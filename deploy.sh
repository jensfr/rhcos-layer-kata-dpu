#!/bin/bash
# Install Kata with DPU cold-plug VFIO support via RHCOS layer only.
#
# No OSC operator, no DS installer, no KataConfig needed.
# The RHCOS layer provides the kata RPM with all config files.
# The osbuilder service builds the initrd at boot.
#
# Usage: ./deploy.sh <MCP_ROLE>
#   MCP_ROLE is required. Use the MCP that targets your DPU worker nodes
#   (e.g. worker-dpu). For SNO testing, use master.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MCP_ROLE="${1:-}"

if [ -z "$MCP_ROLE" ]; then
  echo "Usage: $0 <MCP_ROLE>"
  echo "  e.g. $0 worker-dpu    (for DPU clusters)"
  echo "       $0 master         (for SNO testing)"
  exit 1
fi

err() { echo "ERROR: $*" >&2; exit 1; }

# Validate MCP
if ! oc get mcp "$MCP_ROLE" &>/dev/null; then
  err "MCP '$MCP_ROLE' does not exist."
fi
MC_COUNT=$(oc get mcp "$MCP_ROLE" -o jsonpath='{.status.machineCount}' 2>/dev/null)
echo "MCP '$MCP_ROLE': $MC_COUNT node(s)"
[ "${MC_COUNT:-0}" = "0" ] && err "MCP '$MCP_ROLE' has 0 nodes."

wait_mcp() {
  # Wait until the MCP has fully applied a rendered config that includes our
  # layer MachineConfig with the expected osImageURL digest. Checks the desired
  # state, not a transition -- an already-applied identical layer succeeds
  # immediately.
  local expected_digest="$1"
  local timeout=1800
  local start=$SECONDS

  while true; do
    if (( SECONDS - start > timeout )); then
      err "MCP rollout timed out after ${timeout}s"
    fi

    # Single JSON fetch for consistent snapshot; tolerate transient API errors.
    local mcp_json
    if ! mcp_json=$(oc get mcp "$MCP_ROLE" -o json --request-timeout=10s 2>/dev/null); then
      echo "  API unavailable, retrying..."
      sleep 15
      continue
    fi

    local ready total degraded
    local spec_config status_config
    local cond_updated cond_updating

    ready=$(echo "$mcp_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['status'].get('readyMachineCount',0))")
    total=$(echo "$mcp_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['status'].get('machineCount',0))")
    degraded=$(echo "$mcp_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['status'].get('degradedMachineCount',0))")
    spec_config=$(echo "$mcp_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['spec'].get('configuration',{}).get('name',''))")
    status_config=$(echo "$mcp_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['status'].get('configuration',{}).get('name',''))")
    cond_updated=$(echo "$mcp_json" | python3 -c "import json,sys; d=json.load(sys.stdin); cs=d['status'].get('conditions',[]); print(next((c['status'] for c in cs if c['type']=='Updated'),''))")
    cond_updating=$(echo "$mcp_json" | python3 -c "import json,sys; d=json.load(sys.stdin); cs=d['status'].get('conditions',[]); print(next((c['status'] for c in cs if c['type']=='Updating'),''))")

    echo "  ready=$ready/$total spec=$spec_config status=$status_config updated=$cond_updated updating=$cond_updating degraded=$degraded"

    if [ "$degraded" != "0" ]; then
      err "MCP '$MCP_ROLE' is degraded."
    fi

    # Verify rendered config includes our layer digest.
    # Both the digest check and the MCP completion check must pass together.
    local digest_confirmed=false
    if [ -n "$spec_config" ] && [ -n "$expected_digest" ]; then
      local rendered_url
      rendered_url=$(oc get mc "$spec_config" -o jsonpath='{.spec.osImageURL}' --request-timeout=10s 2>/dev/null)
      if [ -z "$rendered_url" ]; then
        echo "  Cannot read rendered MC osImageURL, retrying..."
        sleep 15
        continue
      fi
      if echo "$rendered_url" | grep -q "$expected_digest"; then
        digest_confirmed=true
      else
        echo "  Rendered config does not include expected digest, waiting..."
        sleep 15
        continue
      fi
    fi

    # Desired state: digest confirmed in rendered config, spec and status
    # configs match, Updated=True, Updating=False, all nodes ready.
    if [ "$digest_confirmed" = true ] \
       && [ "$spec_config" = "$status_config" ] && [ -n "$spec_config" ] \
       && [ "$cond_updated" = "True" ] && [ "$cond_updating" = "False" ] \
       && [ "$ready" = "$total" ] && [ "$total" != "0" ]; then
      return
    fi

    sleep 30
  done
}

LAYER_DIGEST=$(grep 'osImageURL:' "$SCRIPT_DIR/03-rhcos-layer.yaml" | grep -o 'sha256:[a-f0-9]*')
[ -z "$LAYER_DIGEST" ] && err "Cannot extract digest from 03-rhcos-layer.yaml"

echo ""
echo "=== Step 1: Apply RHCOS layer ==="
echo "  Expected digest: $LAYER_DIGEST"
sed "s|machineconfiguration.openshift.io/role: .*|machineconfiguration.openshift.io/role: ${MCP_ROLE}|" \
  "$SCRIPT_DIR/03-rhcos-layer.yaml" | oc apply -f -
echo "Waiting for MCP rollout (nodes will reboot)..."
wait_mcp "$LAYER_DIGEST"
echo "  Layer applied."

echo ""
echo "=== Step 2: Create RuntimeClass ==="
sed "s|node-role.kubernetes.io/REPLACE_ROLE|node-role.kubernetes.io/${MCP_ROLE}|" \
  "$SCRIPT_DIR/kata-coldplug-runtimeclass.yaml" | oc apply -f -

echo ""
echo "=== Step 3: Verify ==="
EXPECTED_RPM="kata-containers-4.1.0-3"
NODES=$(oc get nodes -l "node-role.kubernetes.io/$MCP_ROLE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
[ -z "$NODES" ] && err "No nodes with role $MCP_ROLE"

verify_fail=0
for NODE in $NODES; do
  echo "--- Node: $NODE ---"
  result=$(oc debug node/"$NODE" -- chroot /host bash -c '
    rpm_v=$(rpm -q kata-containers 2>/dev/null)
    initrd=$(readlink -f /var/cache/kata-containers/osbuilder-images/kata.initrd 2>/dev/null)
    kernel=$(readlink -f /var/cache/kata-containers/osbuilder-images/kata.kernel 2>/dev/null)
    crio=$(test -f /etc/crio/crio.conf.d/50-kata-coldplug && echo "ok" || echo "MISSING")
    configd=$(test -f /etc/kata-containers/config.d/50-kata-coldplug.toml && echo "ok" || echo "MISSING")
    vfio=$(test -f /etc/modules-load.d/kata-vfio.conf && echo "ok" || echo "MISSING")
    coldplug=$(grep -q "cold_plug_vfio" /etc/kata-containers/config.d/50-kata-coldplug.toml 2>/dev/null && echo "ok" || echo "MISSING")
    mlx5=$(lsinitrd /var/cache/kata-containers/osbuilder-images/kata.initrd 2>/dev/null | grep -c mlx5_core.ko)

    echo "rpm=$rpm_v"
    echo "initrd=$initrd"
    echo "kernel=$kernel"
    echo "crio_handler=$crio"
    echo "config_d=$configd"
    echo "vfio_module=$vfio"
    echo "coldplug_config=$coldplug"
    echo "mlx5_count=$mlx5"
  ' 2>&1 | grep -v "^Starting\|^Removing\|^Temporary\|^To use")

  echo "$result"

  if ! echo "$result" | grep -q "rpm=$EXPECTED_RPM"; then
    echo "  FAIL: expected RPM $EXPECTED_RPM"
    verify_fail=1
  fi
  if echo "$result" | grep -q "MISSING"; then
    echo "  FAIL: missing files detected"
    verify_fail=1
  fi
  if echo "$result" | grep -q "initrd=$" || echo "$result" | grep -q "kernel=$"; then
    echo "  FAIL: initrd or kernel symlink missing"
    verify_fail=1
  fi
  if echo "$result" | grep -q "mlx5_count=0"; then
    echo "  FAIL: mlx5 modules not in initrd"
    verify_fail=1
  fi
done

[ "$verify_fail" -ne 0 ] && err "Verification failed on one or more nodes."
echo "All nodes verified."

echo ""
echo "=== Done ==="
echo "Test: oc apply -f $SCRIPT_DIR/05-test-pod.yaml"
echo "      oc wait --for=condition=Ready pod/kata-coldplug-test --timeout=120s"
echo "      oc exec kata-coldplug-test -- cat /proc/version"
