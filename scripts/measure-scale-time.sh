#!/usr/bin/env bash
# ============================================================================
# Measure time from pod Pending → Ready for scaling POC
# ============================================================================
# Tracks the full lifecycle including readiness probe pass, not just Running.
#
# Usage:
#   ./scripts/measure-scale-time.sh <deployment-name> <namespace> <replicas>
#
# Examples:
#   # Test 1: ClusterAutoScaler baseline
#   ./scripts/measure-scale-time.sh burst-workload-cas scaling-poc 4
#
#   # Test 2: Karpenter AutoNode
#   ./scripts/measure-scale-time.sh burst-workload-karpenter scaling-poc 4
#
#   # Test 3: Buffer preemption
#   ./scripts/measure-scale-time.sh burst-workload-preempt scaling-poc 4
# ============================================================================
set -euo pipefail

DEPLOYMENT="${1:?Usage: $0 <deployment> <namespace> <replicas>}"
NAMESPACE="${2:?Usage: $0 <deployment> <namespace> <replicas>}"
REPLICAS="${3:?Usage: $0 <deployment> <namespace> <replicas>}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

header() { echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}"; }
info()   { echo -e "${YELLOW}[INFO]${NC} $1"; }
ok()     { echo -e "${GREEN}[OK]${NC} $1"; }
err()    { echo -e "${RED}[ERROR]${NC} $1"; }

# Resolve the app.kubernetes.io/instance label from the deployment
INSTANCE_LABEL=$(oc get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
  -o jsonpath='{.spec.selector.matchLabels.app\.kubernetes\.io/instance}' 2>/dev/null || echo "")
if [ -z "$INSTANCE_LABEL" ]; then
  LABEL_SELECTOR="app=burst-workload"
else
  LABEL_SELECTOR="app.kubernetes.io/name=burst-workload,app.kubernetes.io/instance=$INSTANCE_LABEL"
fi

header "Scale-Up Timing Test"
info "Deployment: $DEPLOYMENT"
info "Namespace:  $NAMESPACE"
info "Replicas:   $REPLICAS"
info "Selector:   $LABEL_SELECTOR"

# Ensure deployment exists and starts at 0
info "Resetting deployment to 0 replicas..."
oc scale deployment/"$DEPLOYMENT" -n "$NAMESPACE" --replicas=0 2>/dev/null || true
sleep 3

# Wait for all pods to terminate
info "Waiting for existing pods to terminate..."
oc wait --for=delete pod -l "$LABEL_SELECTOR" -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

header "Starting Scale-Up"
SCALE_START=$(date +%s%N)
SCALE_START_HUMAN=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

info "Scaling to $REPLICAS replicas at $SCALE_START_HUMAN"
oc scale deployment/"$DEPLOYMENT" -n "$NAMESPACE" --replicas="$REPLICAS"

# Poll pod status — track both Running and Ready (passed readiness probe)
info "Waiting for pods to become Ready (readiness probe must pass)..."
echo ""

FIRST_RUNNING=""
FIRST_READY=""
ALL_READY=false
POLL_INTERVAL=5
MAX_WAIT=1500  # 25 minutes max (CA + CAPI can take 10-15 min)

elapsed=0
while [ "$elapsed" -lt "$MAX_WAIT" ]; do
  TOTAL=$(oc get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" --no-headers 2>/dev/null | wc -l)
  PENDING=$(oc get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" --no-headers 2>/dev/null | grep -c "Pending" || true)
  RUNNING=$(oc get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" --no-headers 2>/dev/null | grep -c "Running" || true)
  # Count pods where all containers are ready (READY column = n/n)
  READY=$(oc get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" --no-headers 2>/dev/null | awk '{split($2,a,"/"); if(a[1]==a[2] && $3=="Running") count++} END{print count+0}')

  NOW=$(date +%s%N)
  ELAPSED_MS=$(( (NOW - SCALE_START) / 1000000 ))
  ELAPSED_S=$(( ELAPSED_MS / 1000 ))

  printf "\r  [%3ds] Total: %d | Pending: %d | Running: %d | Ready: %d / %d" \
    "$ELAPSED_S" "$TOTAL" "$PENDING" "$RUNNING" "$READY" "$REPLICAS"

  # Track first pod Running
  if [ -z "$FIRST_RUNNING" ] && [ "$RUNNING" -gt 0 ]; then
    FIRST_RUNNING_NS=$NOW
    FIRST_RUNNING=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    FIRST_RUNNING_S=$(( (FIRST_RUNNING_NS - SCALE_START) / 1000000 / 1000 ))
  fi

  # Track first pod Ready (passed readiness probe)
  if [ -z "$FIRST_READY" ] && [ "$READY" -gt 0 ]; then
    FIRST_READY_NS=$NOW
    FIRST_READY=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    FIRST_READY_S=$(( (FIRST_READY_NS - SCALE_START) / 1000000 / 1000 ))
  fi

  # All pods ready
  if [ "$READY" -ge "$REPLICAS" ]; then
    ALL_READY=true
    ALL_READY_NS=$NOW
    break
  fi

  sleep "$POLL_INTERVAL"
  elapsed=$((elapsed + POLL_INTERVAL))
done

echo ""
echo ""

# Display results
if [ "$ALL_READY" = true ]; then
  TOTAL_MS=$(( (ALL_READY_NS - SCALE_START) / 1000000 ))
  TOTAL_S=$(( TOTAL_MS / 1000 ))
  TOTAL_MIN=$(awk "BEGIN {printf \"%.1f\", $TOTAL_S / 60}")

  header "Results"
  ok "All $REPLICAS pods Ready (readiness probe passed)!"
  echo ""
  echo -e "  ${BOLD}Scale start:${NC}         $SCALE_START_HUMAN"
  [ -n "$FIRST_RUNNING" ] && echo -e "  ${BOLD}First pod Running:${NC}   $FIRST_RUNNING (${FIRST_RUNNING_S}s)"
  [ -n "$FIRST_READY" ]   && echo -e "  ${BOLD}First pod Ready:${NC}     $FIRST_READY (${FIRST_READY_S}s)"
  echo -e "  ${BOLD}All pods Ready:${NC}      $(date -u '+%Y-%m-%dT%H:%M:%SZ') (${TOTAL_S}s)"
  echo ""
  echo -e "  ${BOLD}${CYAN}Total time to Ready: ${TOTAL_S}s (${TOTAL_MIN} min)${NC}"
  echo ""

  # Pod distribution across nodes/zones
  echo -e "  ${BOLD}Pod distribution:${NC}"
  oc get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o wide --no-headers | \
    awk '{printf "    %-40s  Node: %s\n", $1, $7}'
  echo ""

  # PDB status
  PDB_NAME=$(oc get pdb -n "$NAMESPACE" -l "app.kubernetes.io/instance=$INSTANCE_LABEL" -o name 2>/dev/null | head -1)
  if [ -n "$PDB_NAME" ]; then
    echo -e "  ${BOLD}PDB status:${NC}"
    oc get "$PDB_NAME" -n "$NAMESPACE" 2>/dev/null | sed 's/^/    /'
    echo ""
  fi

  # Write result to file for comparison
  RESULT_FILE="/tmp/scale-result-${DEPLOYMENT}.json"
  cat > "$RESULT_FILE" <<EOF
{
  "deployment": "$DEPLOYMENT",
  "namespace": "$NAMESPACE",
  "replicas": $REPLICAS,
  "scale_start": "$SCALE_START_HUMAN",
  "first_pod_running_s": ${FIRST_RUNNING_S:-null},
  "first_pod_ready_s": ${FIRST_READY_S:-null},
  "all_pods_ready_s": $TOTAL_S,
  "all_pods_ready_min": $TOTAL_MIN
}
EOF
  info "Result saved to $RESULT_FILE"
else
  header "TIMEOUT"
  err "Not all pods became Ready within $((MAX_WAIT / 60)) minutes!"
  err "This confirms the slow scaling issue."
  echo ""

  info "Current pod status:"
  oc get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o wide
  echo ""
  info "Pod conditions:"
  for pod in $(oc get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o name 2>/dev/null); do
    echo "--- $pod ---"
    oc get "$pod" -n "$NAMESPACE" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
    oc describe "$pod" -n "$NAMESPACE" | grep -A 5 "Events:" | tail -6
    echo ""
  done
fi
