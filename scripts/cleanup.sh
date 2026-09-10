#!/usr/bin/env bash
# ============================================================================
# Clean up all POC resources
# ============================================================================
set -euo pipefail

echo "=== Cleaning up Scaling POC resources ==="

echo "Scaling all deployments to 0..."
for dep in burst-workload-cas burst-workload-karpenter burst-workload-preempt capacity-buffer; do
  oc scale deployment/"$dep" -n scaling-poc --replicas=0 2>/dev/null || true
done
sleep 5

echo "Deleting PDBs..."
oc delete pdb -n scaling-poc --all 2>/dev/null || true

echo "Deleting namespace..."
oc delete ns scaling-poc --wait=false 2>/dev/null || true

echo "Deleting PriorityClasses..."
oc delete priorityclass buffer-placeholder production-burst 2>/dev/null || true

echo "Deleting Karpenter NodePool (optional — keeps default)..."
oc delete nodepool burst-nodepool 2>/dev/null || true

echo ""
echo "✅ Cleanup complete"
echo ""
echo "Note: Karpenter nodes will be consolidated automatically."
echo "      To fully disable AutoNode:"
echo "        rosa edit cluster -c <CLUSTER_ID> --autonode=disabled"
