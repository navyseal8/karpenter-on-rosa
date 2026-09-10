#!/usr/bin/env bash
# ============================================================================
# Run all three scaling tests and produce a comparison report
# ============================================================================
# Usage:
#   ./scripts/run-all-tests.sh [replicas]
#
# Default: 5 replicas per test
# ============================================================================
set -euo pipefail

REPLICAS="${1:-4}"  # Default 4: min 2 for HA, spread across 2+ zones/nodes
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

# ── Ensure all deployments are at 0 replicas ──────────────────────
echo -e "${YELLOW}Resetting all test deployments to 0 replicas...${NC}"
for dep in burst-workload-cas burst-workload-karpenter burst-workload-preempt; do
  oc scale deployment/"$dep" -n "$NAMESPACE" --replicas=0 2>/dev/null || true
done
sleep 10

# ═══════════════════════════════════════════════════════════════════
# TEST 1: ClusterAutoScaler Baseline
# ═══════════════════════════════════════════════════════════════════
header "TEST 1: ClusterAutoScaler Baseline"
echo -e "${YELLOW}This test demonstrates the 10-15min scaling delay.${NC}"
echo -e "${YELLOW}Scaling burst-workload-cas to $REPLICAS replicas...${NC}"
echo ""

"$SCRIPT_DIR/measure-scale-time.sh" burst-workload-cas "$NAMESPACE" "$REPLICAS" \
  2>&1 | tee "$RESULTS_DIR/test1-clusterautoscaler.log"

# Reset
echo -e "\n${YELLOW}Cleaning up test 1...${NC}"
oc scale deployment/burst-workload-cas -n "$NAMESPACE" --replicas=0
sleep 30

# ═══════════════════════════════════════════════════════════════════
# TEST 2: Karpenter AutoNode
# ═══════════════════════════════════════════════════════════════════
header "TEST 2: Karpenter AutoNode (Right-Sized)"
echo -e "${YELLOW}This test shows Karpenter provisioning in ~2-3min.${NC}"
echo -e "${YELLOW}Scaling burst-workload-karpenter to $REPLICAS replicas...${NC}"
echo ""

"$SCRIPT_DIR/measure-scale-time.sh" burst-workload-karpenter "$NAMESPACE" "$REPLICAS" \
  2>&1 | tee "$RESULTS_DIR/test2-karpenter.log"

# Reset
echo -e "\n${YELLOW}Cleaning up test 2...${NC}"
oc scale deployment/burst-workload-karpenter -n "$NAMESPACE" --replicas=0
sleep 30

# ═══════════════════════════════════════════════════════════════════
# TEST 3: Buffer Overprovisioning + Preemption
# ═══════════════════════════════════════════════════════════════════
header "TEST 3: Buffer Overprovisioning (Instant Preemption)"
echo -e "${YELLOW}Ensuring buffer pods are running first...${NC}"

# Ensure buffer pods are Running
BUFFER_RUNNING=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=capacity-placeholder --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
if [ "$BUFFER_RUNNING" -lt 3 ]; then
  echo -e "${RED}WARNING: Only $BUFFER_RUNNING buffer pods running. Waiting for buffers...${NC}"
  oc rollout status deployment/capacity-buffer -n "$NAMESPACE" --timeout=300s || true
fi
echo -e "${GREEN}Buffer pods ready: $(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=capacity-placeholder --field-selector=status.phase=Running --no-headers | wc -l)${NC}"
echo ""

echo -e "${YELLOW}Scaling burst-workload-preempt to $REPLICAS replicas...${NC}"
echo -e "${YELLOW}Buffer pods should be preempted instantly!${NC}"
echo ""

"$SCRIPT_DIR/measure-scale-time.sh" burst-workload-preempt "$NAMESPACE" "$REPLICAS" \
  2>&1 | tee "$RESULTS_DIR/test3-buffer.log"

# ═══════════════════════════════════════════════════════════════════
# Comparison Report
# ═══════════════════════════════════════════════════════════════════
header "COMPARISON REPORT"
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
