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

.PHONY: down
down: ## Delete both kind clusters. Other kind clusters are left alone.
	$(KIND) delete cluster --name $(CP_CLUSTER)
	$(KIND) delete cluster --name $(FLEET_CLUSTER)

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
