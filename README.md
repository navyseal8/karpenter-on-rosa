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

```
┌─────────────────────────────────────────────────────────────────────┐
│                        ROSA HCP Cluster                            │
│                                                                     │
│  ┌──────────────────┐   ┌──────────────────┐   ┌────────────────┐  │
│  │ ClusterAutoScaler │   │ Karpenter        │   │ Scheduler      │  │
│  │ (CA + CAPI)       │   │ (AutoNode)       │   │ (Preemption)   │  │
│  │                   │   │                  │   │                │  │
│  │ Pending Pod       │   │ Pending Pod      │   │ High-priority  │  │
│  │    ↓              │   │    ↓             │   │ pod arrives    │  │
│  │ Scale MachineSet  │   │ CreateFleet API  │   │    ↓           │  │
│  │    ↓              │   │    ↓             │   │ Preempts       │  │
│  │ CAPI → EC2        │   │ EC2 direct       │   │ buffer pod     │  │
│  │    ↓              │   │    ↓             │   │    ↓           │  │
│  │ Bootstrap + CSR   │   │ Fast bootstrap   │   │ Instant start  │  │
│  │    ↓              │   │    ↓             │   │                │  │
│  │ ⏱️  10-15 min      │   │ ⏱️  2-3 min       │   │ ⏱️  5-15 sec    │  │
│  └──────────────────┘   └──────────────────┘   └────────────────┘  │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ Worker Nodes                                                │   │
│  │                                                             │   │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐       │   │
│  │  │ Node 1  │  │ Node 2  │  │ Node 3  │  │ Node 4  │       │   │
│  │  │ (base)  │  │ (base)  │  │ (burst) │  │ (burst) │       │   │
│  │  │         │  │         │  │ buffer  │  │ buffer  │       │   │
│  │  │ system  │  │ system  │  │ pods ↔  │  │ pods ↔  │       │   │
│  │  │ pods    │  │ pods    │  │ real    │  │ real    │       │   │
│  │  └─────────┘  └─────────┘  └─────────┘  └─────────┘       │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

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

### Step 2: Enable Karpenter AutoNode (if not already enabled)

```bash
export CLUSTER_NAME=<your-cluster-name>
bash 02-karpenter-autonode/00-enable-autonode.sh
```

### Step 3: Deploy Karpenter NodePool

```bash
# Edit 02-karpenter-autonode/01-nodepool.yaml — replace ${CLUSTER_NAME}
oc apply -f 02-karpenter-autonode/01-nodepool.yaml
```

### Step 4: Deploy all workloads (at 0 replicas) and PDBs

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

### Step 5: Wait for buffer pods to become Ready

```bash
oc get pods -n scaling-poc -l app.kubernetes.io/name=capacity-placeholder -w
```

### Step 6: Run the comparison tests

```bash
chmod +x scripts/*.sh
# Scale to 4 replicas (≥2 for HA, spreads across 2+ zones/nodes)
./scripts/run-all-tests.sh 4
```

## Running Individual Tests

### Test 1: Prove ClusterAutoScaler takes 10-15 min

```bash
# Scale to 4 replicas — these won't fit on existing nodes
oc scale deployment/burst-workload-cas -n scaling-poc --replicas=4

# Watch pods stay Pending for 10-15 minutes
oc get pods -n scaling-poc -l app.kubernetes.io/instance=cas-baseline -w

# Verify PDB is protecting running pods
oc get pdb -n scaling-poc

# Measure with script
./scripts/measure-scale-time.sh burst-workload-cas scaling-poc 4
```

### Test 2: Karpenter AutoNode right-sizing

```bash
# Scale to 4 replicas — Karpenter provisions optimal instances
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
# Verify buffer pods are Running and spread across nodes
oc get pods -n scaling-poc -l app.kubernetes.io/name=capacity-placeholder -o wide

# Scale real workload — buffer pods preempted instantly
oc scale deployment/burst-workload-preempt -n scaling-poc --replicas=4

# Watch instant scheduling!
oc get pods -n scaling-poc -l app.kubernetes.io/instance=buffer-preempt -w

# Verify PDB protects running pods during any disruption
oc get pdb -n scaling-poc
```

## Expected Results

| Approach | Time to all pods Ready | Relative Speed |
|----------|------------------------|----------------|
| ClusterAutoScaler (CAPI) | 10-15 minutes | 1x (baseline) |
| Karpenter AutoNode | 2-3 minutes | ~5x faster |
| Buffer + Preemption | 10-20 seconds* | ~50-80x faster |

\* *Includes ~5s startup probe + ~5s readiness probe pass time on pre-warmed nodes*

## Cleanup

```bash
./scripts/cleanup.sh
```

## File Structure

```
.
├── README.md                                  # This file
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
| **≥2 replicas** | `replicas: 4` (scale target) | Survive single-pod failure |
| **PodDisruptionBudget** | `minAvailable: 1` | Prevent voluntary disruptions from killing all pods |
| **Startup probe** | `test -f /tmp/healthy` | Allow slow-starting containers without liveness kills |
| **Readiness probe** | `test -f /tmp/ready` | Only receive traffic when truly ready |
| **Liveness probe** | `test -f /tmp/healthy` | Restart stuck containers automatically |
| **TopologySpreadConstraints** | Zone + hostname spread | Survive AZ outage; spread across nodes |
| **Guaranteed QoS** | requests = limits (memory) | Prevent OOM kills and noisy neighbours |
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
