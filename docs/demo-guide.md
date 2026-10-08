# Demo guide

A step-by-step walk through the platform: create a Workspace, see it land on the fleet cluster,
break things on the fleet and watch Crossplane put them back. Timings were measured on a laptop
with kind v0.33.0 (Kubernetes v1.37.0), Crossplane 2.4.2 and provider-kubernetes v1.3.1.

All commands run from `workspace-factory/`. Every `kubectl` call names its context explicitly,
because `kind create cluster` switches the current context.

```bash
# Functions, not variables: zsh does not split "$CP" into words.
cpk()   { kubectl --context kind-control-plane-cluster "$@"; }
fleet() { kubectl --context kind-fleet-cluster-1 "$@"; }
```

## 1. Bring the environment up

```bash
make up    # ~1.5 min from scratch: two kind clusters, Crossplane, function, provider, fleet connection, Workspace API
cpk get xrd,compositions
cpk get providers,functions
```

Expected: the XRD `workspaces.platform.local` is `ESTABLISHED=True`, the provider and the function are
`INSTALLED=True HEALTHY=True`. `OFFERED` is empty: Crossplane v2 has no claims.

## 2. Create a Workspace

```bash
cpk apply -f examples/workspace.yaml
cpk -n default wait --for=condition=Ready ws/frontend-dev-env --timeout=3m
cpk -n default get ws
cpk -n default get objects.kubernetes.m.crossplane.io
```

Expected: `SYNCED=True READY=True`, three Objects (Namespace, ResourceQuota, Deployment), all Ready.
The first Workspace after `make up` takes ~25 s (Crossplane starts the XR controller and the function,
the node pulls the image); later ones take a few seconds.

Use the full name `objects.kubernetes.m.crossplane.io`: provider-kubernetes also installs the legacy
cluster-scoped `objects.kubernetes.crossplane.io`, and a bare `kubectl get object` resolves to that one.

The resource tree:

```bash
make crossplane-cli    # downloads the CLI into ./bin once; make up does not need it
./bin/crossplane-v2.5.0 resource trace --context kind-control-plane-cluster -n default workspace.platform.local/frontend-dev-env
```

```
NAME                                                SYNCED   READY   STATUS
Workspace/frontend-dev-env (default)                True     True    Available
├─ Object/frontend-dev-env-...   (default)          True     True    Available
├─ Object/frontend-dev-env-...   (default)          True     True    Available
└─ Object/frontend-dev-env-...   (default)          True     True    Available
```

## 3. Check the fleet cluster

```bash
fleet -n dev-frontend get resourcequota,deploy,pods
fleet -n dev-frontend port-forward deploy/welcome 15678:5678 & pf=$!
curl --retry 10 --retry-connrefused --retry-delay 1 localhost:15678    # port-forward needs a moment to listen
kill $pf
```

Expected: quota `limits.cpu: 100m/2, limits.memory: 128Mi/4Gi` (the app pod uses 100m/128Mi),
one `welcome` pod Running, and `curl` prints `Welcome, dev-frontend!`.

## 4. Change a parameter

```bash
cpk -n default patch ws frontend-dev-env --type=merge -p '{"spec":{"parameters":{"cpuLimit":"4"}}}'
fleet -n dev-frontend get resourcequota workspace-quota
```

Expected: `limits.cpu` becomes `4` on the fleet in under a second. Put it back with
`cpk apply -f examples/workspace.yaml`.

A broken template (platform side). `READY` means the rollout is complete, not only that some pod serves:

```bash
sed 's#http-echo:1.0.0#http-echo:0.0.0-broken#' platform/composition.yaml | cpk apply -f -
sleep 30; fleet -n dev-frontend get pods; cpk -n default get ws
cpk apply -f platform/composition.yaml
cpk -n default wait --for=condition=Ready ws/frontend-dev-env --timeout=2m
```

Expected: the new pod is in `ErrImagePull` / `ImagePullBackOff`, the old one keeps `Running` and serving, and the Workspace
is `READY=False`. After the good Composition is back, the broken ReplicaSet is scaled down and the Workspace
is Ready again within seconds.

## 5. Drift: delete the tenant namespace on the fleet

In one terminal:

```bash
fleet get ns dev-frontend -w
```

In another:

```bash
fleet delete ns dev-frontend
```

Measured timeline:

| Time | Fleet | Workspace |
|---|---|---|
| 0 s | namespace `Terminating` | `READY=True` |
| ~5 s | pod gone | `READY=False` |
| ~10 s | namespace re-created (new UID), quota back | `READY=False` |
| ~12-16 s | Deployment available again | `READY=True` |

Four of six measured runs (with the circuit breaker closed) took 12-16 s. Two runs, each the first drift
after the Workspace was created, were slow: the namespace took ~25 s to delete instead of ~10 s, and the
Workspace was Ready at ~57 s and ~101 s. The timestamps of the second one show why: the Deployment Object was
Ready 2 s after the namespace came back, but the ResourceQuota Object was re-created only ~16 s later and
marked Ready only on the next poll a minute after that. While the namespace is `Terminating`, the provider's
attempts to create the quota in it fail and its retries back off. The app itself serves again within
seconds of the namespace coming back; only the Workspace's `READY` lags.

Why it is fast: provider-kubernetes runs with `--enable-watches` and every Object has `spec.watch: true`,
so the provider sees the deletion as it happens. `--poll=1m` is the fallback if a watch drops.

Why it is not instant: Kubernetes has to finish deleting the namespace first; while it is `Terminating`
nothing can be created in it, and the provider retries (events `CannotCreateExternalResource ...
unable to create new content in namespace`). This is expected, not an error to fix.

Several deletions in a row: Crossplane v2 protects itself with a per-XR circuit breaker (100 events,
refilled at 1 per second). Back-to-back drift generates enough events to open it; the Workspace then
shows `Responsive=False WatchCircuitOpen` and its `READY` catches up on the next poll, up to a minute
later. The fleet resources are still restored in seconds, because that is the provider's job, not the
XR's. Wait a minute between drift demos to avoid it.

## 6. Drift: change a field on the fleet

```bash
fleet -n dev-frontend scale deploy/welcome --replicas=3
fleet -n dev-frontend get events --field-selector involvedObject.kind=Deployment
```

Expected: the provider sets `replicas` back to 1 within the same second
(`Scaled up ... from 1 to 3`, then `Scaled down ... from 3 to 1`).

## 7. Validation (CEL)

```bash
for f in examples/invalid/*.yaml; do cpk apply -f $f; done
cpk -n default patch ws frontend-dev-env --type=merge -p '{"spec":{"parameters":{"tenantName":"other"}}}'
```

Expected: every request is rejected by the API server with its own message, for example
`tenantName must not be a system namespace` or `memoryLimit must be at least 256Mi`.
Changing `tenantName` fails with `tenantName is immutable; create a new Workspace instead`.

The same checks run offline, without a cluster:

```bash
make test
```

## 8. Developer permissions

```bash
cpk apply -f examples/developer-rolebinding.yaml
cpk auth can-i create workspaces.platform.local -n default --as=frontend-dev            # yes
cpk auth can-i create objects.kubernetes.m.crossplane.io -n default --as=frontend-dev   # no
cpk auth can-i get secrets -n crossplane-system --as=frontend-dev                       # no
```

The developer may patch the Workspace, but not choose what it turns into:

```bash
cpk -n default patch ws frontend-dev-env --as=frontend-dev --type=merge \
  -p '{"spec":{"crossplane":{"compositionRef":{"name":"something-else"}}}}'
sleep 3; cpk -n default get ws frontend-dev-env -o jsonpath='{.spec.crossplane.compositionRef.name}{"\n"}'
cpk -n default patch ws frontend-dev-env --as=frontend-dev --type=merge \
  -p '{"spec":{"crossplane":{"compositionUpdatePolicy":"Manual"}}}'
```

Expected: the first patch is accepted, but Crossplane puts `workspace-fleet` back (`enforcedCompositionRef`).
The second is rejected by CEL: `compositionUpdatePolicy must be Automatic`.

## 9. Delete the Workspace

```bash
cpk -n default delete ws frontend-dev-env --cascade=foreground
fleet get ns dev-frontend    # NotFound
```

With `--cascade=foreground` the command returns only after the fleet is clean (~40 s, mostly namespace
termination). A plain `delete` returns at once and the cleanup continues in the background; creating the
same Workspace again right away then waits until the old Objects are gone (their names are derived from
the Workspace, so they collide), which took about two minutes in testing.

## 10. Tear down

```bash
make down    # deletes control-plane-cluster and fleet-cluster-1 only
```
