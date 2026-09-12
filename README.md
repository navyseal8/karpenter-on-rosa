# ROSA Scaling POC: ClusterAutoScaler vs Karpenter AutoNode vs Buffer Overprovisioning

## Problem Statement

On **Red Hat OpenShift Service on AWS (ROSA)**, the built-in **ClusterAutoScaler** with Cluster API (CAPI) takes **10-15 minutes** to provision new worker nodes when burst workloads create pending pods. This delay comes from:

| Phase | Duration | Description |
|-------|----------|-------------|
| CA scan interval | ~10s | ClusterAutoScaler detects unschedulable pods |
| CA → CAPI decision | ~20-30s | CA evaluates node groups, selects MachineSet to scale |
| CAPI → AWS EC2 API | ~1-2min | Cluster API calls AWS to create EC2 instance |
| EC2 instance launch | ~2-3min | Instance boots, passes health checks |
| OpenShift node bootstrap | ~3-5min | kubelet starts, pulls images, joins cluster |
| CSR approval | ~1-3min | Node certificate signing request approved |
| Node Ready → Pod scheduled | ~30s-1min | Scheduler places pods on new Ready node |
| **Total** | **~10-15min** | ❌ Unacceptable for bursty workloads |

## Solutions Demonstrated

This POC demonstrates three approaches and measures their scaling times:

### 1️⃣ Baseline: ClusterAutoScaler (10-15 min)

The default ROSA scaling path — proves the problem exists.

### 2️⃣ Workaround A: Karpenter AutoNode (~2-3 min)

Uses **Red Hat build of Karpenter (AutoNode)** for workload-aware, just-in-time node provisioning:
- Karpenter evaluates pending pod resource requests directly
- Calls EC2 `CreateFleet` API — bypasses CAPI entirely
- Right-sizes instances (picks optimal from c/m/r families)
- Node bootstraps faster (simpler join flow)
- Bursty workloads are labelled `workload-type: burst` and targeted to a dedicated Karpenter NodePool

### 3️⃣ Workaround B: Buffer Overprovisioning (~5-15 seconds)

Pre-provisions warm capacity using **placeholder pods with negative PriorityClass**:
- Buffer pods (priority -1000) reserve resources on pre-provisioned nodes
- Real workloads (priority 1000000) preempt buffer pods instantly
- Real pods start in seconds on already-warm nodes
- Karpenter refills the buffer automatically in the background

## Architecture

> 📐 Open [`architecture.drawio`](architecture.drawio) in [draw.io](https://app.diagrams.net/) or the VS Code draw.io extension for the full interactive diagram.

![Architecture Diagram — open architecture.drawio for interactive version](architecture.drawio)

The diagram shows:

| Section | What it illustrates |
|---------|---------------------|
| **Top left (red)** | ClusterAutoScaler flow — 8-step pipeline through CAPI, EC2, bootstrap, CSR → 10-15 min |
| **Top centre (amber)** | Karpenter AutoNode flow — direct CreateFleet API, fast bootstrap → 2-3 min |
| **Top right (green)** | Buffer overprovisioning — preemption of low-priority pause pods → 10-20 sec |
| **Bottom** | Worker nodes split across 2 AZs, showing topology spread, buffer ↔ real pod preemption, PDB/probes |

## Test Parameters

Each pod requests **2 CPU / 4Gi memory** — deliberately sized so that only **1 pod fits per node** (node allocatable ≈ 3.5 CPU / 6.5–15Gi). This forces each approach to provision **new** node capacity rather than bin-packing onto existing nodes.

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| **Pod CPU request** | 2 CPU | Only 1 pod per node (3.5 CPU allocatable) |
| **Pod memory request** | 4 Gi | Fits within burst node memory (~6.5 Gi allocatable) |
| **Replicas** | Auto-sized | `base_nodes + extra` — always exceeds current capacity |
| **Extra (default)** | 2 | How many pods go Pending to force new node provisioning |
| **Buffer pod replicas** | Same as replicas | Pre-warms burst nodes (1 buffer per node) |
| **Buffer pod image** | `registry.k8s.io/pause:3.10` | Negligible CPU — reserves capacity only |
| **Buffer PriorityClass** | `-1000` (buffer-placeholder) | Lowest priority — preempted first |
| **Real workload PriorityClass** | `1000000` (production-burst) | Preempts buffer pods instantly |

### Auto-sizing replicas to exceed current capacity

The test script **automatically counts base nodes** and sets replicas to exceed
available capacity. This ensures pending pods regardless of how many MachinePool
nodes are currently running (e.g. 3 nodes at min, or 6 nodes at max).

```
replicas = (base nodes that can fit a 2-CPU pod) + extra
```

The `extra` argument (default: 2) controls how many pods go Pending and trigger
new node provisioning. Run with a different value:

```bash
./scripts/run-all-tests.sh 3   # 3 extra pods beyond current capacity
```

### How each test forces new node provisioning

| Test | Targeting | Why pods can't fit on existing nodes |
|------|-----------|--------------------------------------|
| **1. CA baseline** | No `nodeSelector` → base MachinePool nodes only | Script counts base nodes, sets replicas to exceed → extra pods go Pending → CA scales MachineSet |
| **2. Karpenter** | `nodeSelector: workload-type=burst` | All burst NodeClaims deleted before test → 0 burst nodes → Karpenter provisions fresh |
| **3. Buffer** | Same `nodeSelector` + `priorityClass: production-burst` | Burst nodes removed → buffer pods provision fresh nodes → real pods preempt buffers instantly |

## Prerequisites

- **ROSA HCP cluster** running OpenShift **≥ 4.22**
- `oc` CLI authenticated to the cluster
- `rosa` CLI configured (≥ 1.2.61)
- AWS CLI configured with IAM permissions
- `jq` installed

## Quick Start

### Step 1: Set up namespace, PriorityClasses, and PDBs

```bash
oc apply -f 01-baseline-clusterautoscaler/00-namespace.yaml
oc apply -f 03-buffer-overprovisioning/00-priority-classes.yaml
```

### Step 2: Enable MachinePool autoscaling (required for Test 1)

The ClusterAutoScaler can only provision new nodes if the MachinePool has
autoscaling enabled. Without this, pending pods stay Pending forever — CA
sees `Insufficient cpu` but has no permission to add nodes.

```bash
# List existing MachinePool(s)
rosa list machinepools -c <CLUSTER_NAME>

# Enable autoscaling (replace <POOL_NAME> with the name from above)
rosa edit machinepool -c <CLUSTER_NAME> <POOL_NAME> \
  --enable-autoscaling \
  --min-replicas 3 \
  --max-replicas 6
```

### Step 3: Enable Karpenter AutoNode (required for Tests 2 & 3)

```bash
export CLUSTER_NAME=<your-cluster-name>
export AWS_REGION=<your-region>
bash 02-karpenter-autonode/00-enable-autonode.sh
```

> ⚠️ **rosa CLI ≥ 1.2.57** is required for `--autonode` flag. If your CLI is
> older, the script will print instructions to enable via the OCM console instead.

### Step 4: Tag subnets for Karpenter discovery

Karpenter requires the **private subnets** to be tagged with `kubernetes.io/role/internal-elb=1`.
Without this tag, the `OpenshiftEC2NodeClass` stays `READY: False` (SubnetsNotFound).

```bash
# Find the VPC from the cluster's security group
CLUSTER_ID=$(rosa describe cluster -c <CLUSTER_NAME> -o json | jq -r '.id')
SG_ID=$(aws ec2 describe-security-groups --region <REGION> \
  --filters "Name=tag:Name,Values=${CLUSTER_ID}-default-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)
VPC_ID=$(aws ec2 describe-security-groups --region <REGION> \
  --group-ids "$SG_ID" --query 'SecurityGroups[0].VpcId' --output text)

# List subnets in the VPC
aws ec2 describe-subnets --region <REGION> \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[*].[SubnetId,AvailabilityZone,MapPublicIpOnLaunch,Tags[?Key==`Name`].Value|[0]]' \
  --output table

# Tag the PRIVATE subnets only (MapPublicIpOnLaunch = False, name contains "private")
aws ec2 create-tags --region <REGION> \
  --resources <PRIVATE_SUBNET_1> <PRIVATE_SUBNET_2> <PRIVATE_SUBNET_3> \
  --tags "Key=kubernetes.io/role/internal-elb,Value=1"
```

### Step 5: Deploy Karpenter NodePool

```bash
oc apply -f 02-karpenter-autonode/01-nodepool.yaml

# Verify both are Ready
oc get openshiftec2nodeclass   # Should show READY: True
oc get nodepool                # Should show READY: True
```

### Step 6: Deploy all workloads (at 0 replicas) and PDBs

```bash
# Baseline CA test
oc apply -f 01-baseline-clusterautoscaler/03-burst-workload.yaml
oc apply -f 01-baseline-clusterautoscaler/04-pdb.yaml

# Karpenter AutoNode test
oc apply -f 02-karpenter-autonode/02-burst-workload-karpenter.yaml
oc apply -f 02-karpenter-autonode/03-pdb.yaml

# Buffer overprovisioning test
oc apply -f 03-buffer-overprovisioning/01-buffer-pods.yaml
oc apply -f 03-buffer-overprovisioning/02-burst-workload-preempting.yaml
oc apply -f 03-buffer-overprovisioning/03-pdb.yaml
```

### Step 7: Run the comparison tests

```bash
chmod +x scripts/*.sh
./scripts/run-all-tests.sh      # default: 2 extra pods beyond current capacity
./scripts/run-all-tests.sh 3    # or specify how many extra Pending pods to force
```

> The test script automatically:
> - **Counts base MachinePool nodes** and sizes replicas to exceed capacity
> - Deletes burst NodeClaims before Test 2 (forces fresh Karpenter provisioning)
> - Deletes burst NodeClaims before Test 3, deploys buffer pods, waits for
>   warm capacity, then scales real pods (forces preemption)
> - Uses the **same replica count** across all 3 tests for a fair comparison
> - Total runtime: ~25-30 min (Test 1 is the slow one at 10-15 min)

## Running Individual Tests

### Test 1: Prove ClusterAutoScaler takes 10-15 min

> **Prerequisite:** MachinePool autoscaling must be enabled (see Step 2 above).
> Without it, the 4th pod stays Pending forever — CA can't provision new nodes.

```bash
# Ensure no burst nodes interfere (CA test targets base MachinePool nodes only)
# Scale to 4 replicas — 3 fit on base nodes, 1 goes Pending
oc scale deployment/burst-workload-cas -n scaling-poc --replicas=4

# Watch: 3 pods Running quickly, 4th stuck Pending for 10-15 min
oc get pods -n scaling-poc -l app.kubernetes.io/instance=cas-baseline -w

# In another terminal — watch CA provision a new MachinePool node via CAPI
oc get nodes -w

# Verify PDB is protecting running pods
oc get pdb -n scaling-poc

# Measure with script (timeout: 25 min)
./scripts/measure-scale-time.sh burst-workload-cas scaling-poc 4
```

### Test 2: Karpenter AutoNode right-sizing

```bash
# IMPORTANT: ensure no burst nodes exist — Karpenter must provision fresh
oc delete nodeclaim -l karpenter.sh/nodepool=burst-nodepool --wait=true 2>/dev/null
sleep 30

# Scale to 4 replicas — Karpenter provisions 4 right-sized burst nodes
oc scale deployment/burst-workload-karpenter -n scaling-poc --replicas=4

# Watch Karpenter provision nodes in ~2-3 min
oc get pods -n scaling-poc -l app.kubernetes.io/instance=karpenter-autonode -w

# Check which instance types Karpenter right-sized
oc get nodeclaim -o wide

# Verify pods spread across zones
oc get pods -n scaling-poc -l app.kubernetes.io/instance=karpenter-autonode -o wide
```

### Test 3: Buffer preemption (instant)

```bash
# Step 1: Clean up any existing burst nodes (start from scratch)
oc scale deployment/burst-workload-karpenter -n scaling-poc --replicas=0
oc scale deployment/capacity-buffer -n scaling-poc --replicas=0
oc delete nodeclaim -l karpenter.sh/nodepool=burst-nodepool --wait=true 2>/dev/null
sleep 30

# Step 2: Deploy buffer pods — Karpenter provisions fresh burst nodes (~2-3 min)
# Each buffer pod (2 CPU / 4Gi) fully occupies 1 burst node
oc scale deployment/capacity-buffer -n scaling-poc --replicas=4
oc get pods -n scaling-poc -l app.kubernetes.io/name=capacity-placeholder -w
# Wait until all 4 buffer pods are Running, then Ctrl+C

# Step 3: Scale real workload — buffer pods PREEMPTED instantly
oc scale deployment/burst-workload-preempt -n scaling-poc --replicas=4

# Watch instant scheduling! (~10-20 sec to Ready)
oc get pods -n scaling-poc -l app.kubernetes.io/instance=buffer-preempt -w

# Verify PDB protects running pods during any disruption
oc get pdb -n scaling-poc
```

## Expected Results

| Approach | Pod requests | What happens | Time to Ready |
|----------|-------------|--------------|---------------|
| ClusterAutoScaler (CAPI) | N × 2 CPU / 4Gi | Base nodes absorb what they can; **extra pods Pending** → CA scales MachineSet → CAPI → EC2 → bootstrap → CSR | **10-15 min** |
| Karpenter AutoNode | N × 2 CPU / 4Gi | 0 burst nodes exist → Karpenter `CreateFleet` → N right-sized instances | **~2-3 min** |
| Buffer + Preemption | N × 2 CPU / 4Gi | N buffer pods preempted → real pods start on warm nodes | **~10-20 sec** |

*N = auto-sized replicas (base nodes that can fit a 2-CPU pod + extra)*

\* *Includes ~5s startup probe + ~5s readiness probe pass time on pre-warmed nodes*

> **Note on Test 1:** MachinePool autoscaling must be enabled (`rosa edit machinepool --enable-autoscaling`).
> Without it, the 4th pod stays Pending **indefinitely** — the ClusterAutoScaler sees `Insufficient cpu`
> but has no permission to scale the MachineSet. This is a common misconfiguration in ROSA clusters.

## Resetting & Re-running Tests

If a test run was interrupted or you want to re-run from a clean state:

```bash
# 1. Scale all workloads to 0
oc scale deployment -n scaling-poc --all --replicas=0

# 2. Delete all Karpenter burst nodes
oc delete nodeclaim -l karpenter.sh/nodepool=burst-nodepool --wait=false

# 3. Wait for burst nodes to terminate
watch 'oc get nodeclaim -l karpenter.sh/nodepool=burst-nodepool --no-headers | wc -l'
# Wait until it shows 0, then Ctrl+C

# 4. Confirm only the base MachinePool nodes remain
oc get nodes

# 5. Re-apply latest manifests
oc apply -f 01-baseline-clusterautoscaler/03-burst-workload.yaml
oc apply -f 02-karpenter-autonode/02-burst-workload-karpenter.yaml
oc apply -f 03-buffer-overprovisioning/01-buffer-pods.yaml
oc apply -f 03-buffer-overprovisioning/02-burst-workload-preempting.yaml

# 6. Re-run (auto-sizes replicas to exceed current capacity)
./scripts/run-all-tests.sh
```

> If Test 1 (CA) scaled the MachinePool beyond `min-replicas` in a previous run,
> the extra node may take ~15 min to scale back down. You can speed this up:
> ```bash
> # Check current MachinePool replicas
> rosa list machinepools -c <CLUSTER_NAME>
>
> # Manually scale down if needed (don't go below min-replicas)
> rosa edit machinepool -c <CLUSTER_NAME> <POOL_NAME> --replicas 3
> ```

## Cleanup

To remove **all** POC resources from the cluster:

```bash
./scripts/cleanup.sh
```

Or manually:

```bash
oc scale deployment -n scaling-poc --all --replicas=0
oc delete nodeclaim -l karpenter.sh/nodepool=burst-nodepool --wait=false
oc delete ns scaling-poc
oc delete priorityclass buffer-placeholder production-burst
oc delete nodepool burst-nodepool
```

## File Structure

```
.
├── README.md                                  # This file
├── architecture.drawio                        # Architecture diagram (draw.io)
├── 01-baseline-clusterautoscaler/
│   ├── 00-namespace.yaml                      # Shared namespace
│   ├── 01-clusterautoscaler.yaml              # CA config (reference only)
│   ├── 02-machinepool-autoscale.yaml          # MachinePool config (reference only)
│   ├── 03-burst-workload.yaml                 # Test workload for CA
│   └── 04-pdb.yaml                           # PodDisruptionBudget
├── 02-karpenter-autonode/
│   ├── 00-enable-autonode.sh                  # Script to enable AutoNode
│   ├── 01-nodepool.yaml                       # Karpenter NodePool + EC2NodeClass
│   ├── 02-burst-workload-karpenter.yaml       # Test workload for Karpenter
│   └── 03-pdb.yaml                           # PodDisruptionBudget
├── 03-buffer-overprovisioning/
│   ├── 00-priority-classes.yaml               # PriorityClasses (buffer + prod)
│   ├── 01-buffer-pods.yaml                    # Placeholder/buffer deployment
│   ├── 02-burst-workload-preempting.yaml      # Real workload that preempts
│   └── 03-pdb.yaml                           # PodDisruptionBudget
└── scripts/
    ├── measure-scale-time.sh                  # Measure single test timing
    ├── run-all-tests.sh                       # Run all 3 tests + comparison
    └── cleanup.sh                             # Remove all POC resources
```

## Resilience Best Practices Applied

Every burst workload manifest follows production-grade best practices:

| Practice | What | Why |
|----------|------|-----|
| **≥2 replicas** | Auto-sized (≥2) scale target | Survive single-pod failure |
| **PodDisruptionBudget** | `minAvailable: 1` | Prevent voluntary disruptions from killing all pods |
| **Startup probe** | `test -f /tmp/healthy` | Allow slow-starting containers without liveness kills |
| **Readiness probe** | `test -f /tmp/ready` | Only receive traffic when truly ready |
| **Liveness probe** | `test -f /tmp/healthy` | Restart stuck containers automatically |
| **TopologySpreadConstraints** | Zone + hostname spread | Survive AZ outage; spread across nodes |
| **Guaranteed QoS** | requests = limits (2 CPU / 4Gi) | Prevent OOM kills and noisy neighbours |
| **Security context** | Non-root, read-only rootfs, drop ALL caps | Hardened by default |
| **Graceful shutdown** | SIGTERM trap → remove `/tmp/ready` → sleep 5 | Drain in-flight requests before exit |
| **RollingUpdate** | `maxUnavailable: 0` | Zero-downtime deploys |
| **K8s recommended labels** | `app.kubernetes.io/*` | Standard observability and management |

### Buffer pods — intentionally NO PDB

Buffer pods do **not** have a PDB. This is by design: they must be freely preemptable
so that real workloads can claim warm capacity instantly. A PDB would block the
scheduler from evicting them during preemption, defeating the purpose.

## Key Design Decisions

### Why label bursty workloads?

Labelling with `workload-type: burst` lets you:
- **Separate concerns**: Steady-state workloads stay on MachinePool nodes; bursty workloads go to Karpenter nodes
- **Right-size per workload**: Karpenter picks the optimal instance type per burst
- **Cost control**: Set CPU/memory limits on the Karpenter NodePool
- **Gradual adoption**: Karpenter and ClusterAutoScaler coexist — migrate workloads incrementally

### Why buffer pods + PriorityClass?

- **Zero cold-start**: Real pods start in seconds, not minutes
- **Self-healing**: Karpenter refills the buffer automatically
- **Cost-bounded**: You control exactly how much warm capacity to maintain
- **Works with any autoscaler**: The PriorityClass preemption is a Kubernetes-native mechanism
- **Configurable**: Adjust buffer replica count and resource requests to match your burst profile

### Combining both workarounds

The **best approach** combines both:
1. **Karpenter NodePool** with `workload-type: burst` label for right-sized provisioning
2. **Buffer pods** on those Karpenter-managed nodes for instant scheduling
3. When buffer is consumed, Karpenter refills it in ~2-3min (not 10-15min)

This gives you:
- **First burst**: instant (preempts buffers, ~10-20s including probe readiness)
- **Buffer refill**: fast (Karpenter, ~2-3min)
- **Sustained burst beyond buffer**: still fast (Karpenter provisions more, ~2-3min)
