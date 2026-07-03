#!/bin/bash
# Verify DPU/SR-IOV cold-plug VFIO backport deployment
# Run after deploy.sh completes

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

check() {
  local desc=$1
  shift
  if "$@" &>/dev/null; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc"
    FAIL=$((FAIL + 1))
  fi
}

check_output() {
  local desc=$1
  local expected=$2
  shift 2
  local output
  output=$("$@" 2>/dev/null)
  if echo "$output" | grep -q "$expected"; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected '$expected', got '$output')"
    FAIL=$((FAIL + 1))
  fi
}

NODE=$(oc get nodes -l node-role.kubernetes.io/kata-oc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$NODE" ] && NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')

node_exec() {
  oc debug node/$NODE -- chroot /host bash -c "$1" 2>&1 | grep -v "^Starting\|^Removing\|^To use"
}

echo "=== Node checks (node: $NODE) ==="

check_output "kata-containers RPM is 3.31.0-3" \
  "kata-containers-3.31.0-3" \
  node_exec "rpm -q kata-containers"

check_output "qemu-kvm-core is installed" \
  "qemu-kvm-core" \
  node_exec "rpm -q qemu-kvm-core"

check_output "virtiofsd is installed" \
  "virtiofsd" \
  node_exec "rpm -q virtiofsd"

check_output "CRI-O kata-coldplug handler exists" \
  "kata-coldplug" \
  node_exec "cat /etc/crio/crio.conf.d/50-kata-coldplug"

check_output "cold_plug_vfio is root-port" \
  'cold_plug_vfio = "root-port"' \
  node_exec "cat /etc/kata-containers/config.d/50-coldplug.toml"

check_output "mlx5_core in kata initrd" \
  "mlx5_core" \
  node_exec "lsinitrd /var/cache/kata-containers/osbuilder-images/kata.initrd 2>/dev/null | grep mlx5_core"

check_output "mlx5_ib in kata initrd" \
  "mlx5_ib" \
  node_exec "lsinitrd /var/cache/kata-containers/osbuilder-images/kata.initrd 2>/dev/null | grep mlx5_ib"

check_output "PR #13103 in RPM changelog" \
  "PR #13103" \
  node_exec "rpm -q --changelog kata-containers | head -5"

echo ""
echo "=== Cluster checks ==="

check_output "RuntimeClass kata exists" \
  "kata" \
  oc get runtimeclass kata

check_output "RuntimeClass kata-coldplug exists" \
  "kata-coldplug" \
  oc get runtimeclass kata-coldplug

echo ""
echo "=== Pod test: kata (standard) ==="

oc delete pod kata-test --ignore-not-found &>/dev/null
oc run kata-test --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
  --restart=Never --overrides='{"spec":{"runtimeClassName":"kata"}}' \
  --command -- sleep 120 &>/dev/null

if oc wait --for=condition=Ready pod/kata-test --timeout=180s &>/dev/null; then
  check_output "kata pod runs a VM (separate kernel)" \
    "el9" \
    oc exec kata-test -- uname -r

  check_output "mlx5_core module loaded in kata VM" \
    "mlx5_core" \
    oc exec kata-test -- cat /proc/modules
else
  echo "FAIL: kata pod did not start"
  FAIL=$((FAIL + 1))
fi
oc delete pod kata-test --ignore-not-found &>/dev/null

echo ""
echo "=== Pod test: kata-coldplug ==="

oc delete pod kata-coldplug-test --ignore-not-found &>/dev/null
oc run kata-coldplug-test --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
  --restart=Never --overrides='{"spec":{"runtimeClassName":"kata-coldplug"}}' \
  --command -- sleep 120 &>/dev/null

if oc wait --for=condition=Ready pod/kata-coldplug-test --timeout=180s &>/dev/null; then
  check_output "kata-coldplug pod runs a VM" \
    "el9" \
    oc exec kata-coldplug-test -- uname -r

  check_output "mlx5_core loaded in kata-coldplug VM" \
    "mlx5_core" \
    oc exec kata-coldplug-test -- cat /proc/modules

  check_output "mlx5_ib loaded in kata-coldplug VM" \
    "mlx5_ib" \
    oc exec kata-coldplug-test -- cat /proc/modules

  check_output "ib_core loaded in kata-coldplug VM" \
    "ib_core" \
    oc exec kata-coldplug-test -- cat /proc/modules

  check_output "ib_uverbs loaded in kata-coldplug VM" \
    "ib_uverbs" \
    oc exec kata-coldplug-test -- cat /proc/modules

  check_output "ib_umad loaded in kata-coldplug VM" \
    "ib_umad" \
    oc exec kata-coldplug-test -- cat /proc/modules
else
  echo "FAIL: kata-coldplug pod did not start"
  FAIL=$((FAIL + 1))
fi
oc delete pod kata-coldplug-test --ignore-not-found &>/dev/null

echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
echo "==============================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
