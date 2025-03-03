#!/bin/bash


OVS_POD_WORKER1=$(kubectl -n kube-system get pod -o wide | grep ovs |grep 'k8sdev-worker ' | cut -d ' ' -f 1)
OVS_POD_WORKER2=$(kubectl -n kube-system get pod -o wide | grep ovs |grep 'k8sdev-worker2' | cut -d ' ' -f 1)
declare -a OVS_PODS=(${OVS_POD_WORKER1} ${OVS_POD_WORKER2})

# Waiting until BGP connections are succeeded.


WORKER1_EXT1_HWADDR=$(/bin/docker exec -it k8sdev-worker ip a s dev to-rail1 | grep "link/ether" | awk '{print $2}' | tr -d ':')
WORKER1_EXT2_HWADDR=$(/bin/docker exec -it k8sdev-worker ip a s dev to-rail2 | grep "link/ether" | awk '{print $2}' | tr -d ':')
WORKER1_RAIL1_HWADDR=$(/bin/docker exec -it clab-rail-optimized-rail_leaf1 ip a s dev to-worker1 |grep link/ether | awk '{print $2}' |tr -d ':')
WORKER1_RAIL2_HWADDR=$(/bin/docker exec -it clab-rail-optimized-rail_leaf2 ip a s dev to-worker1 |grep link/ether | awk '{print $2}' |tr -d ':')

WORKER2_EXT1_HWADDR=$(/bin/docker exec -it k8sdev-worker2 ip a s dev to-rail1 | grep "link/ether" | awk '{print $2}' | tr -d ':')
WORKER2_EXT2_HWADDR=$(/bin/docker exec -it k8sdev-worker2 ip a s dev to-rail2 | grep "link/ether" | awk '{print $2}' | tr -d ':')
WORKER2_RAIL1_HWADDR=$(/bin/docker exec -it clab-rail-optimized-rail_leaf1 ip a s dev to-worker2 |grep link/ether | awk '{print $2}' |tr -d ':')
WORKER2_RAIL2_HWADDR=$(/bin/docker exec -it clab-rail-optimized-rail_leaf2 ip a s dev to-worker2 |grep link/ether | awk '{print $2}' |tr -d ':')

WORKER1_POD_NET1=$(kubectl exec -t netshoot-worker1 -- ip a s dev net1 | grep "link/ether" | awk '{print $2}' | tr -d ':')
WORKER1_POD_NET2=$(kubectl exec -t netshoot-worker1 -- ip a s dev net2 | grep "link/ether" | awk '{print $2}' | tr -d ':')
WORKER2_POD_NET1=$(kubectl exec -t netshoot-worker2 -- ip a s dev net1 | grep "link/ether" | awk '{print $2}' | tr -d ':')
WORKER2_POD_NET2=$(kubectl exec -t netshoot-worker2 -- ip a s dev net2 | grep "link/ether" | awk '{print $2}' | tr -d ':')

echo "-------------------- Testbed Information --------------------"
echo "k8sdev-worker:"
echo "  - ovs pod: ${OVS_POD_WORKER1}"
echo "  - netshoot: net1 (${WORKER1_POD_NET1}), net2 (${WORKER1_POD_NET2})"
echo "  - to-rail1 (${WORKER1_EXT1_HWADDR}) is connected to rail-leaf1's to-worker1 (${WORKER1_RAIL1_HWADDR})"
echo "  - to-rail2 (${WORKER1_EXT2_HWADDR}) is connected to rail-leaf2's to-worker1 (${WORKER1_RAIL2_HWADDR})"
echo "k8sdev-worker2:"
echo "  - ovs pod: ${OVS_POD_WORKER2}"
echo "  - netshoot: net1 (${WORKER2_POD_NET1}), net2 (${WORKER1_POD_NET2})"
echo "  - to-rail1 (${WORKER2_EXT1_HWADDR}) is connected to rail-leaf1's to-worker2 (${WORKER2_RAIL1_HWADDR})"
echo "  - to-rail2 (${WORKER2_EXT2_HWADDR}) is connected to rail-leaf2's to-worker2 (${WORKER2_RAIL2_HWADDR})"
echo "------------------------------=-------------------------------"


function _install_flow_via_kubeovs() {
  local ovspod=$1
  local flowrule=$2
  if [ "$MODE" == "dryrun" ]; then
    echo "$ovspod / $flowrule"
  elif [ "$MODE" == "info" ]; then
    return
  else
    ./bin/kubectl -n kube-system exec -it $ovspod -c ovsdb-vswitchd -- ovs-ofctl add-flow br-roce "$flowrule"
  fi
}

function _install_bgp_flows() {
  local TABLE_ID=0
  for OVS_POD in ${OVS_PODS[@]}; do
    _install_flow_via_kubeovs $OVS_POD "table=${TABLE_ID},priority=800,in_port=bgp-rail1-ovs,ipv6 actions:output=to-rail1"
    _install_flow_via_kubeovs $OVS_POD "table=${TABLE_ID},priority=800,in_port=to-rail1,ipv6 actions:output=bgp-rail1-ovs"
    _install_flow_via_kubeovs $OVS_POD "table=${TABLE_ID},priority=800,in_port=bgp-rail2-ovs,ipv6 actions:output=to-rail2"
	  _install_flow_via_kubeovs $OVS_POD "table=${TABLE_ID},priority=800,in_port=to-rail2,ipv6 actions:output=bgp-rail2-ovs"
    _install_flow_via_kubeovs $OVS_POD "table=${TABLE_ID},priority=600,arp,in_port=to-pod-if1 actions=resubmit(,10)"
    _install_flow_via_kubeovs $OVS_POD "table=${TABLE_ID},priority=600,arp,in_port=to-pod-if2 actions=resubmit(,10)"
    _install_flow_via_kubeovs $OVS_POD "table=${TABLE_ID},priority=400,in_port=to-pod-if1 actions=resubmit(,20)"
    _install_flow_via_kubeovs $OVS_POD "table=${TABLE_ID},priority=400,in_port=to-pod-if2 actions=resubmit(,20)"
    _install_flow_via_kubeovs $OVS_POD "table=${TABLE_ID},priority=400,in_port=to-rail1 actions=resubmit(,30)"
    _install_flow_via_kubeovs $OVS_POD "table=${TABLE_ID},priority=400,in_port=to-rail2 actions=resubmit(,30)"
  done
}

function _install_arp_flows() {
  local TABLE_ID=10
  # Install ARP Conversion Rule for Worker1 NIC1
  _install_flow_via_kubeovs $OVS_POD_WORKER1 "table=${TABLE_ID},priority=600,arp,in_port=to-pod-if1,arp_op=1 actions=move:NXM_OF_ETH_SRC[]->NXM_OF_ETH_DST[],load:0x${WORKER1_RAIL1_HWADDR}->NXM_OF_ETH_SRC[],move:NXM_NX_ARP_SHA[]->NXM_NX_ARP_THA[],load:0x${WORKER1_RAIL1_HWADDR}->NXM_NX_ARP_SHA[],push:NXM_OF_ARP_TPA[],move:NXM_OF_ARP_SPA[]->NXM_OF_ARP_TPA[],pop:NXM_OF_ARP_SPA[],load:0x2->NXM_OF_ARP_OP[],IN_PORT"
  # Install ARP Conversion Rule for Worker1 NIC2
  _install_flow_via_kubeovs $OVS_POD_WORKER1 "table=${TABLE_ID},priority=600,arp,in_port=to-pod-if2,arp_op=1 actions=move:NXM_OF_ETH_SRC[]->NXM_OF_ETH_DST[],load:0x${WORKER1_RAIL2_HWADDR}->NXM_OF_ETH_SRC[],move:NXM_NX_ARP_SHA[]->NXM_NX_ARP_THA[],load:0x${WORKER1_RAIL2_HWADDR}->NXM_NX_ARP_SHA[],push:NXM_OF_ARP_TPA[],move:NXM_OF_ARP_SPA[]->NXM_OF_ARP_TPA[],pop:NXM_OF_ARP_SPA[],load:0x2->NXM_OF_ARP_OP[],IN_PORT"
  # Install ARP Conversion Rule for Worker2 NIC1
  _install_flow_via_kubeovs $OVS_POD_WORKER2 "table=${TABLE_ID},priority=600,arp,in_port=to-pod-if1,arp_op=1 actions=move:NXM_OF_ETH_SRC[]->NXM_OF_ETH_DST[],load:0x${WORKER2_RAIL1_HWADDR}->NXM_OF_ETH_SRC[],move:NXM_NX_ARP_SHA[]->NXM_NX_ARP_THA[],load:0x${WORKER2_RAIL1_HWADDR}->NXM_NX_ARP_SHA[],push:NXM_OF_ARP_TPA[],move:NXM_OF_ARP_SPA[]->NXM_OF_ARP_TPA[],pop:NXM_OF_ARP_SPA[],load:0x2->NXM_OF_ARP_OP[],IN_PORT"
  # Install ARP Conversion Rule for Worker2 NIC2
  _install_flow_via_kubeovs $OVS_POD_WORKER2 "table=${TABLE_ID},priority=600,arp,in_port=to-pod-if2,arp_op=1 actions=move:NXM_OF_ETH_SRC[]->NXM_OF_ETH_DST[],load:0x${WORKER2_RAIL2_HWADDR}->NXM_OF_ETH_SRC[],move:NXM_NX_ARP_SHA[]->NXM_NX_ARP_THA[],load:0x${WORKER2_RAIL2_HWADDR}->NXM_NX_ARP_SHA[],push:NXM_OF_ARP_TPA[],move:NXM_OF_ARP_SPA[]->NXM_OF_ARP_TPA[],pop:NXM_OF_ARP_SPA[],load:0x2->NXM_OF_ARP_OP[],IN_PORT"
}

function _install_mac_conversion_from_pod() {
  # Convert SRC_MAC from Pod Interface to Rail(Uplink) IF
  # Because of the ARP alternative reply flow, DST_MAC of Pod packet is already set as Rail-Leaf's Interface MAC
  local TABLE_ID=20
  _install_flow_via_kubeovs $OVS_POD_WORKER1 "table=${TABLE_ID},priority=600,in_port=to-pod-if1 actions=load:0x${WORKER1_EXT1_HWADDR}->NXM_OF_ETH_SRC[],resubmit(,40)"
  _install_flow_via_kubeovs $OVS_POD_WORKER1 "table=${TABLE_ID},priority=600,in_port=to-pod-if2 actions=load:0x${WORKER1_EXT2_HWADDR}->NXM_OF_ETH_SRC[],resubmit(,40)"
  _install_flow_via_kubeovs $OVS_POD_WORKER2 "table=${TABLE_ID},priority=600,in_port=to-pod-if1 actions=load:0x${WORKER2_EXT1_HWADDR}->NXM_OF_ETH_SRC[],resubmit(,40)"
  _install_flow_via_kubeovs $OVS_POD_WORKER2 "table=${TABLE_ID},priority=600,in_port=to-pod-if2 actions=load:0x${WORKER2_EXT2_HWADDR}->NXM_OF_ETH_SRC[],resubmit(,40)"
}

function _install_mac_conversion_from_rail() {
  # Convert DST_MAC from Rail(Uplink) Interface to Pod IF
  # Because of the ARP alternative reply flow, No need to change SRC_MAC of Rail(Uplink).
  local TABLE_ID=30
  _install_flow_via_kubeovs $OVS_POD_WORKER1 "table=${TABLE_ID},priority=600,in_port=to-rail1 actions=load:0x${WORKER1_POD_NET1}->NXM_OF_ETH_DST[],resubmit(,40)"
  _install_flow_via_kubeovs $OVS_POD_WORKER1 "table=${TABLE_ID},priority=600,in_port=to-rail2 actions=load:0x${WORKER1_POD_NET2}->NXM_OF_ETH_DST[],resubmit(,40)"
  _install_flow_via_kubeovs $OVS_POD_WORKER2 "table=${TABLE_ID},priority=600,in_port=to-rail1 actions=load:0x${WORKER2_POD_NET1}->NXM_OF_ETH_DST[],resubmit(,40)"
  _install_flow_via_kubeovs $OVS_POD_WORKER2 "table=${TABLE_ID},priority=600,in_port=to-rail2 actions=load:0x${WORKER2_POD_NET2}->NXM_OF_ETH_DST[],resubmit(,40)"
}

function _install_ipv4() {
  local TABLE_ID=40
  for OVS_POD in ${OVS_PODS[@]}; do
    _install_flow_via_kubeovs $OVS_POD "table=${TABLE_ID},priority=400,in_port=to-pod-if1 actions=to-rail1"
    _install_flow_via_kubeovs $OVS_POD "table=${TABLE_ID},priority=400,in_port=to-pod-if2 actions=to-rail2"
    _install_flow_via_kubeovs $OVS_POD "table=${TABLE_ID},priority=400,in_port=to-rail1 actions=to-pod-if1"
    _install_flow_via_kubeovs $OVS_POD "table=${TABLE_ID},priority=400,in_port=to-rail2 actions=to-pod-if2"
  done
}

function install_flows() {
  _install_bgp_flows
  _install_arp_flows
  _install_mac_conversion_from_pod
  _install_mac_conversion_from_rail
  _install_ipv4
}

# if '--dryrun' is passed, then dryrun
MODE=run
if [ "$1" == "--dryrun" ]; then
  MODE=dryrun
elif [ "$1" == "--info" ]; then
  MODE=info
fi

install_flows
