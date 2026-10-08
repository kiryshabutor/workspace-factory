# Design

Why the Tenant Workspace Factory is built the way it is. Each section states the decision, the reason
and the alternatives that were rejected. Measured behaviour is in the [demo guide](demo-guide.md).

## Contents

1. [Delivery to the fleet: provider-kubernetes](#1-delivery-to-the-fleet-provider-kubernetes)
2. [Two clusters and how they reach each other](#2-two-clusters-and-how-they-reach-each-other)
3. [Fleet credentials: ClusterProviderConfig](#3-fleet-credentials-clusterproviderconfig)
4. [The Workspace API and CEL validation](#4-the-workspace-api-and-cel-validation)
5. [ResourceQuota on limits only](#5-resourcequota-on-limits-only)
6. [The Composition](#6-the-composition)
7. [Readiness](#7-readiness)
8. [Drift: watches plus poll](#8-drift-watches-plus-poll)
9. [Deletion](#9-deletion)
10. [The app](#10-the-app)
11. [Developer RBAC](#11-developer-rbac)
12. [Versions](#12-versions)
13. [Tests](#13-tests)

## How a change flows

A developer changes `cpuLimit` from `"2"` to `"4"`:

```
1. kubectl apply      Workspace (XR) on the control plane now says cpuLimit: "4"
2. Crossplane         the XR controller (generated from the XRD) sees the change
3. Composition        function-patch-and-transform returns the desired three Objects,
                      the quota Object now carries limits.cpu: "4"
4. Crossplane         updates the Object on the control plane
5. provider-kubernetes sees the Object change and applies its manifest on the fleet
```

Two controllers in a chain: Crossplane (Workspace → Objects) and the provider (Objects → fleet). Measured
end to end: under a second.

## 1. Delivery to the fleet: provider-kubernetes

**Decision.** The Composition creates three **namespaced** provider-kubernetes `Object`s
(`kubernetes.m.crossplane.io/v1alpha1`), one per fleet resource, with the fleet manifest in
`spec.forProvider.manifest`.

**Why.** The task contradicts itself. It asks for:

- resources on another cluster (`fleet-cluster-1`), reached through "Kubernetes Secrets containing target
  Kubeconfigs";
- a Namespaced XR;
- no provider-kubernetes `Object` wrappers.

Native composition writes only to the cluster Crossplane runs in, and a Namespaced XR may compose only
namespaced resources in its own namespace. The tenant Namespace is cluster-scoped and the quota and the app
must live in `dev-frontend`, so not one of the three resources can be composed natively, even on the same
cluster. Reaching another cluster with a kubeconfig is precisely what provider-kubernetes does. The
interviewer confirmed that provider-kubernetes is the best option.

The "legacy wrapper" the task warns about is the cluster-scoped `kubernetes.crossplane.io` `Object` from
Crossplane v1. This solution uses the namespaced v2 one: the Objects live next to the Workspace, so the
Namespaced XR rule holds and a developer's Objects stay in their namespace.

**Rejected.**

- *Compose natively without the provider*: impossible for the reasons above.
- *Cluster-scoped XR*: would allow composing a Namespace, but still only on the local cluster, and breaks
  the task's Namespaced XR requirement.

## 2. Two clusters and how they reach each other

**Decision.** Two kind clusters, `control-plane-cluster` (Crossplane) and `fleet-cluster-1` (tenants). The
provider uses the kubeconfig from `kind get kubeconfig --internal --name fleet-cluster-1`.

**Why two clusters.** The control plane survives a broken or overloaded fleet and vice versa; developers get
access to the control plane only, never to the fleet; one control plane can drive many fleet clusters (a
new cluster is one more Secret and ProviderConfig).

**Why `--internal`.** The usual kind kubeconfig points at `https://127.0.0.1:<port>`, a port forwarded to
the laptop. Inside the provider pod `127.0.0.1` is the pod itself. All kind nodes are containers on the
docker network `kind` and resolve each other by container name, so the internal kubeconfig's
`https://fleet-cluster-1-control-plane:6443` is reachable from the control-plane pods, and the API server
certificate includes that name. No extra networking is needed.

**Observed.** If the host's `/etc/resolv.conf` has a search domain whose DNS server does not answer, pods
try `fleet-cluster-1-control-plane.<domain>` first and wait for a timeout. `curl` in a pod gives up on that
error; the provider (Go resolver) moves on to the bare name and connects. No workaround was needed.

## 3. Fleet credentials: ClusterProviderConfig

**Decision.** One cluster-scoped `ClusterProviderConfig fleet-cluster-1` reading the Secret
`crossplane-system/fleet-cluster-1-kubeconfig`. `make connect-fleet` pipes the internal kubeconfig into the
Secret; it never touches the disk or git. The Makefile runs recipes in `bash -o pipefail`, and the recipe
stops if `kind` fails or prints an empty kubeconfig: in a plain `sh` pipe only the last command counts, so a
failed `kind get kubeconfig` would overwrite a working Secret with an empty one and `make` would exit 0. Every Object names it explicitly in `providerConfigRef`
(the CRD default is `{kind: ClusterProviderConfig, name: default}`, which does not exist here).

**Why.** The credentials stay with the platform team in `crossplane-system`; developers cannot read them
(see [RBAC](#11-developer-rbac)).

**Rejected.** *A namespaced `ProviderConfig` plus Secret in each developer namespace*: every tenant
namespace would hold a cluster-admin kubeconfig of the fleet, readable by anyone who can read Secrets there.

**Limitation.** The kubeconfig is the cluster-admin one kind generates. Production would use a fleet
ServiceAccount allowed to manage only namespaces, quotas and deployments.

## 4. The Workspace API and CEL validation

**Decision.** XRD `workspaces.platform.local`, `apiextensions.crossplane.io/v2`, `scope: Namespaced`,
version `v1`; `spec.parameters.tenantName`, `cpuLimit`, `memoryLimit`, all required strings.
`enforcedCompositionRef: workspace-fleet` (developers don't pick a Composition, see below), short name `ws`,
printer columns `TENANT`, `CPU`, `MEMORY`.

Validation is CEL in the XRD, so the API server rejects a bad Workspace on `kubectl apply`, instead of the
error surfacing later on the fleet:

| Field | Rule | Why |
|---|---|---|
| `tenantName` | `self.matches('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')`, `maxLength: 63` | it becomes a namespace name (DNS-1123 label) |
| `tenantName` | not `kube-*`, `default`, `local-path-storage` | a developer must not take over a system namespace; with delete-on-delete, removing the Workspace would delete it |
| `tenantName` | `self == oldSelf` | a new name would create a second namespace and delete the first one with the tenant's app; create a new Workspace instead |
| `cpuLimit`, `memoryLimit` | `isQuantity(self)` | a typo ("two cores") fails on apply, not on the fleet |
| `cpuLimit`, `memoryLimit` | `!isQuantity(self) \|\| quantity(self).compareTo(quantity('200m')) >= 0` (`256Mi` for memory) | the app needs room for two pods during a rolling update (2 × 100m / 128Mi) |
| `spec` | `self.crossplane.compositionUpdatePolicy == 'Automatic'` (if set), no `self.crossplane.compositionRevisionSelector` | a developer must not pin an old revision of the Composition, see below |

Details that matter:

- `quantity()` on an invalid string is an evaluation error, not `false`, so the minimum rule is guarded by
  `!isQuantity(self) ||` and the format gets its own rule and message.
- Every string has `maxLength`: without it the API server estimates the `matches()` cost as unbounded and
  rejects the XRD ("estimated rule cost exceeds budget").
- `self == oldSelf` on a field is a transition rule: it runs on updates only.

**Who picks the Composition.** A developer may patch their Workspace, and RBAC cannot hide single fields,
so with `defaultCompositionRef` they could set `spec.crossplane.compositionRef` to any other Composition in
the cluster (checked: `frontend-dev` switched a Workspace to a test Composition and the app on the fleet
changed). With `enforcedCompositionRef` Crossplane resets the field on the next reconcile. The enforced ref
does not cover revisions. A developer could still pin an old or broken revision of `workspace-fleet` in two
ways: `compositionUpdatePolicy: Manual` with `compositionRevisionRef`, or a `compositionRevisionSelector`
matching the `crossplane.io/composition-hash` label of an old revision (with `Automatic`, Crossplane picks
the newest revision among those the selector matches). So the CEL rules on `spec` allow only `Automatic` and
no selector. `compositionRevisionRef` itself stays allowed, because Crossplane writes it. What CEL does not
stop is the `crossplane.io/paused` annotation (see Known limitations in the README). The price: `enforcedCompositionRef` is immutable in the XRD. Template changes go into new
revisions of `workspace-fleet`, which is the normal path; moving to a Composition with another name would
mean recreating the XRD, and that deletes every Workspace.

**Limitation.** CEL sees only the object being validated, so two Workspaces with the same `tenantName` in
different namespaces are not caught; they would fight over one fleet namespace. That needs an admission
webhook or a policy engine. The `platform.local/workspace: <namespace>/<name>` annotation on every fleet
resource shows the owner.

## 5. ResourceQuota on limits only

**Decision.** `ResourceQuota workspace-quota` with `limits.cpu` and `limits.memory` from the Workspace,
no `requests.*`.

**Why.** The task gives one CPU and one memory number, which caps what the namespace may consume at most,
i.e. limits. A quota on `limits.*` forces every pod in the namespace to declare limits, so nothing can run
unbounded. Consequence: the Deployment must set limits (100m / 128Mi), and the minimums in CEL leave room
for a second pod during a rolling update.

**Rejected.** *Quota on requests too*: would need numbers the task does not give, or derived ones that the
developer never sees.

## 6. The Composition

**Decision.** `Composition workspace-fleet`, `mode: Pipeline`, one step with `function-patch-and-transform`
producing three Objects:

```
render-fleet-resources (function-patch-and-transform)
├── namespace      tenantName -> manifest.metadata.name
├── resourcequota  tenantName -> manifest.metadata.namespace, cpuLimit / memoryLimit -> spec.hard
└── deployment     tenantName -> manifest.metadata.namespace, "-text=Welcome, %s!" -> args[0]
```

- `FromCompositeFieldPath` copies a Workspace field into the manifest; `CombineFromComposite` with a string
  format builds the app argument and the owner annotation.
- Quota keys contain a dot, so the path uses brackets: `spec.hard[limits.cpu]`.
- The Objects have no `metadata.name` or `namespace` in the base: Crossplane generates the name and places
  them in the Workspace's namespace.
- Fixed in each Object: `providerConfigRef`, `watch: true`, and `readiness` where needed.

**Rejected.**

- *`function-auto-ready`*: not needed. Patch-and-transform already treats a composed resource as ready when
  it has `Ready=True`, and the provider sets that on each Object according to its readiness policy.
- *Go templating or KCL functions*: more power than three static manifests with four substitutions need,
  and harder to read.

## 7. Readiness

**Decision.**

| Object | `spec.readiness.policy` | Why |
|---|---|---|
| Deployment | `DeriveFromCelQuery`: the rollout is complete, the same checks as `kubectl rollout status`: `status.observedGeneration == metadata.generation`, `updatedReplicas == spec.replicas`, `replicas == updatedReplicas`, `availableReplicas == updatedReplicas` | the Workspace is Ready only when the current template actually serves |
| Namespace, ResourceQuota | default `SuccessfulCreate` | they have no conditions; created means done |

**Why.** With the default, a wrong image or a pod that does not fit the quota would leave the Workspace
`READY=True` with the app down. Now the chain is honest: rollout complete → Object Ready → Workspace Ready.

Checking only the `Available=True` condition is not enough: when a new Composition revision brings a broken
template, the old pod keeps serving, `Available` stays `True`, and the Workspace said `READY=True` while the
new pod was in `ImagePullBackOff`. With the rollout checks the same scenario gives `READY=False` while the old
pod still serves (checked by applying a Composition with a nonexistent image tag). The Deployment controller
omits zero counters from `status`, so every counter is guarded with `has()`.

**Rejected.** *`DeriveFromObject`*: it looks for a `Ready` condition, which a Deployment does not have
(only `Available` and `Progressing`), so the Object would never become Ready.

## 8. Drift: watches plus poll

**Decision.** The provider runs with `--enable-watches` and `--poll=1m` (set through a
`DeploymentRuntimeConfig`; the container must be named `package-runtime`, otherwise Crossplane adds it as
a sidecar), and every Object has `spec.watch: true`.

**Why.** By default the provider re-checks the fleet every 10 minutes: a deleted namespace would stay gone
that long. With watches it sees the change immediately. Measured: a deleted namespace is back in ~10 s and
the Workspace is Ready again in 12-16 s in four of six runs (most of it is Kubernetes finishing the
namespace deletion). Two runs took ~57 s and ~101 s: the namespace was `Terminating` longer, the provider's
retries to re-create the ResourceQuota in it backed off, and the quota Object became Ready only on the next
poll (see the [demo guide](demo-guide.md#5-drift-delete-the-tenant-namespace-on-the-fleet)); a manual
`scale --replicas=3` is reverted within the same second. The poll is a safety net for events lost while a
watch connection is down.

**Details.**

- `--enable-watches` is a boolean flag; `--enable-watches=true` makes the provider exit with
  `unexpected true`. Worse, the Provider reported `HEALTHY=True` before the pod crashed, so `make packages`
  also waits for the provider pod to be Ready.
- `spec.watch` is an alpha field and does nothing without the flag.
- Crossplane v2 has a per-XR circuit breaker (100 events, refilled at 1 per second, 5 minute cooldown).
  Back-to-back drift opens it: the fleet is still repaired by the provider in seconds, but the Workspace's
  status catches up on the next XR poll (up to a minute). The defaults are kept; the breaker protects
  Crossplane from hot loops.

**Rejected.** *Poll only*: correct, but drift lasts up to the poll interval. It stays the fallback, and is
the safer choice in production while watches are alpha.

## 9. Deletion

**Decision.** Deleting a Workspace deletes its resources on the fleet.

Namespaced managed resources in Crossplane v2 have no `deletionPolicy`; it was replaced by
`managementPolicies`, whose default `["*"]` includes Delete. So this is the default, nothing is set.

| Case | Delete (chosen) | Orphan |
|---|---|---|
| A developer deletes a Workspace | the fleet is clean | abandoned namespaces with running apps pile up |
| Someone deletes the XRD | every tenant namespace on the fleet goes | the fleet keeps running, only management is lost |

**Why.** Self-service means "remove it yourself" too. The app is stateless, so even the XRD accident is
recoverable by re-applying. The XRD and the Composition are changed by platform admins only. With data in
the namespaces (databases, PVCs), Orphan on at least the Namespace would be the safer choice.

**Observed.**

- A plain `kubectl delete ws` returns in about a second while the Objects and the fleet namespace are
  deleted in the background. The Objects are owned by the Workspace with `blockOwnerDeletion: true`, so
  `kubectl delete ws ... --cascade=foreground` waits until the fleet is clean (~40 s, mostly namespace
  termination).
- Object names are derived from the Workspace, so re-creating the same Workspace right after a background
  delete waits until the old Objects are gone (about two minutes in testing). After a foreground delete it
  is Ready in seconds.
- Crossplane v2 has no XR-level delete policy (`defaultCompositeDeletePolicy` in the XRD applies to claims,
  which v2 dropped).

## 10. The app

**Decision.** `hashicorp/http-echo:1.0.0` with `-text=Welcome, <tenantName>!`, one replica, requests
50m / 64Mi, limits 100m / 128Mi, readiness probe on `/`, no Service.

**Why.** `curl` shows the tenant name that travelled from the Workspace on the control plane to the pod on
the fleet. The image is tiny and already runs as a non-root user (uid 65532, distroless), so the pod sets
`runAsNonRoot: true`, a read-only root filesystem, no privilege escalation, all capabilities dropped and
the RuntimeDefault seccomp profile. The task asks for three resources, so there is no Service; check it with
`kubectl port-forward`.

**Rejected.** *nginx*: the same page for every tenant, proves nothing. *podinfo*: far more than needed.

## 11. Developer RBAC

**Decision.** `ClusterRole workspace-developer`, bound per namespace with a RoleBinding
(`examples/developer-rolebinding.yaml`):

- `workspaces.platform.local`: get, list, watch, create, update, patch, delete;
- `objects.kubernetes.m.crossplane.io` and `events`: read only, to see why a Workspace is not Ready.

**Why not a built-in role.** Crossplane v2 aggregates XR permissions not into Kubernetes' `edit` but into its
own `crossplane-edit`, which also aggregates provider-kubernetes permissions, including **creating Objects**.
A developer who can create an Object can put any manifest on the fleet through the `fleet-cluster-1`
ClusterProviderConfig, bypassing the Workspace API. Kubernetes' `edit` in turn does not include Workspaces
and does include reading Secrets.

Checked with impersonation: `frontend-dev` can create Workspaces in `default` but not in `kube-system`, can
read but not create Objects, and cannot read Secrets or create ProviderConfigs and Compositions.

## 12. Versions

Everything is pinned: the kind node image by digest, the Crossplane chart, the packages, the CLI, and the
Crossplane image that `crossplane composition render` and `resource validate` run (they default to
`crossplane:stable`).

| Component | Version | Note |
|---|---|---|
| kind | v0.33.0 | node `kindest/node:v1.37.0@sha256:a1ed56cf...`, the kind default |
| Crossplane | 2.4.2 (Helm chart) | |
| provider-kubernetes | v1.3.1 | v1.4.0 was released a day before this work and changes defaults (watches on by default, failing start without readable ProviderConfigs); the flags are set explicitly anyway |
| function-patch-and-transform | v0.11.0 | |
| Crossplane CLI | v2.5.0 | downloaded into `./bin` by the Makefile |
| kubectl | v1.36+ recommended | tested with v1.35.4, one minor outside the ±1 skew policy for Kubernetes 1.37: it prints a warning, everything worked |

## 13. Tests

`make test` runs without a cluster (Docker only):

1. `crossplane composition render --include-full-xr` on the example, diffed against
   `test/golden/workspace.yaml`. The output is deterministic (Object names are hashes of the Workspace and
   the resource name, timestamps are fixed), so the whole file is compared. `--include-full-xr` is needed,
   otherwise the XR is printed without `spec` and fails validation.
2. `crossplane resource validate` of the render against the XRD and the provider-kubernetes CRDs.
3. Every `examples/invalid/*.yaml` must fail with a `CEL validation error`, not with any error, so a failed
   schema download does not count as a pass.

Breaking the Composition (changing the greeting) or "fixing" an invalid example makes `make test` fail.

The boundary: `resource validate` checks an Object against the provider's CRD, where `forProvider.manifest`
is free-form (`x-kubernetes-preserve-unknown-fields`). The Deployment inside is not validated: a golden file
with `replicas: definitely-not-an-integer` passes. Such a manifest is rejected only by the fleet API server
when the provider applies it. Catching it offline would take the Kubernetes OpenAPI schemas and a second tool
(e.g. kubeconform on the extracted manifests); `make test` stays with the Crossplane CLI only.
The transition rule `self == oldSelf` cannot be checked offline; it is covered in the demo guide. The live
behaviour (Ready, drift, deletion) is checked by hand following the [demo guide](demo-guide.md); there is no
automated end-to-end test or CI.
