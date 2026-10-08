# Tenant Workspace Factory: two local kind clusters, Crossplane v2 on the control plane,
# tenant workspaces rendered onto the fleet cluster through provider-kubernetes.

CP_CLUSTER    ?= control-plane-cluster
FLEET_CLUSTER ?= fleet-cluster-1
CP_CTX        ?= kind-$(CP_CLUSTER)
FLEET_CTX     ?= kind-$(FLEET_CLUSTER)

CROSSPLANE_VERSION     ?= 2.4.2
CROSSPLANE_CLI_VERSION ?= v2.5.0

KIND    ?= kind
KUBECTL ?= kubectl
HELM    ?= helm

# bash with pipefail: a failing command in the middle of a pipe fails the recipe,
# not only the last one (connect-fleet must not store an empty kubeconfig).
SHELL       := bash
.SHELLFLAGS := -eu -o pipefail -c

# The steps of `make up` depend on each other in order (cluster -> Crossplane -> packages -> XRD),
# so `make -j` must not run them side by side.
.NOTPARALLEL:

.PHONY: all
all: help

##@ General

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Environment

.PHONY: up
up: clusters crossplane packages connect-fleet platform ## Create everything: both clusters, Crossplane, provider, fleet connection, Workspace API.

.PHONY: clusters
clusters: ## Create both kind clusters (skips the ones that already exist).
	@for c in $(CP_CLUSTER) $(FLEET_CLUSTER); do \
		if $(KIND) get clusters | grep -qx "$$c"; then \
			echo "kind cluster $$c already exists"; \
		else \
			$(KIND) create cluster --config clusters/$$c.yaml; \
		fi; \
	done

.PHONY: down
down: ## Delete both kind clusters. Other kind clusters are left alone.
	$(KIND) delete cluster --name $(CP_CLUSTER)
	$(KIND) delete cluster --name $(FLEET_CLUSTER)

##@ Platform

CROSSPLANE_CHART_REPO ?= https://charts.crossplane.io/stable

.PHONY: crossplane
crossplane: ## Install Crossplane into the control-plane cluster with helm.
	$(HELM) upgrade --install crossplane crossplane \
		--repo $(CROSSPLANE_CHART_REPO) --version $(CROSSPLANE_VERSION) \
		--namespace crossplane-system --create-namespace \
		--kube-context $(CP_CTX) --wait

.PHONY: packages
packages: ## Install function-patch-and-transform and provider-kubernetes, wait until healthy.
	$(KUBECTL) --context $(CP_CTX) apply -f platform/functions.yaml -f platform/provider.yaml
	$(KUBECTL) --context $(CP_CTX) wait --for=condition=Healthy --timeout=5m \
		function/function-patch-and-transform provider/provider-kubernetes
	@# Healthy can flip to True before a bad runtime config crashes the pod, so also wait for the pod itself.
	$(KUBECTL) --context $(CP_CTX) -n crossplane-system wait --for=condition=Ready --timeout=3m \
		pod -l pkg.crossplane.io/provider=provider-kubernetes

.PHONY: connect-fleet
connect-fleet: ## Store the fleet kubeconfig in a Secret and create the ClusterProviderConfig.
	@# --internal gives the fleet API address inside the docker network kind (fleet-cluster-1-control-plane:6443),
	@# reachable from pods of the control-plane cluster. The kubeconfig stays in a shell variable and a pipe,
	@# it never hits the disk. If kind fails or prints nothing, stop before the Secret is overwritten.
	kubeconfig="$$($(KIND) get kubeconfig --internal --name $(FLEET_CLUSTER))"; \
	if [ -z "$$kubeconfig" ]; then echo "kind returned an empty kubeconfig for $(FLEET_CLUSTER)" >&2; exit 1; fi; \
	printf '%s\n' "$$kubeconfig" \
		| $(KUBECTL) --context $(CP_CTX) -n crossplane-system create secret generic $(FLEET_CLUSTER)-kubeconfig \
			--from-file=kubeconfig=/dev/stdin --dry-run=client -o yaml \
		| $(KUBECTL) --context $(CP_CTX) apply -f -
	$(KUBECTL) --context $(CP_CTX) apply -f platform/providerconfig.yaml

.PHONY: platform
platform: ## Apply the Workspace API: XRD, Composition and the developer role.
	$(KUBECTL) --context $(CP_CTX) apply -f platform/xrd.yaml
	$(KUBECTL) --context $(CP_CTX) wait --for=condition=Established --timeout=2m xrd/workspaces.platform.local
	$(KUBECTL) --context $(CP_CTX) apply -f platform/composition.yaml -f platform/rbac.yaml

##@ Test

# Offline checks: no cluster needed, only docker (render runs the function and Crossplane in containers).
# Images are pinned so the output does not change under us; the schema cache lives in ./bin.
CROSSPLANE_IMAGE ?= xpkg.crossplane.io/crossplane/crossplane:v$(CROSSPLANE_VERSION)
RENDER   = $(CROSSPLANE_CLI) composition render --include-full-xr --crossplane-image=$(CROSSPLANE_IMAGE) --xrd=platform/xrd.yaml
VALIDATE = $(CROSSPLANE_CLI) resource validate --cache-dir=$(LOCALBIN)/cache --crossplane-image=$(CROSSPLANE_IMAGE)
GOLDEN   = test/golden/workspace.yaml

.PHONY: test
test: $(CROSSPLANE_CLI) ## Render the example, diff against the golden file, validate schemas and CEL rules.
	@# The render output is deterministic (hashed names, fixed timestamps), so the whole file is compared.
	$(RENDER) examples/workspace.yaml platform/composition.yaml platform/functions.yaml | diff -u $(GOLDEN) -
	$(VALIDATE) --skip-success-results platform/xrd.yaml,platform/provider.yaml $(GOLDEN)
	@# Every file in examples/invalid breaks one CEL rule and must be rejected by that rule,
	@# not by some other error (e.g. a failed schema download). validate exits non-zero here on purpose,
	@# so its output is captured first instead of piped (pipefail would turn the pipe into a failure).
	@for f in examples/invalid/*.yaml; do \
		out="$$($(VALIDATE) platform/xrd.yaml $$f 2>&1 || true)"; \
		if grep -q 'CEL validation error' <<<"$$out"; then \
			echo "ok: $$f rejected by CEL"; \
		else \
			echo "FAIL: $$f was not rejected by a CEL rule"; exit 1; \
		fi; \
	done

.PHONY: test-update
test-update: $(CROSSPLANE_CLI) ## Regenerate the golden render output after an intended Composition change.
	@mkdir -p $(dir $(GOLDEN))
	$(RENDER) examples/workspace.yaml platform/composition.yaml platform/functions.yaml > $(GOLDEN)

##@ Tools

LOCALBIN ?= $(CURDIR)/bin
$(LOCALBIN):
	mkdir -p $@

OS   := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

# The version is part of the file name, so bumping CROSSPLANE_CLI_VERSION downloads a fresh binary.
CROSSPLANE_CLI ?= $(LOCALBIN)/crossplane-$(CROSSPLANE_CLI_VERSION)

.PHONY: crossplane-cli
crossplane-cli: $(CROSSPLANE_CLI) ## Download the Crossplane CLI into ./bin.
# Download into a temp file and rename it only on success, so an interrupted download
# does not leave a broken binary that make would treat as up to date.
$(CROSSPLANE_CLI): | $(LOCALBIN)
	curl -sSfL -o $@.tmp https://cli.crossplane.io/stable/$(CROSSPLANE_CLI_VERSION)/bin/$(OS)_$(ARCH)/crossplane
	chmod +x $@.tmp
	mv $@.tmp $@
