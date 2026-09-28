#!/bin/bash
# Verify kata layer-only installation.
# Usage: ./test.sh <MCP_ROLE>

set -euo pipefail

MCP_ROLE="${1:-}"
if [ -z "$MCP_ROLE" ]; then
  echo "Usage: $0 <MCP_ROLE>"
  exit 1
fi

EXPECTED_RPM="kata-containers-4.1.0-3"
PASS=0
FAIL=0

check() {
  local desc=$1 val=$2 expected=$3
  if echo "$val" | grep -q "$expected"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected '$expected', got '$val')"
    FAIL=$((FAIL + 1))
  fi
}

NODES=$(oc get nodes -l "node-role.kubernetes.io/$MCP_ROLE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
[ -z "$NODES" ] && { echo "ERROR: no nodes with role $MCP_ROLE"; exit 1; }

echo "=== Node checks ==="
for NODE in $NODES; do
  echo "--- $NODE ---"
  result=$(oc debug node/"$NODE" -- chroot /host bash -c '
    echo "rpm=$(rpm -q kata-containers 2>/dev/null)"
    echo "initrd_target=$(readlink /var/cache/kata-containers/osbuilder-images/kata.initrd 2>/dev/null)"
    echo "kernel_target=$(readlink /var/cache/kata-containers/osbuilder-images/kata.kernel 2>/dev/null)"
    echo "crio_handler=$(test -f /etc/crio/crio.conf.d/50-kata-coldplug && echo present || echo MISSING)"
    echo "config_d=$(test -f /etc/kata-containers/config.d/50-kata-coldplug.toml && echo present || echo MISSING)"
    echo "coldplug=$(grep -c cold_plug_vfio /etc/kata-containers/config.d/50-kata-coldplug.toml 2>/dev/null)"
    echo "pcie_root_port=$(grep -c pcie_root_port /etc/kata-containers/config.d/50-kata-coldplug.toml 2>/dev/null)"
    echo "vfio_module=$(test -f /etc/modules-load.d/kata-vfio.conf && echo present || echo MISSING)"
    echo "mlx5_initrd=$(lsinitrd /var/cache/kata-containers/osbuilder-images/kata.initrd 2>/dev/null | grep -c mlx5_core.ko)"
    echo "selinux=$(semodule -l 2>/dev/null | grep -c osc_monitor)"
  ' 2>&1 | grep "=" | grep -v "^Starting\|^Removing\|^Temporary\|^To use\|^Warning")

  rpm_val=$(echo "$result" | grep "^rpm=" | cut -d= -f2)
  check "RPM version" "$rpm_val" "$EXPECTED_RPM"
  check "initrd symlink" "$(echo "$result" | grep initrd_target)" "kata.initrd"
  check "kernel symlink" "$(echo "$result" | grep kernel_target)" "vmlinuz"
  check "CRI-O handler" "$(echo "$result" | grep crio_handler)" "present"
  check "config.d drop-in" "$(echo "$result" | grep config_d)" "present"
  check "cold_plug_vfio set" "$(echo "$result" | grep coldplug)" "1"
  check "pcie_root_port set" "$(echo "$result" | grep pcie_root_port)" "1"
  check "vfio-pci module-load" "$(echo "$result" | grep vfio_module)" "present"
  check "mlx5 in initrd" "$(echo "$result" | grep mlx5_initrd)" "mlx5_initrd=1"
  check "SELinux osc_monitor" "$(echo "$result" | grep selinux)" "selinux=1"
done

echo ""
echo "=== RuntimeClass ==="
check "kata-coldplug exists" "$(oc get runtimeclass kata-coldplug -o name 2>/dev/null)" "kata-coldplug"

echo ""
echo "=== Pod lifecycle ==="
oc delete pod kata-coldplug-test --ignore-not-found &>/dev/null
sleep 2
oc apply -f "$(dirname "$0")/05-test-pod.yaml" &>/dev/null

if oc wait --for=condition=Ready pod/kata-coldplug-test --timeout=120s &>/dev/null; then
  POD_NODE=$(oc get pod kata-coldplug-test -o jsonpath='{.spec.nodeName}')
  target_node=false
  for candidate in $NODES; do
    if [[ "$POD_NODE" == "$candidate" ]]; then
      target_node=true
      break
    fi
  done
  check "pod scheduled on target node" "$target_node" "^true$"

  exec_out=$(oc exec kata-coldplug-test -- cat /proc/version 2>/dev/null)
  check "exec works" "$exec_out" "Linux version"

  qemu_before=$(oc debug node/"$POD_NODE" -- chroot /host bash -c 'ps aux | grep qemu-kvm | grep -v grep | wc -l' 2>&1 | grep -E "^[0-9]")
  check "QEMU running" "$qemu_before" "1"

  oc delete pod kata-coldplug-test --wait --timeout=30s &>/dev/null
  sleep 5

  cleanup=$(oc debug node/"$POD_NODE" -- chroot /host bash -c 'echo "QEMU=$(ps aux | grep qemu-kvm | grep -v grep | wc -l) Shim=$(ps aux | grep containerd-shim-kata | grep -v grep | wc -l)"' 2>&1 | grep "QEMU=")
  check "QEMU gone after delete" "$cleanup" "QEMU=0"
  check "Shim gone after delete" "$cleanup" "Shim=0"
else
  echo "  FAIL: pod did not start within 120s"
  FAIL=$((FAIL + 1))
  oc describe pod kata-coldplug-test 2>/dev/null | tail -10
  oc delete pod kata-coldplug-test --ignore-not-found &>/dev/null
fi

echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
echo "==============================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
