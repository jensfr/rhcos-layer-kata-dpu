#!/bin/bash
# Verify DPU/SR-IOV cold-plug VFIO deployment on a DPU cluster
# Run after deploy.sh completes
# Requires: oc access to host cluster, DOCA kubeconfig at $DOCA_KUBECONFIG

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCA_KUBECONFIG="${DOCA_KUBECONFIG:-/tmp/doca-kubeconfig.yaml}"
VF_RESOURCE="${VF_RESOURCE:-openshift.io/bf3-p1-vfs-kata}"

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
    echo "FAIL: $desc (expected '$expected', got '$(echo $output | head -c 80)')"
    FAIL=$((FAIL + 1))
  fi
}

NODE=$(oc get nodes -l node-role.kubernetes.io/kata-oc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$NODE" ] && NODE=$(oc get nodes -l node-role.kubernetes.io/dpu -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$NODE" ] && { echo "ERROR: no DPU node found"; exit 1; }

node_exec() {
  oc debug node/$NODE -- chroot /host bash -c "$1" 2>&1 | grep -v "^Starting\|^Removing\|^To use\|^Temporary"
}

echo "=== Node checks (node: $NODE) ==="

check_output "kata-containers RPM installed" \
  "kata-containers" \
  node_exec "rpm -q kata-containers"

check_output "qemu-kvm-core installed" \
  "qemu-kvm-core" \
  node_exec "rpm -q qemu-kvm-core"

check_output "CRI-O kata-coldplug handler" \
  "kata-coldplug" \
  node_exec "cat /etc/crio/crio.conf.d/50-kata-coldplug"

check_output "cold_plug_vfio = root-port" \
  'cold_plug_vfio = "root-port"' \
  node_exec "cat /etc/kata-containers/config.d/50-coldplug.toml"

check_output "pcie_root_port = 2" \
  'pcie_root_port = 2' \
  node_exec "cat /etc/kata-containers/config.d/50-coldplug.toml"

check_output "vfio_mode = guest-kernel" \
  'vfio_mode = "guest-kernel"' \
  node_exec "cat /etc/kata-containers/config.d/50-coldplug.toml"

check_output "static_sandbox_resource_mgmt = true" \
  'static_sandbox_resource_mgmt = true' \
  node_exec "cat /etc/kata-containers/config.d/50-coldplug.toml"

echo ""
echo "=== IOMMU checks ==="

check_output "IOMMU kernel args" \
  "intel_iommu=on" \
  node_exec "cat /proc/cmdline"

check_output "IOMMU groups exist" \
  "0" \
  node_exec "ls /sys/kernel/iommu_groups/ | head -1"

echo ""
echo "=== DPU VF checks ==="

check_output "VF resource available" \
  "$VF_RESOURCE" \
  bash -c "oc get node $NODE -o json | python3 -c \"import json,sys; d=json.load(sys.stdin); print([k for k in d['status']['allocatable'] if 'kata' in k.lower() or 'vf' in k.lower()])\""

PF1=$(node_exec "ls /sys/class/net/ | grep -E 'np1$' | head -1" | tr -d '[:space:]')
[ -z "$PF1" ] && PF1="ens4f1np1"

check_output "VFs on port 1 have IOMMU groups" \
  "iommu=" \
  node_exec "vf=/sys/class/net/$PF1/device/virtfn0 && pci=\$(basename \$(readlink \$vf)) && echo iommu=\$(basename \$(readlink /sys/bus/pci/devices/\$pci/iommu_group))"

check_output "VFs bound to mlx5_core (no stale vfio-pci)" \
  "mlx5_core" \
  node_exec "basename \$(readlink /sys/class/net/$PF1/device/virtfn0/driver)"

echo ""
echo "=== Webhook and NAD checks ==="

check_output "kata-coldplug RuntimeClass exists" \
  "kata-coldplug" \
  oc get runtimeclass kata-coldplug

check_output "Kata NAD exists" \
  "kata-coldplug" \
  oc get net-attach-def -n openshift-ovn-kubernetes -o name '|' grep kata

check_output "OVN-K webhook has kata runtimeclass mapping" \
  "kata-coldplug" \
  oc get deployment -n openshift-ovn-kubernetes -l app=ovn-kubernetes-resource-injector -o jsonpath='{.items[0].spec.template.spec.containers[0].args}'

echo ""
echo "=== DPU connectivity checks ==="

if [ -f "$DOCA_KUBECONFIG" ]; then
  check_output "DOCA cluster reachable" \
    "Ready" \
    env KUBECONFIG=$DOCA_KUBECONFIG oc get nodes

  check_output "DPU OVN pod running" \
    "Running" \
    env KUBECONFIG=$DOCA_KUBECONFIG oc get pods -n dpf-operator-system -o wide '|' grep ovn
else
  echo "SKIP: DOCA kubeconfig not found at $DOCA_KUBECONFIG"
fi

echo ""
echo "=== Pod test: kata-coldplug with DPU VF ==="

oc delete pod kata-dpu-smoke --ignore-not-found &>/dev/null
sleep 2
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: kata-dpu-smoke
spec:
  runtimeClassName: kata-coldplug
  nodeSelector:
    kubernetes.io/hostname: $NODE
  containers:
  - name: test
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["sleep", "120"]
    resources:
      limits:
        $VF_RESOURCE: "1"
      requests:
        $VF_RESOURCE: "1"
EOF

echo "Waiting for pod (up to 3 min)..."
if oc wait --for=condition=Ready pod/kata-dpu-smoke --timeout=180s &>/dev/null; then
  check_output "kata-dpu pod is Running" \
    "Running" \
    oc get pod kata-dpu-smoke

  check_output "Pod has IP from OVN" \
    "10\." \
    oc get pod kata-dpu-smoke -o jsonpath='{.status.podIP}'

  check_output "Webhook injected kata NAD" \
    "kata-coldplug" \
    oc get pod kata-dpu-smoke -o jsonpath='{.metadata.annotations.v1\.multus-cni\.io/default-network}'

  check_output "DPU connection details present" \
    "pfId" \
    oc get pod kata-dpu-smoke -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/dpu\.connection-details}'

  QEMU_VFIO=$(node_exec "ps aux | grep qemu-kvm | grep -o 'vfio-pci,host=[^ ]*'")
  if echo "$QEMU_VFIO" | grep -q "vfio-pci,host="; then
    echo "PASS: QEMU has VFIO device: $QEMU_VFIO"
    PASS=$((PASS + 1))
  else
    echo "FAIL: QEMU VFIO device not found in cmdline"
    FAIL=$((FAIL + 1))
  fi

  check_output "ARP to gateway resolves in VM" \
    "0a:58" \
    oc exec kata-dpu-smoke -- cat /proc/net/arp

  check_output "eth0 carrier up in VM" \
    "1" \
    oc exec kata-dpu-smoke -- cat /sys/class/net/eth0/carrier
else
  echo "FAIL: kata-dpu pod did not start within 3 min"
  FAIL=$((FAIL + 1))
fi
oc delete pod kata-dpu-smoke --ignore-not-found &>/dev/null

echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
echo "==============================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
