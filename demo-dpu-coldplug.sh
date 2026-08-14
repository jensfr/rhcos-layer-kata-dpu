#!/bin/bash
# Demo: Kata VM with cold-plugged BlueField-3 VF
# Prerequisites: kata-dpu-test pod running, KUBECONFIG set

KUBECONFIG="${KUBECONFIG:?Set KUBECONFIG to your DPU cluster kubeconfig}"
DOCA_KUBECONFIG="${DOCA_KUBECONFIG:-/tmp/doca-kubeconfig.yaml}"
export KUBECONFIG

run() {
  echo -e "\033[1;32m\$ $1\033[0m"
  eval "$1"
}

pause() { echo ""; sleep 2; }

echo "================================================================"
echo "  Kata Containers + BlueField-3 DPU Cold-Plug VFIO Demo"
echo "================================================================"
pause

echo "--- 1. Pod is running with kata-coldplug RuntimeClass ---"
run "oc get pod kata-dpu-test -o wide"
pause

echo "--- 2. Webhook injected DPU NAD automatically ---"
run "oc get pod kata-dpu-test -o jsonpath='{.metadata.annotations.v1\.multus-cni\.io/default-network}'"
echo ""
pause

echo "--- 3. OVN assigned IP and MAC ---"
run "oc get pod kata-dpu-test -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -m json.tool"
pause

NODE=$(oc get pod kata-dpu-test -o jsonpath='{.spec.nodeName}')

echo "--- 4. QEMU runs with VFIO-passthrough BlueField VF ---"
echo -e "\033[1;32m\$ oc debug node/\$NODE -- chroot /host ps aux | grep vfio-pci\033[0m"
oc debug node/$NODE -- chroot /host bash -c 'ps aux | grep qemu-kvm | grep -o "vfio-pci,host=[^ ]*"' 2>&1 | grep vfio
pause

echo "--- 5. VF bound to vfio-pci with IOMMU on host ---"
VF_PCI=$(oc debug node/$NODE -- chroot /host bash -c 'ps aux | grep qemu-kvm | grep -oP "host=\K[0-9a-f:.]+(?=,)"' 2>&1 | grep "0000:")
echo -e "\033[1;32m\$ oc debug node/\$NODE -- chroot /host cat /sys/bus/pci/devices/$VF_PCI/{driver,iommu_group}\033[0m"
oc debug node/$NODE -- chroot /host bash -c "echo PCI: $VF_PCI; echo Driver: \$(basename \$(readlink /sys/bus/pci/devices/$VF_PCI/driver)); echo IOMMU: group \$(basename \$(readlink /sys/bus/pci/devices/$VF_PCI/iommu_group))" 2>&1 | grep -E "PCI:|Driver|IOMMU"
pause

echo "--- 6. Inside the VM: eth0 MAC matches OVN assignment ---"
run "oc exec kata-dpu-test -- cat /sys/class/net/eth0/address"
pause

echo "--- 7. VM network interface: 100 GbE BlueField VF ---"
run "oc exec kata-dpu-test -- bash -c 'for f in rx_packets tx_packets rx_bytes tx_bytes; do printf \"  %-12s %s\n\" \"\$f:\" \"\$(cat /sys/class/net/eth0/statistics/\$f)\"; done; echo \"  operstate:   \$(cat /sys/class/net/eth0/operstate)\"; echo \"  speed:       \$(cat /sys/class/net/eth0/speed) Mbps\"; echo \"  mtu:         \$(cat /sys/class/net/eth0/mtu)\"'"
pause

echo "--- 8. mlx5 driver loaded in guest VM ---"
run "oc exec kata-dpu-test -- cat /proc/modules | grep mlx5"
pause

echo "--- 9. ARP to gateway resolves (L2 connectivity) ---"
run "oc exec kata-dpu-test -- cat /proc/net/arp"
pause

echo "--- 10. VF representor active on DPU (traffic path) ---"
if [ -f "$DOCA_KUBECONFIG" ]; then
  DPU_OVN=$(KUBECONFIG=$DOCA_KUBECONFIG oc get pods -n dpf-operator-system -o name 2>/dev/null | grep ovn | head -1)
  if [ -n "$DPU_OVN" ]; then
    echo -e "\033[1;32m\$ KUBECONFIG=\$DOCA_KUBECONFIG oc exec -n dpf-operator-system \$DPU_OVN -c ovn-controller -- ovs-vsctl list-ports br-int | grep pf1\033[0m"
    KUBECONFIG=$DOCA_KUBECONFIG timeout 15 oc exec -n dpf-operator-system ${DPU_OVN#pod/} -c ovn-controller -- ovs-vsctl list-ports br-int 2>/dev/null | grep pf1
  fi
else
  echo "  (DOCA kubeconfig not set, skipping)"
fi
pause

echo "--- 11. Host has NO access to VF (VFIO isolation) ---"
echo -e "\033[1;32m\$ oc debug node/\$NODE -- chroot /host ls /sys/bus/pci/devices/$VF_PCI/net/\033[0m"
oc debug node/$NODE -- chroot /host bash -c "echo Driver: \$(basename \$(readlink /sys/bus/pci/devices/$VF_PCI/driver)); ls /sys/bus/pci/devices/$VF_PCI/net/ 2>&1 || echo '(empty -- VF is inside the VM, not on host)'" 2>&1 | grep -v "Starting\|Removing\|Temporary"
pause

echo "================================================================"
echo "  Kata VM running with cold-plugged BlueField-3 100GbE VF"
echo "  VFIO passthrough + IOMMU isolation + L2 connectivity"
echo "================================================================"
