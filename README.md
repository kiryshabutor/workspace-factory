# workspace-factory

A self-service "Tenant Workspace Factory" built with Crossplane v2 on two local kind clusters.

A developer applies a small `Workspace` resource (tenant name, CPU and memory limits) to the
**control-plane cluster**. Crossplane turns it into three resources on the **fleet cluster**: the tenant
namespace, a ResourceQuota on that namespace and a welcome web app. If someone deletes or changes them on
the fleet, Crossplane puts them back within seconds. There is no controller code: the platform is an XRD
(the API), a Composition (what the API turns into) and off-the-shelf Crossplane packages.

```
control-plane-cluster                                fleet-cluster-1
┌──────────────────────────────────────┐            ┌──────────────────────────┐
│ ns default                           │            │                          │
│   Workspace frontend-dev-env  (XR)   │            │ Namespace dev-frontend   │
│        │ Composition workspace-fleet │            │   ResourceQuota          │
│        ▼ (function-patch-and-        │            │     workspace-quota      │
│           transform)                 │            │   Deployment welcome     │
│   Object (Namespace)     ────────────┼─kubeconfig─▶     (http-echo)          │
│   Object (ResourceQuota) ────────────┼────────────▶                          │
│   Object (Deployment)    ────────────┼────────────▶                          │
│                                      │            │                          │
│ ns crossplane-system                 │            │                          │
│   Crossplane, provider-kubernetes,   │            │                          │
│   Secret fleet-cluster-1-kubeconfig  │            │                          │
└──────────────────────────────────────┘            └──────────────────────────┘
```

Why it is built this way: [docs/design.md](docs/design.md). A full walk-through with measured timings:
[docs/demo-guide.md](docs/demo-guide.md).

## Quickstart

### Requirements

- Docker
- [kind](https://kind.sigs.k8s.io/)
- kubectl v1.36 or newer (the clusters run Kubernetes 1.37, and kubectl supports one minor version of skew)
- helm
- make, curl

Tested with kind v0.33.0 (Kubernetes v1.37.0, node image pinned by digest), helm v4.3.0, Docker 29.1.3,
Crossplane 2.4.2, provider-kubernetes v1.3.1, function-patch-and-transform v0.11.0, Crossplane CLI v2.5.0, and
kubectl v1.35.4 (outside the skew policy: it prints a warning, but everything worked).

### Run

```sh
# 0. Code: the solution lives in the workspace-factory branch
git clone -b workspace-factory https://github.com/kiryl-b-inno/inno-testtask.git
cd inno-testtask/workspace-factory

# 1. Both clusters, Crossplane, the function and the provider, the fleet connection, the Workspace API (~1.5 min)
make up

# 2. A Workspace, exactly the example from the task
kubectl --context kind-control-plane-cluster apply -f examples/workspace.yaml
kubectl --context kind-control-plane-cluster -n default wait --for=condition=Ready ws/frontend-dev-env --timeout=3m
kubectl --context kind-control-plane-cluster -n default get ws

# 3. What landed on the fleet
kubectl --context kind-fleet-cluster-1 -n dev-frontend get resourcequota,deploy,pods
kubectl --context kind-fleet-cluster-1 -n dev-frontend port-forward deploy/welcome 15678:5678 & pf=$!
curl --retry 10 --retry-connrefused --retry-delay 1 localhost:15678    # Welcome, dev-frontend!
kill $pf

# 4. Drift: delete the namespace on the fleet and watch it come back (usually ~10 s; Ready in 12-16 s, sometimes up to ~100 s)
kubectl --context kind-fleet-cluster-1 delete ns dev-frontend
kubectl --context kind-fleet-cluster-1 get ns dev-frontend -w

# 5. Clean up: only these two clusters are deleted, other kind clusters stay
make down
```

`kind create cluster` switches the current kubectl context, so every command names its context.
`make help` lists all targets.

### Offline checks

```sh
make test   # no cluster needed, only Docker
```

- renders `examples/workspace.yaml` through the Composition and diffs it against `test/golden/workspace.yaml`
  (`make test-update` regenerates it after an intended change);
- validates the rendered resources against the XRD and the provider-kubernetes CRDs;
- checks that every file in `examples/invalid/` is rejected by a CEL rule.

It does not validate the Deployment inside an Object: provider-kubernetes keeps the manifest as free-form
YAML, so a broken manifest is caught only by the fleet API server when the provider applies it.

## The Workspace API

```yaml
apiVersion: platform.local/v1
kind: Workspace
metadata:
  name: frontend-dev-env
  namespace: default
spec:
  parameters:
    tenantName: dev-frontend   # namespace on the fleet
    cpuLimit: "2"              # ResourceQuota limits.cpu
    memoryLimit: "4Gi"         # ResourceQuota limits.memory
```

The result on `fleet-cluster-1`:

| Resource | Details |
|---|---|
| `Namespace dev-frontend` | label `app.kubernetes.io/managed-by: crossplane`, annotation `platform.local/workspace: default/frontend-dev-env` |
| `ResourceQuota workspace-quota` | `limits.cpu: "2"`, `limits.memory: 4Gi` |
| `Deployment welcome` | `hashicorp/http-echo:1.0.0` answering `Welcome, dev-frontend!` on port 5678; 1 replica, limits 100m/128Mi, non-root, read-only root filesystem |

Validation runs in the API server (CEL rules in the XRD), so a bad Workspace is rejected on `kubectl apply`:

| Field | Rule |
|---|---|
| `tenantName` | a valid namespace name (DNS-1123 label, at most 63 characters) |
| `tenantName` | not a system namespace: `kube-*`, `default`, `local-path-storage` |
| `tenantName` | immutable: changing it would move the tenant to another namespace, so create a new Workspace instead |
| `cpuLimit`, `memoryLimit` | a Kubernetes quantity, at least `200m` / `256Mi` (room for two app pods during a rolling update) |
| `spec.crossplane.compositionUpdatePolicy` | `Automatic` only: the platform picks the Composition and rolls out its revisions |

`kubectl get ws` shows `TENANT`, `CPU` and `MEMORY` next to Crossplane's `SYNCED` and `READY`. A Workspace is
`READY` only when the app's rollout on the fleet is complete (every replica runs the current template and is
available), not merely when the manifests were accepted.

## Deviation from the task: provider-kubernetes

The task asks for **no provider-kubernetes `Object` wrappers**, but also for resources on a **different
cluster** and a **Namespaced XR**. These cannot all hold at once:

- Crossplane composes resources natively only into the cluster it runs in. Reaching another cluster takes a
  provider with a kubeconfig, and the "Kubernetes Secrets containing target Kubeconfigs" from the task's
  design are exactly provider-kubernetes credentials.
- A Namespaced XR composes only namespaced resources in its own namespace. The tenant Namespace is
  cluster-scoped, and the quota and the app belong in `dev-frontend`, not in the Workspace's namespace.

I asked the interviewer and got the answer that provider-kubernetes is the best option. The solution uses its
**namespaced** `Object` (`kubernetes.m.crossplane.io`, new in Crossplane v2), not the legacy cluster-scoped
`kubernetes.crossplane.io` wrapper. The Objects live next to the Workspace, so the Namespaced XR rule holds.
Details: [docs/design.md](docs/design.md#1-delivery-to-the-fleet-provider-kubernetes).

## Layout

```
Makefile                     up / down / test and the steps behind them
clusters/                    kind configs (node image pinned by digest)
platform/
  functions.yaml             function-patch-and-transform
  provider.yaml              provider-kubernetes + DeploymentRuntimeConfig (watches, poll)
  providerconfig.yaml        ClusterProviderConfig fleet-cluster-1
  xrd.yaml                   Workspace API with CEL validation
  composition.yaml           Workspace -> three Objects on the fleet
  rbac.yaml                  ClusterRole workspace-developer
examples/
  workspace.yaml             the example from the task
  developer-rolebinding.yaml grants workspace-developer to user frontend-dev in default
  invalid/                   one CEL violation per file
test/golden/workspace.yaml   expected render output
docs/                        design and demo guide
```

The fleet kubeconfig is never written to disk or git: `make connect-fleet` pipes
`kind get kubeconfig --internal` straight into a Secret.

## Known limitations

- **Two Workspaces with the same `tenantName`** (in different namespaces) would fight over one fleet
  namespace. CEL sees only the object being validated, so it cannot catch this; it would take an admission
  webhook or a policy engine. The `platform.local/workspace` annotation on the fleet resources shows which
  Workspace owns them.
- **The fleet credentials are cluster-admin** (the kubeconfig kind generates). Production would use a
  ServiceAccount on the fleet limited to namespaces, quotas and deployments.
- **Watches are an alpha feature** of provider-kubernetes. `--poll=1m` keeps drift correction working if a
  watch drops; without watches, drift is fixed on the next poll instead of within seconds.
- **Deleting the XRD deletes every Workspace** and, with the default delete behaviour, every tenant namespace
  on the fleet. The app is stateless, so re-applying brings everything back; only platform admins may change
  the XRD and the Composition (developers get `workspace-developer` only).
- **Plain `kubectl delete ws` returns before the fleet is clean**; use `--cascade=foreground` to wait for it.
  Re-creating the same Workspace right after a background delete waits until the old Objects are gone.
- **Back-to-back drift** opens Crossplane's per-XR circuit breaker: the fleet is still repaired in seconds,
  but the Workspace's `READY` catches up on the next poll, up to a minute later. See the
  [demo guide](docs/demo-guide.md#5-drift-delete-the-tenant-namespace-on-the-fleet).
