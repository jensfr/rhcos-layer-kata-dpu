#!/bin/bash
# Demo script for asciinema recording
# Usage: asciinema rec --command ./demo.sh demo.cast

KUBECONFIG="${KUBECONFIG:-$HOME/Downloads/cluster-bot-2026-07-03-095027.kubeconfig}"
export KUBECONFIG

# Simulate typing with a delay
type_cmd() {
  echo ""
  echo -n "$ "
  echo "$1" | while IFS= read -r -n1 char; do
    echo -n "$char"
    sleep 0.04
  done
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
echo "============================================================"
echo "  DPU/SR-IOV Cold-Plug VFIO Backport for OSC"
echo "  Upstream kata-containers PR #13103"
echo "  https://github.com/jensfr/rhcos-layer-kata-dpu"
echo "============================================================"
echo -e "\033[0m"
sleep 4

# Part 1: What works
echo -e "\033[1;32m>>> Part 1: What works\033[0m"
sleep 2

comment "Cluster is running OCP 4.22 with OSC installed"
type_cmd "oc get nodes"

comment "Patched kata-containers RPM (3.31.0-3) with 17 backported commits"
NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
type_cmd "oc debug node/$NODE -- chroot /host rpm -q --changelog kata-containers 2>&1 | grep -A2 '3.31.0-3' | grep -v '^Starting\|^Removing\|^To use'"

comment "kata-coldplug RuntimeClass with cold_plug_vfio enabled"
type_cmd "oc get runtimeclass"

comment "CRI-O knows the kata-coldplug handler"
type_cmd "oc debug node/$NODE -- chroot /host cat /etc/crio/crio.conf.d/50-kata-coldplug 2>&1 | grep -v '^Starting\|^Removing\|^To use'"

comment "cold_plug_vfio = root-port via config.d drop-in"
type_cmd "oc debug node/$NODE -- chroot /host cat /etc/kata-containers/config.d/50-coldplug.toml 2>&1 | grep -v '^Starting\|^Removing\|^To use'"

comment "mlx5/InfiniBand modules are in the kata guest initrd"
type_cmd "oc debug node/$NODE -- chroot /host lsinitrd /var/cache/kata-containers/osbuilder-images/kata.initrd 2>/dev/null 2>&1 | grep mlx5 | grep -v '^Starting\|^Removing\|^To use'"

comment "Start a pod with kata-coldplug RuntimeClass"
oc delete pod kata-coldplug-demo --ignore-not-found &>/dev/null
type_cmd "oc run kata-coldplug-demo --image=registry.access.redhat.com/ubi9/ubi-minimal:latest --restart=Never --overrides='{\"spec\":{\"runtimeClassName\":\"kata-coldplug\"}}' --command -- sleep 300"

echo "  Waiting for pod..."
oc wait --for=condition=Ready pod/kata-coldplug-demo --timeout=180s &>/dev/null
sleep 1

comment "Pod is running in a Kata VM with its own kernel"
type_cmd "oc exec kata-coldplug-demo -- uname -r"

comment "mlx5 and InfiniBand modules loaded in the VM guest"
type_cmd "oc exec kata-coldplug-demo -- cat /proc/modules | grep -E 'mlx5|ib_core|ib_uverbs|ib_umad'"

comment "Running the full test suite (18 checks)"
type_cmd "./test.sh"

oc delete pod kata-coldplug-demo --ignore-not-found &>/dev/null

# Part 2: What's missing
sleep 3
echo ""
echo -e "\033[1;31m>>> Part 2: Constraints and open work\033[0m"
sleep 3

echo -e "\033[1;36m"
cat <<'MSG'
WORKAROUNDS IN THIS PROTOTYPE:
  - RHCOS layer via rpm-ostree (not official extension mechanism)
  - Brew scratch build against rhaos-4.23 target (Go 1.25.10 not in 4.22 build root)
  - kata-coldplug RuntimeClass created manually (not via OSC operator)
  - config.d drop-in for cold_plug_vfio (not a dedicated configuration.toml)
MSG
sleep 6

cat <<'MSG'

OPEN WORK FOR PRODUCT INTEGRATION:
  - OSC operator: add feature gate + deploy kata-coldplug RuntimeClass and CRI-O config
  - confidential-compute-artifacts: add mlx5/IB modules to dracut config
  - Fix Go version mismatch: build must target rhaos-4.23 (Go 1.25.10)
  - Konflux pipeline: RPM build, RHCOS extension update, image rebuild trigger
  - Test on real DPU hardware (BlueField) -- only module loading verified here
  - No actual cold-plug VFIO passthrough tested (no SR-IOV VFs on this cluster)
MSG
sleep 6

cat <<'MSG'

RISKS FOR PRODUCT INTEGRATION:
  - Rust agent patches not verified on RHEL build infra (compiled in podman/UBI9)
  - config.d drop-in mechanism is relatively new -- validate with operator
  - RHCOS extension ships kata 3.25.0, we layer 3.31.0 on top (version mismatch)
  - 17 patches across Go + Rust -- merge conflicts possible on future rebases
MSG
sleep 6

echo -e "\033[0m"
echo -e "\033[1;33m"
echo "============================================================"
echo "  Repo: https://github.com/jensfr/rhcos-layer-kata-dpu"
echo "  Brew scratch build: task 71190778"
echo "  Upstream PR: https://github.com/kata-containers/kata-containers/pull/13103"
echo "============================================================"
echo -e "\033[0m"
sleep 4
