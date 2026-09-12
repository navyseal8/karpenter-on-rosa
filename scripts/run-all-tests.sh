#!/usr/bin/env bash
# ============================================================================
# Run all three scaling tests and produce a comparison report
# ============================================================================
# Usage:
#   ./scripts/run-all-tests.sh [extra_replicas]
#
# The script auto-detects the number of base MachinePool nodes and sets
# replicas = base_nodes + extra (default extra=2) to guarantee pending pods
# that force new node provisioning.
#
# Each pod requests 2 CPU / 4Gi — at most 1 pod per node (3.5 CPU allocatable).
# ============================================================================
set -euo pipefail

EXTRA="${1:-2}"  # How many pods BEYOND existing base node capacity
NAMESPACE="scaling-poc"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="/tmp/scaling-poc-results-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

header() { echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${NC}"; echo -e "${BOLD}${CYAN}║  $1${NC}"; echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${NC}"; }

# ── Pre-flight checks ──────────────────────────────────────────────
echo -e "${BOLD}Pre-flight checks...${NC}"
oc whoami > /dev/null 2>&1 || { echo "ERROR: Not logged in to OpenShift. Run: oc login"; exit 1; }
oc get ns "$NAMESPACE" > /dev/null 2>&1 || { echo "Creating namespace $NAMESPACE..."; oc create -f ../01-baseline-clusterautoscaler/00-namespace.yaml; }

# ── Count base (non-burst) nodes to auto-size replicas ────────────
echo -e "${YELLOW}Current nodes:${NC}"
oc get nodes -o custom-columns='NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory,TYPE:.metadata.labels.workload-type' --no-headers
echo ""

# Base nodes = nodes WITHOUT the workload-type=burst label
BASE_NODES=$(oc get nodes --no-headers -l '!workload-type' 2>/dev/null | wc -l)
# Also count how many 2-CPU pods can fit on base nodes (1 per node max)
# by checking free CPU on each base node
SCHEDULABLE=0
while IFS= read -r line; do
  NODE_NAME=$(echo "$line" | awk '{print $1}')
  ALLOC_CPU=$(echo "$line" | awk '{print $2}' | sed 's/m$//')
  # Get total CPU requests on this node
  USED_CPU=$(oc get pods --all-namespaces --field-selector="spec.nodeName=$NODE_NAME" \
    -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.requests.cpu}{"\n"}{end}{end}' 2>/dev/null | \
    awk '{s=0; while((getline line) > 0){
      if(line ~ /m$/){gsub(/m$/,"",line); s+=line}
      else if(line+0 > 0){s+=line*1000}
    } print s}' 2>/dev/null || echo "0")
  # If we can't parse, assume 1000m used
  [ -z "$USED_CPU" ] && USED_CPU=1000
  FREE_CPU=$((ALLOC_CPU - USED_CPU))
  if [ "$FREE_CPU" -ge 2000 ]; then
    SCHEDULABLE=$((SCHEDULABLE + 1))
  fi
done < <(oc get nodes --no-headers -l '!workload-type' -o custom-columns='NAME:.metadata.name,CPU:.status.allocatable.cpu' 2>/dev/null)

# Replicas = nodes that can fit a pod + EXTRA (to guarantee Pending pods)
REPLICAS=$((SCHEDULABLE + EXTRA))
# Minimum 2 for HA
[ "$REPLICAS" -lt 2 ] && REPLICAS=2

echo -e "${BOLD}Auto-sizing:${NC}"
echo -e "  Base nodes:            ${BASE_NODES}"
echo -e "  Can fit 2-CPU pod:     ${SCHEDULABLE} nodes"
echo -e "  Extra pods to force:   ${EXTRA}"
echo -e "  ${CYAN}${BOLD}Replicas for Test 1:   ${REPLICAS} (${SCHEDULABLE} fit + ${EXTRA} Pending → triggers CA)${NC}"
echo ""

# ── Ensure all deployments are at 0 replicas ──────────────────────
echo -e "${YELLOW}Resetting all test deployments to 0 replicas...${NC}"
for dep in burst-workload-cas burst-workload-karpenter burst-workload-preempt capacity-buffer; do
  oc scale deployment/"$dep" -n "$NAMESPACE" --replicas=0 2>/dev/null || true
done

# ── Clean up any existing Karpenter burst nodes ──────────────────
echo -e "${YELLOW}Removing existing Karpenter burst NodeClaims for clean test...${NC}"
oc delete nodeclaim -l karpenter.sh/nodepool=burst-nodepool --wait=false 2>/dev/null || true

echo -e "${YELLOW}Waiting for Karpenter burst nodes to terminate...${NC}"
for i in $(seq 1 60); do
  CLAIMS=$(oc get nodeclaim -l karpenter.sh/nodepool=burst-nodepool --no-headers 2>/dev/null | wc -l)
  if [ "$CLAIMS" -eq 0 ]; then
    echo -e "${GREEN}All burst nodes removed.${NC}"
    break
  fi
  printf "\r  Waiting... %d NodeClaims remaining" "$CLAIMS"
  sleep 10
done
echo ""
sleep 10

# ═══════════════════════════════════════════════════════════════════
# TEST 1: ClusterAutoScaler Baseline
# ═══════════════════════════════════════════════════════════════════
header "TEST 1: ClusterAutoScaler Baseline"
echo -e "${YELLOW}This test demonstrates the 10-15min scaling delay.${NC}"
echo -e "${YELLOW}Each pod requests 2 CPU / 4Gi — only 1 fits per node.${NC}"
echo -e "${YELLOW}${REPLICAS} pods across ${SCHEDULABLE} schedulable base nodes → ${EXTRA} Pending → CA must provision via CAPI.${NC}"
echo ""

"$SCRIPT_DIR/measure-scale-time.sh" burst-workload-cas "$NAMESPACE" "$REPLICAS" \
  2>&1 | tee "$RESULTS_DIR/test1-clusterautoscaler.log"

# Reset Test 1
echo -e "\n${YELLOW}Cleaning up test 1...${NC}"
oc scale deployment/burst-workload-cas -n "$NAMESPACE" --replicas=0
echo -e "${YELLOW}Waiting 30s for pods to terminate...${NC}"
sleep 30

# ═══════════════════════════════════════════════════════════════════
# TEST 2: Karpenter AutoNode
# ═══════════════════════════════════════════════════════════════════
header "TEST 2: Karpenter AutoNode (Right-Sized)"
echo -e "${YELLOW}This test shows Karpenter provisioning in ~2-3min.${NC}"
echo -e "${YELLOW}No burst nodes exist — Karpenter must provision fresh via CreateFleet.${NC}"
echo -e "${YELLOW}Scaling to ${REPLICAS} replicas (same as Test 1 for fair comparison).${NC}"
echo ""

# Confirm no burst nodes exist
CLAIMS=$(oc get nodeclaim -l karpenter.sh/nodepool=burst-nodepool --no-headers 2>/dev/null | wc -l)
if [ "$CLAIMS" -gt 0 ]; then
  echo -e "${YELLOW}Cleaning up $CLAIMS remaining burst NodeClaims...${NC}"
  oc delete nodeclaim -l karpenter.sh/nodepool=burst-nodepool --wait=true --timeout=120s 2>/dev/null || true
  sleep 10
fi

"$SCRIPT_DIR/measure-scale-time.sh" burst-workload-karpenter "$NAMESPACE" "$REPLICAS" \
  2>&1 | tee "$RESULTS_DIR/test2-karpenter.log"

# Clean up Test 2 completely — burst nodes must be removed so Test 3
# buffer pods provision FRESH nodes that are fully occupied by buffers
echo -e "\n${YELLOW}Cleaning up test 2 workload and burst nodes...${NC}"
oc scale deployment/burst-workload-karpenter -n "$NAMESPACE" --replicas=0
sleep 5

echo -e "${YELLOW}Deleting Test 2 burst NodeClaims...${NC}"
oc delete nodeclaim -l karpenter.sh/nodepool=burst-nodepool --wait=false 2>/dev/null || true

echo -e "${YELLOW}Waiting for all burst nodes to terminate...${NC}"
for i in $(seq 1 60); do
  CLAIMS=$(oc get nodeclaim -l karpenter.sh/nodepool=burst-nodepool --no-headers 2>/dev/null | wc -l)
  if [ "$CLAIMS" -eq 0 ]; then
    echo -e "${GREEN}All burst nodes removed.${NC}"
    break
  fi
  printf "\r  Waiting... %d NodeClaims remaining" "$CLAIMS"
  sleep 10
done
echo ""
sleep 10

# ═══════════════════════════════════════════════════════════════════
# TEST 3: Buffer Overprovisioning + Preemption
# ═══════════════════════════════════════════════════════════════════
header "TEST 3: Buffer Overprovisioning (Instant Preemption)"
echo -e "${YELLOW}Step 1: Deploy ${REPLICAS} buffer pods to provision and warm burst nodes...${NC}"
echo -e "${YELLOW}        Each buffer pod (2 CPU / 4Gi) fully occupies 1 burst node.${NC}"
echo -e "${YELLOW}        Karpenter will provision ${REPLICAS} new nodes (~2-3 min).${NC}"
echo ""

# Scale up buffer pods — Karpenter provisions fresh burst nodes for them
oc scale deployment/capacity-buffer -n "$NAMESPACE" --replicas="$REPLICAS"

echo -e "${YELLOW}Waiting for $REPLICAS buffer pods to become Running...${NC}"
for i in $(seq 1 90); do
  BUFFER_RUNNING=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=capacity-placeholder --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  CLAIMS=$(oc get nodeclaim -l karpenter.sh/nodepool=burst-nodepool --no-headers 2>/dev/null | wc -l)
  if [ "$BUFFER_RUNNING" -ge "$REPLICAS" ]; then
    echo ""
    echo -e "${GREEN}All $REPLICAS buffer pods Running on $CLAIMS burst nodes — warm capacity ready!${NC}"
    break
  fi
  printf "\r  NodeClaims: %d | Buffer pods Running: %d / %d" "$CLAIMS" "$BUFFER_RUNNING" "$REPLICAS"
  sleep 10
done
echo ""

echo -e "${YELLOW}Step 2: Scale real workload — buffer pods will be PREEMPTED instantly!${NC}"
echo ""

"$SCRIPT_DIR/measure-scale-time.sh" burst-workload-preempt "$NAMESPACE" "$REPLICAS" \
  2>&1 | tee "$RESULTS_DIR/test3-buffer.log"

# ═══════════════════════════════════════════════════════════════════
# Comparison Report
# ═══════════════════════════════════════════════════════════════════
header "COMPARISON REPORT"
echo ""
echo -e "${BOLD}Test config: ${REPLICAS} replicas × 2 CPU / 4Gi per pod | ${BASE_NODES} base nodes | ${EXTRA} forced Pending${NC}"
echo ""

T1=$(cat /tmp/scale-result-burst-workload-cas.json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['all_pods_ready_s'])" 2>/dev/null || echo "N/A")
T2=$(cat /tmp/scale-result-burst-workload-karpenter.json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['all_pods_ready_s'])" 2>/dev/null || echo "N/A")
T3=$(cat /tmp/scale-result-burst-workload-preempt.json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['all_pods_ready_s'])" 2>/dev/null || echo "N/A")

echo -e "${BOLD}┌─────────────────────────────────────────┬───────────┬───────────┐${NC}"
echo -e "${BOLD}│ Approach                                │   Time(s) │  Time(m)  │${NC}"
echo -e "${BOLD}├─────────────────────────────────────────┼───────────┼───────────┤${NC}"
printf  "${BOLD}│${NC} ${RED}1. ClusterAutoScaler (baseline)${NC}         ${BOLD}│${NC} %9s ${BOLD}│${NC} %9s ${BOLD}│${NC}\n" "$T1" "$(echo "$T1" | awk '{printf "%.1f", $1/60}' 2>/dev/null || echo 'N/A')"
printf  "${BOLD}│${NC} ${YELLOW}2. Karpenter AutoNode (right-sized)${NC}     ${BOLD}│${NC} %9s ${BOLD}│${NC} %9s ${BOLD}│${NC}\n" "$T2" "$(echo "$T2" | awk '{printf "%.1f", $1/60}' 2>/dev/null || echo 'N/A')"
printf  "${BOLD}│${NC} ${GREEN}3. Buffer + Preemption (instant)${NC}        ${BOLD}│${NC} %9s ${BOLD}│${NC} %9s ${BOLD}│${NC}\n" "$T3" "$(echo "$T3" | awk '{printf "%.1f", $1/60}' 2>/dev/null || echo 'N/A')"
echo -e "${BOLD}└─────────────────────────────────────────┴───────────┴───────────┘${NC}"
echo ""

if [ "$T1" != "N/A" ] && [ "$T3" != "N/A" ]; then
  SPEEDUP=$(awk "BEGIN {printf \"%.0f\", $T1 / $T3}")
  echo -e "${GREEN}${BOLD}Buffer preemption is ~${SPEEDUP}x faster than ClusterAutoScaler!${NC}"
fi

echo ""
echo -e "${CYAN}Results saved to: $RESULTS_DIR${NC}"
echo ""

# ── Cleanup reminder ──────────────────────────────────────────────
echo -e "${YELLOW}To clean up all test resources:${NC}"
echo "  oc delete ns scaling-poc"
echo "  oc delete priorityclass buffer-placeholder production-burst"
