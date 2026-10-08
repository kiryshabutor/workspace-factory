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

.PHONY: all
all: help

##@ General

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Environment

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
	@# reachable from pods of the control-plane cluster. The kubeconfig goes through a pipe and never hits the disk.
	$(KIND) get kubeconfig --internal --name $(FLEET_CLUSTER) \
		| $(KUBECTL) --context $(CP_CTX) -n crossplane-system create secret generic $(FLEET_CLUSTER)-kubeconfig \
			--from-file=kubeconfig=/dev/stdin --dry-run=client -o yaml \
		| $(KUBECTL) --context $(CP_CTX) apply -f -
	$(KUBECTL) --context $(CP_CTX) apply -f platform/providerconfig.yaml

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
$(CROSSPLANE_CLI): | $(LOCALBIN)
	curl -sSfL -o $@ https://cli.crossplane.io/stable/$(CROSSPLANE_CLI_VERSION)/bin/$(OS)_$(ARCH)/crossplane
	chmod +x $@
