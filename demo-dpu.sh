#!/bin/bash
# Demo: BlueField DPU VF hot-plugged into Kata VM on OCP 4.22
# Usage: asciinema rec --command ./demo-dpu.sh demo-dpu.cast

export KUBECONFIG="${KUBECONFIG:-$HOME/Downloads/kubeconfig.igal-cno}"

type_cmd() {
  echo ""
  echo -n "$ "
  echo "$1" | while IFS= read -r -n1 char; do echo -n "$char"; sleep 0.03; done
  echo ""
  sleep 0.5
  eval "$1"
  sleep 2
}

comment() {
  echo ""
  echo -e "\033[1;36m# $1\033[0m"
  sleep 2
}

clear
echo -e "\033[1;33m"
echo "================================================================"
echo "  BlueField DPU SR-IOV VF in a Kata VM on OCP 4.22"
echo "  Hot-plug workaround for pre-bound VFIO devices"
echo "  https://github.com/jensfr/rhcos-layer-kata-dpu"
echo "================================================================"
echo -e "\033[0m"
sleep 4

echo -e "\033[1;32m>>> What we did to get here\033[0m"
sleep 2
echo -e "\033[1;36m"
cat <<'MSG'
1. Backported 17 patches from upstream kata PR #13103 to kata 3.31.0
2. Built RHCOS layered image with patched RPM + mlx5 kernel modules
3. Created kata-coldplug RuntimeClass with hot_plug_vfio = root-port
4. Worked around: service IP routing, OVN-K webhook injection,
   OSC operator label conflicts, cold-plug code bug
MSG
echo -e "\033[0m"
sleep 5

echo -e "\033[1;32m>>> Live demo\033[0m"
sleep 2

comment "The DPU worker node with BlueField-3"
type_cmd "oc get nodes"

comment "4 VFIO VFs available for Kata pods"
type_cmd "oc get node nvd-srv-27.nvidia.eng.rdu2.dc.redhat.com -o json | jq '.status.allocatable | with_entries(select(.key | contains(\"kata\") or contains(\"vfio\")))'"

comment "Kata pod running with kata-coldplug RuntimeClass + DPU VF (hot-plug workaround -- cold-plug has a code bug)"
type_cmd "oc get pod -n test-kata mellanox-x86 -o wide"

comment "It is a real VM with its own kernel"
type_cmd "oc exec -n test-kata mellanox-x86 -- uname -r"

comment "BlueField VF is inside the VM (vendor 0x15b3 = Mellanox)"
type_cmd "oc exec -n test-kata mellanox-x86 -- bash -c 'for d in /sys/bus/pci/devices/*; do v=\$(cat \$d/vendor 2>/dev/null); [ \"\$v\" = \"0x15b3\" ] && echo \"\$(basename \$d) vendor=\$v device=\$(cat \$d/device) driver=\$(readlink \$d/driver 2>/dev/null | xargs basename 2>/dev/null)\"; done'"

comment "mlx5_core driver bound, firmware loaded"
type_cmd "oc exec -n test-kata mellanox-x86 -- dmesg | grep mlx5 | head -5"

comment "eth0 interface created by mlx5_core"
type_cmd "oc exec -n test-kata mellanox-x86 -- ip addr show eth0"

comment "Physical hardware: FIBRE port, 200Gbps capable"
type_cmd "oc exec -n test-kata mellanox-x86 -- ethtool eth0 2>&1 | head -6"

comment "L2 connectivity: ARP to OVN gateway resolves through the DPU hardware"
type_cmd "oc exec -n test-kata mellanox-x86 -- ip neigh show dev eth0"

comment "This proves the VF is connected to the DPU switching fabric"
sleep 2

comment "Configuration that made it work"
NODE=nvd-srv-27.nvidia.eng.rdu2.dc.redhat.com
type_cmd "oc debug node/$NODE -- chroot /host cat /etc/kata-containers/config.d/50-coldplug.toml 2>&1 | grep -v '^Starting\|^Removing\|^To use\|^Temporary'"

sleep 3
echo ""
echo -e "\033[1;31m>>> What's still needed\033[0m"
sleep 2
echo -e "\033[1;36m"
cat <<'MSG'
1. L3 connectivity: OVN-K needs DAN support (PR #6407, Lei Huang, NVIDIA)
   to auto-configure IP/MAC/routes inside the VM
2. Cold-plug: code bug prevents pre-bound VFIO devices from being
   added to QEMU at sandbox creation (hot-plug workaround for now)
3. For CoCo: cold-plug is mandatory (hot-plug compromises attestation)
MSG
echo -e "\033[0m"
sleep 6

echo -e "\033[1;33m"
echo "================================================================"
echo "  Repo: https://github.com/jensfr/rhcos-layer-kata-dpu"
echo "  Branch: dpu-hotplug-workaround"
echo "  Report: dpu-kata-integration-report.md"
echo "================================================================"
echo -e "\033[0m"
sleep 10
