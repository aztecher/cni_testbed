PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))


.PHONY: all
all: help


##@ General

.PHONY: help
help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: build_ovs_container
build_ovs_container: ## Build OvS Container for testbed
	@if [ ! -d /tmp/ovs ]; then \
		git clone https://github.com/openvswitch/ovs.git /tmp/ovs; \
			cd /tmp/ovs/utilities/docker; \
	    	sed -i 's/16.04/22.04/' $(OVS_BUILD_DISTRO)/Dockerfile; \
			OVS_BRANCH=$(OVS_BUILD_BRANCH) \
				OVS_VERSION=$(OVS_BUILD_VERSION) \
				KERNEL_VERSION=$(OVS_BUILD_KERNEL_VERSION) \
				DISTRO=$(OVS_BUILD_DISTRO) \
				GITHUB_SRC=$(OVS_BUILD_GITHUB_SRC) \
				DOCKER_REPO=$(OVS_BUILD_DOCKER_REPO) \
				make build; \
			cd $(PROJECT_DIR); \
	fi

.PHONY: cni_testbed
testbed: kind kubectl plugins build_ovs_container ## Construct cni testbed
	# Create kind cluster
	$(KIND) get clusters | grep k8sdev 2>&1 >/dev/null || \
		$(KIND) create cluster --name $(KIND_CLUSTER_NAME) --config config/kind/kind-k8sdev-no-cni.yaml
	# Deploy flannel as a primary CNI
	$(KUBECTL) apply -f config/manifests/flannel/kube-flannel.yaml
	until ! $(KUBECTL) -n kube-flannel get pod |grep -e Init -e Creating -e Error 2>&1 >/dev/null; do \
		echo "Waiting for Running flannel" && sleep 10s; \
	done
	# Deploy multus CNI
	$(KUBECTL) apply -f config/manifests/multus/multus-daemonset-thick.yaml
	until ! $(KUBECTL) -n kube-system get pod | grep multus | grep -e Init -e Creating -e Error 2>&1 >/dev/null; do \
		echo "Waiting for Running multus" && sleep 10s; \
	done
	# Deploy Network
	$(docker) ps | grep clab 2>&1 >/dev/null || \
		$(DOCKER) run --rm -it --privileged \
			--network host \
			-v /var/run/docker.sock:/var/run/docker.sock \
			-v /var/run/netns:/var/run/netns \
			-v /etc/hosts:/etc/hosts \
			-v /var/lib/docker/containers:/var/lib/docker/containers \
			--pid="host" \
			-v $(PROJECT_DIR):$(PROJECT_DIR) \
			-w $(PROJECT_DIR) \
			ghcr.io/srl-labs/clab:latest \
			containerlab deploy --topo config/clab/rail-optimized.yaml
	sudo config/scripts/setup_netns.sh
	# Configure Additional Network between kind worker and network
	# Configure worker1 - rail_leaf1
	sudo ip link add to-rail1   type veth peer name to-worker1
	sudo ip link set to-worker1 netns $(CLAB_RAIL_LEAF1)
	sudo ip link set to-rail1   netns $(KIND_WORKER1)
	sudo ip netns exec $(CLAB_RAIL_LEAF1) ip link set to-worker1 up
	sudo ip netns exec $(KIND_WORKER1)    ip link set to-rail1   up
	# Configure worker1 - rail_leaf2
	sudo ip link add to-rail2   type veth peer name to-worker1
	sudo ip link set to-worker1 netns $(CLAB_RAIL_LEAF2)
	sudo ip link set to-rail2   netns $(KIND_WORKER1)
	sudo ip netns exec $(CLAB_RAIL_LEAF2) ip link set to-worker1 up
	sudo ip netns exec $(KIND_WORKER1)    ip link set to-rail2   up
	# Configure BGP interface for rail_leaf1 of worker1
	sudo ip link add bgp-rail1     type veth peer name bgp-rail1-ovs
	sudo ip link set bgp-rail1     netns $(KIND_WORKER1)
	sudo ip link set bgp-rail1-ovs netns $(KIND_WORKER1)
	sudo ip netns exec $(KIND_WORKER1) ip link set bgp-rail1     up
	sudo ip netns exec $(KIND_WORKER1) ip link set bgp-rail1-ovs up
	# Configure BGP interface for rail_leaf2 of worker1
	sudo ip link add bgp-rail2     type veth peer name bgp-rail2-ovs
	sudo ip link set bgp-rail2     netns $(KIND_WORKER1)
	sudo ip link set bgp-rail2-ovs netns $(KIND_WORKER1)
	sudo ip netns exec $(KIND_WORKER1) ip link set bgp-rail2     up
	sudo ip netns exec $(KIND_WORKER1) ip link set bgp-rail2-ovs up
	# Configure worker2 - rail_leaf1
	sudo ip link add to-rail1   type veth peer name to-worker2
	sudo ip link set to-worker2 netns $(CLAB_RAIL_LEAF1)
	sudo ip link set to-rail1   netns $(KIND_WORKER2)
	sudo ip netns exec $(CLAB_RAIL_LEAF1) ip link set to-worker2 up
	sudo ip netns exec $(KIND_WORKER2)    ip link set to-rail1   up
	# Configure worker2 - rail_leaf2
	sudo ip link add to-rail2   type veth peer name to-worker2
	sudo ip link set to-worker2 netns $(CLAB_RAIL_LEAF2)
	sudo ip link set to-rail2   netns $(KIND_WORKER2)
	sudo ip netns exec $(CLAB_RAIL_LEAF2) ip link set to-worker2 up
	sudo ip netns exec $(KIND_WORKER2)    ip link set to-rail2   up
	# Configure BGP interface for rail_leaf1 of worker2
	sudo ip link add bgp-rail1     type veth peer name bgp-rail1-ovs
	sudo ip link set bgp-rail1     netns $(KIND_WORKER2)
	sudo ip link set bgp-rail1-ovs netns $(KIND_WORKER2)
	sudo ip netns exec $(KIND_WORKER2) ip link set bgp-rail1     up
	sudo ip netns exec $(KIND_WORKER2) ip link set bgp-rail1-ovs up
	# Configure BGP interface for rail_leaf2 of worker2
	sudo ip link add bgp-rail2     type veth peer name bgp-rail2-ovs
	sudo ip link set bgp-rail2     netns $(KIND_WORKER2)
	sudo ip link set bgp-rail2-ovs netns $(KIND_WORKER2)
	sudo ip netns exec $(KIND_WORKER2) ip link set bgp-rail2     up
	sudo ip netns exec $(KIND_WORKER2) ip link set bgp-rail2-ovs up
	# Prepare interface for NetworkAttachmentDefinition
	#
	# TODO: Currently, ovs flow rule is statically defined
	#       So, veth interfaces for Pods are also statically created here.
	#       This will be removal by using ovs-cni
	#
	# Prepare interface for NetworkAttachmentDefinition for Worker1
	sudo ip link add to-pod-if1 type veth peer name pod-if1
	sudo ip link add to-pod-if2 type veth peer name pod-if2
	sudo ip link set to-pod-if1 netns $(KIND_WORKER1)
	sudo ip link set to-pod-if2 netns $(KIND_WORKER1)
	sudo ip link set pod-if1    netns $(KIND_WORKER1)
	sudo ip link set pod-if2    netns $(KIND_WORKER1)
	sudo ip netns exec $(KIND_WORKER1) ip link set to-pod-if1 up
	sudo ip netns exec $(KIND_WORKER1) ip link set to-pod-if2 up
	sudo ip netns exec $(KIND_WORKER1) ip link set pod-if1    up
	sudo ip netns exec $(KIND_WORKER1) ip link set pod-if2    up
	# Prepare interface for NetworkAttachmentDefinition for Worker2
	sudo ip link add to-pod-if1 type veth peer name pod-if1
	sudo ip link add to-pod-if2 type veth peer name pod-if2
	sudo ip link set to-pod-if1 netns $(KIND_WORKER2)
	sudo ip link set to-pod-if2 netns $(KIND_WORKER2)
	sudo ip link set pod-if1    netns $(KIND_WORKER2)
	sudo ip link set pod-if2    netns $(KIND_WORKER2)
	sudo ip netns exec $(KIND_WORKER2) ip link set to-pod-if1 up
	sudo ip netns exec $(KIND_WORKER2) ip link set to-pod-if2 up
	sudo ip netns exec $(KIND_WORKER2) ip link set pod-if1    up
	sudo ip netns exec $(KIND_WORKER2) ip link set pod-if2    up
	# Deploy frrouting
	$(DOCKER) exec --privileged -it $(KIND_WORKER1) \
		sysctl -w net.ipv6.conf.all.disable_ipv6=0
	$(DOCKER) exec --privileged -it $(KIND_WORKER2) \
		sysctl -w net.ipv6.conf.all.disable_ipv6=0
	$(KUBECTL) apply -f config/manifests/frrouting/frr-ds.yaml
	until ! $(KUBECTL) -n kube-system get pod | grep frr | grep -e Init -e Creating -e Error 2>&1 >/dev/null; do \
		echo "Waiting for Running frrouting" && sleep 10s; \
	done
	# Deploy OpenvSwitch
	$(KIND) load docker-image $(OVS_CONTAINER) --name $(KIND_CLUSTER_NAME)
	$(KUBECTL) apply -f config/manifests/openvswitch/ovs-ds.yaml
	until ! $(KUBECTL) -n kube-system get pod | grep ovs | grep -e Init -e Creating -e Error 2>&1 >/dev/null; do \
		echo "Waiting for Running ovs" && sleep 10s; \
	done
	sleep 10s
	# Configure OpenvSwitch for Worker1 / Worker2
	# 1. Create 'br-roce' bridge
	# 2. Create 'bgp' interface on 'br-roce'
	# 3. Assign 'to-rail1' interface to 'br-roce'
	# 4. Assign 'to-rail2' interface to 'br-roce'
	# 5. Linkup 'bgp' interface
	# 6. Linkup 'br-roce' interface
	OVS_WORKER1=`$(KUBECTL) -n kube-system get pod -o wide |grep ovs | grep 'k8sdev-worker ' | cut -d ' ' -f 1` && \
		echo "Worker Pod: $$OVS_WORKER1" && \
		$(KUBECTL) -n kube-system exec -t $$OVS_WORKER1 -c ovsdb-vswitchd -- \
			ovs-vsctl add-br br-roce && \
		sleep 1s && \
		$(KUBECTL) -n kube-system exec -t $$OVS_WORKER1 -c ovsdb-vswitchd -- \
			ovs-vsctl add-port br-roce bgp-rail1-ovs && \
		sleep 1s && \
		$(KUBECTL) -n kube-system exec -t $$OVS_WORKER1 -c ovsdb-vswitchd -- \
			ovs-vsctl add-port br-roce bgp-rail2-ovs && \
		sleep 1s && \
		$(KUBECTL) -n kube-system exec -t $$OVS_WORKER1 -c ovsdb-vswitchd -- \
			ovs-vsctl add-port br-roce to-rail1 && \
		sleep 1s && \
		$(KUBECTL) -n kube-system exec -t $$OVS_WORKER1 -c ovsdb-vswitchd -- \
			ovs-vsctl add-port br-roce to-rail2 && \
		sleep 1s && \
		$(KUBECTL) -n kube-system exec -t $$OVS_WORKER1 -c ovsdb-vswitchd -- \
			ovs-vsctl add-port br-roce to-pod-if1 && \
		sleep 1s && \
		$(KUBECTL) -n kube-system exec -t $$OVS_WORKER1 -c ovsdb-vswitchd -- \
			ovs-vsctl add-port br-roce to-pod-if2 && \
		sleep 1s && \
		sudo ip netns exec $(KIND_WORKER1) ip link set bgp-rail1 up && \
		sudo ip netns exec $(KIND_WORKER1) ip link set bgp-rail2 up && \
		sudo ip netns exec $(KIND_WORKER1) ip link set br-roce up
	OVS_WORKER2=`$(KUBECTL) -n kube-system get pod -o wide | grep ovs | grep 'k8sdev-worker2 ' | cut -d ' ' -f 1` && \
		$(KUBECTL) -n kube-system exec -t $$OVS_WORKER2 -c ovsdb-vswitchd -- \
			ovs-vsctl add-br br-roce && \
		sleep 1s && \
		$(KUBECTL) -n kube-system exec -t $$OVS_WORKER2 -c ovsdb-vswitchd -- \
			ovs-vsctl add-port br-roce bgp-rail1-ovs && \
		sleep 1s && \
		$(KUBECTL) -n kube-system exec -t $$OVS_WORKER2 -c ovsdb-vswitchd -- \
			ovs-vsctl add-port br-roce bgp-rail2-ovs && \
		sleep 1s && \
		$(KUBECTL) -n kube-system exec -t $$OVS_WORKER2 -c ovsdb-vswitchd -- \
			ovs-vsctl add-port br-roce to-rail1 && \
		sleep 1s && \
		$(KUBECTL) -n kube-system exec -t $$OVS_WORKER2 -c ovsdb-vswitchd -- \
			ovs-vsctl add-port br-roce to-rail2 && \
		sleep 1s && \
		$(KUBECTL) -n kube-system exec -t $$OVS_WORKER2 -c ovsdb-vswitchd -- \
			ovs-vsctl add-port br-roce to-pod-if1 && \
		sleep 1s && \
		$(KUBECTL) -n kube-system exec -t $$OVS_WORKER2 -c ovsdb-vswitchd -- \
			ovs-vsctl add-port br-roce to-pod-if2 && \
		sleep 1s && \
		sudo ip netns exec $(KIND_WORKER1) ip link set bgp-rail1 up && \
		sudo ip netns exec $(KIND_WORKER1) ip link set bgp-rail2 up && \
		sudo ip netns exec $(KIND_WORKER2) ip link set br-roce up
	# Deploy Pods w/ Secondary NIC
	$(KUBECTL) apply -f config/manifests/net-attach-def/host-device/
	$(KUBECTL) apply -f config/manifests/multinic/
	until ! $(KUBECTL) get pod | grep netshoot-worker1 | grep -e Init -e Creating -e Error -e ImagePullBackOff 2>&1 >/dev/null; do \
		echo "Waiting for Running netshoot-worker1" && sleep 10s; \
	done
	until ! $(KUBECTL) get pod | grep netshoot-worker2 | grep -e Init -e Creating -e Error -e ImagePullBackOff 2>&1 >/dev/null; do \
		echo "Waiting for Running netshoot-worker2" && sleep 10s; \
	done
	sleep 10s
	# Install OvS flow rule to connect netshoot-workers
	config/scripts/install_ovs_flows.sh
	@echo "You can see the information again by using 'config/scripts/install_ovs_flows.sh --info'"
	@echo "And following command template help you if some incident occurs."
	@echo ""
	@echo "FRR_WORKER1=$$(kubectl -n kube-system get pod | grep frr-worker1 | cut -d ' ' -f 1)"
	@echo "FRR_WORKER2=$$(kubectl -n kube-system get pod | grep frr-worker2 | cut -d ' ' -f 1)"
	@echo "OVS_WORKER1=$$(kubectl -n kube-system get pod -o wide | grep ovs | grep 'k8sdev-worker ' | cut -d ' ' -f 1)"
	@echo "OVS_WORKER2=$$(kubectl -n kube-system get pod -o wide | grep ovs | grep 'k8sdev-worker2' | cut -d ' ' -f 1)"
	@echo "kubectl -n kube-system exec -t $FRR_WORKER1 -- vtysh -c 'show ip bgp summary'"
	@echo "kubectl -n kube-system exec -t $FRR_WORKER2 -- vtysh -c 'show ip bgp summary'"
	@echo "kubectl -n kube-system exec -t $OVS_WORKER1 -- ovs-ofctl dump-flows --name br-roce"
	@echo "kubectl -n kube-system exec -t $OVS_WORKER2 -- ovs-ofctl dump-flows --name br-roce"
	@echo ""


.PHONY: cleanup
cleanup: cleanup_network cleanup_kind cleanup_netns ## Destroy all

.PHONY: cleanup_network
cleanup_network: ## Destroy network configured by containerlab
	$(DOCKER) run --rm -it --privileged \
		--network host \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v /var/run/netns:/var/run/netns \
		-v /etc/hosts:/etc/hosts \
		-v /var/lib/docker/containers:/var/lib/docker/containers \
		--pid="host" \
		-v $(PROJECT_DIR):$(PROJECT_DIR) \
		-w $(PROJECT_DIR) \
		ghcr.io/srl-labs/clab:latest \
		containerlab destroy --topo config/clab/rail-optimized.yaml

.PHONY: cleanup_netns
cleanup_netns: ## Destroy netns
	@for ns in `ls /var/run/netns`; do sudo unlink /var/run/netns/$$ns; done

.PHONY: cleanup_kind
cleanup_kind: ## Destroy kind
	$(KIND) delete cluster -n k8sdev


##@ Tools

### Variables

LOCALBIN ?= $(PROJECT_DIR)/bin
$(LOCALBIN):
	@mkdir -p $(LOCALBIN)

LOCALCNIBIN ?=$(LOCALBIN)/cni
$(LOCALCNIBIN):
	@mkdir -p $(LOCALCNIBIN)


KIND ?= $(LOCALBIN)/kind
KUBECTL ?= $(LOCALBIN)/kubectl
PLUGINS ?= $(LOCALCNIBIN)/static
DOCKERBINDIR ?= /usr/bin/
DOCKER ?= $(DOCKERBINDIR)/docker

CLAB_PREFIX ?= clab-rail-optimized
CLAB_RAIL_LEAF1 ?= $(CLAB_PREFIX)-rail_leaf1
CLAB_RAIL_LEAF2 ?= $(CLAB_PREFIX)-rail_leaf2
CLAB_SPINE1 ?= $(CLAB_PREFIX)-spine1
CLAB_SPINE2 ?= $(CLAB_PREFIX)-spine2

KIND_PREFIX ?= k8sdev
KIND_WORKER1 ?= $(KIND_PREFIX)-worker
KIND_WORKER2 ?= $(KIND_PREFIX)-worker2
KIND_CLUSTER_NAME ?= k8sdev

OVS_BUILD_GITHUB_SRC ?= https://github.com/openvswitch/ovs.git
OVS_BUILD_BRANCH ?= branch-3.5
OVS_BUILD_VERSION ?= 3.5
OVS_BUILD_KERNEL_VERSION ?= 6.8.0-51-generic
OVS_BUILD_DISTRO ?= debian
OVS_BUILD_DOCKER_REPO ?= localhost
OVS_CONTAINER_TAG=$(OVS_BUILD_VERSION)_$(OVS_BUILD_DISTRO)_$(OVS_BUILD_KERNEL_VERSION)
OVS_CONTAINER=$(OVS_BUILD_DOCKER_REPO):$(OVS_CONTAINER_TAG)

### Tool versions

KIND_VERSION ?= v0.27.0
KIND_BIN_URL ?= https://kind.sigs.k8s.io/dl/$(KIND_VERSION)/kind-linux-amd64

KUBECTL_VERSION ?= v1.32.2
KUBECTL_BIN_URL ?= https://dl.k8s.io/release/$(KUBECTL_VERSION)/bin/linux/amd64/kubectl

PLUGINS_VERSION ?= v1.6.2
PLUGINS_URL ?= https://github.com/containernetworking/plugins/releases/download/$(PLUGINS_VERSION)/cni-plugins-linux-amd64-$(PLUGINS_VERSION).tgz

.PHONY: kind
kind: $(KIND) ## Download kind locally if necessary
$(KIND): | $(LOCALBIN)
	@curl -Lo $(KIND) $(KIND_BIN_URL)
	@chmod +x $(KIND)

.PHONY: kubectl
kubectl: $(KUBECTL) ## Download kubectl locally if necessary
$(KUBECTL): | $(LOCALBIN)
	@curl -Lo $(KUBECTL) $(KUBECTL_BIN_URL)
	@chmod +x $(KUBECTL)

.PHONY: plugins
plugins: $(PLUGINS) ## Download plugins locally if necessary
$(PLUGINS): | $(LOCALCNIBIN)
	@curl -sfL $(PLUGINS_URL) | tar -xz -C $(LOCALCNIBIN)
