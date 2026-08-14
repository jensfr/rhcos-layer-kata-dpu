#!/bin/bash
# Demo: Kata VM with cold-plugged BlueField-3 VF
# Records with asciinema if available, otherwise just runs
# Prerequisites: kata-dpu-test pod running, KUBECONFIG set

KUBECONFIG="${KUBECONFIG:?Set KUBECONFIG to your DPU cluster kubeconfig}"
DOCA_KUBECONFIG="${DOCA_KUBECONFIG:-/tmp/doca-kubeconfig.yaml}"
export KUBECONFIG

pause() { echo ""; sleep 2; }

echo "================================================================"
echo "  Kata Containers + BlueField-3 DPU Cold-Plug VFIO Demo"
echo "================================================================"
pause

echo "--- 1. Pod is running with kata-coldplug RuntimeClass ---"
oc get pod kata-dpu-test -o wide
pause

echo "--- 2. Webhook injected DPU NAD automatically ---"
echo "NAD: $(oc get pod kata-dpu-test -o jsonpath='{.metadata.annotations.v1\.multus-cni\.io/default-network}')"
echo "VF:  $(oc get pod kata-dpu-test -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/dpu\.connection-details}' | python3 -m json.tool 2>/dev/null)"
pause

echo "--- 3. OVN assigned IP and MAC ---"
oc get pod kata-dpu-test -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/pod-networks}' | python3 -c "
import json,sys
d=json.load(sys.stdin)['default']
print(f\"  IP:      {d['ip_address']}\")
print(f\"  MAC:     {d['mac_address']}\")
print(f\"  Gateway: {d['gateway_ip']}\")
"
pause

NODE=$(oc get pod kata-dpu-test -o jsonpath='{.spec.nodeName}')

echo "--- 4. QEMU runs with VFIO-passthrough BlueField VF ---"
oc debug node/$NODE -- chroot /host bash -c '
  ps aux | grep qemu-kvm | grep -o "vfio-pci,host=[^ ]*"
' 2>&1 | grep vfio
pause

echo "--- 5. VF is bound to vfio-pci with IOMMU ---"
VF_PCI=$(oc debug node/$NODE -- chroot /host bash -c '
  ps aux | grep qemu-kvm | grep -oP "host=\K[0-9a-f:.]+(?=,)"
' 2>&1 | grep -v "^$\|Starting\|Removing\|Temporary")
echo "  PCI:    $VF_PCI"
oc debug node/$NODE -- chroot /host bash -c "
  driver=\$(basename \$(readlink /sys/bus/pci/devices/$VF_PCI/driver))
  iommu=\$(basename \$(readlink /sys/bus/pci/devices/$VF_PCI/iommu_group))
  echo \"  Driver: \$driver\"
  echo \"  IOMMU:  group \$iommu\"
" 2>&1 | grep -E "Driver|IOMMU"
pause

echo "--- 6. Inside the VM: eth0 has the OVN-assigned MAC ---"
oc exec kata-dpu-test -- cat /sys/class/net/eth0/address
pause

echo "--- 7. ARP to gateway resolves (L2 connectivity proven) ---"
oc exec kata-dpu-test -- cat /proc/net/arp
pause

echo "--- 8. VF representor visible on DPU (pf1vf*) ---"
if [ -f "$DOCA_KUBECONFIG" ]; then
  DPU_NODE=$(KUBECONFIG=$DOCA_KUBECONFIG oc get nodes -o jsonpath='{.items[0].metadata.name}')
  KUBECONFIG=$DOCA_KUBECONFIG oc debug node/$DPU_NODE -- chroot /host bash -c '
    echo "OVS ports in br-int matching pf1:"
    ovs-vsctl list-ports br-int | grep pf1
  ' 2>&1 | grep -v "Starting\|Removing\|Temporary"
else
  echo "  (DOCA kubeconfig not available, skipping DPU-side check)"
fi
pause

echo "--- 9. Host does NOT see the VF traffic (isolation) ---"
oc debug node/$NODE -- chroot /host bash -c "
  echo 'VF $VF_PCI driver on host:'
  basename \$(readlink /sys/bus/pci/devices/$VF_PCI/driver)
  echo 'No netdev on host (VFIO passthrough):'
  ls /sys/bus/pci/devices/$VF_PCI/net/ 2>&1 || echo '  (empty - correct, VF is in the VM)'
" 2>&1 | grep -v "Starting\|Removing\|Temporary"
pause

echo "================================================================"
echo "  SUMMARY"
echo "  - Kata VM running with cold-plugged BlueField-3 VF"
echo "  - VF passed via VFIO with IOMMU isolation"
echo "  - OVN webhook auto-injects DPU network"
echo "  - L2 connectivity to OVN gateway confirmed"
echo "  - Host has no access to VF (security isolation)"
echo "================================================================"
