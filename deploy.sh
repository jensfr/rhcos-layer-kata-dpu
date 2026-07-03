#!/bin/bash
# Deploy DPU/SR-IOV cold-plug VFIO backport on OpenShift Sandboxed Containers
# Works on SNO (single-node), compact (3 master/worker), and standard (3+3) clusters

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

wait_for_api() {
  echo "  waiting for API..."
  until oc get nodes &>/dev/null; do sleep 15; done
}

detect_role() {
  if oc get mcp kata-oc &>/dev/null; then
    echo "kata-oc"
  else
    echo "master"
  fi
}

apply_with_role() {
  local file=$1
  local role=$2
  sed "s/machineconfiguration.openshift.io\/role: .*/machineconfiguration.openshift.io\/role: ${role}/" "$file" | oc apply -f -
}

echo "=== Step 1: Install OSC operator ==="
oc apply -f "$SCRIPT_DIR/01-osc-operator.yaml"

echo "Waiting for operator..."
until oc get csv -n openshift-sandboxed-containers-operator -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Succeeded"; do
  sleep 10
done
echo "Operator ready."

echo "=== Step 2: Create KataConfig ==="
oc apply -f "$SCRIPT_DIR/02-kataconfig.yaml"

echo "Waiting for kata install (nodes will reboot)..."
while true; do
  INPROG=$(oc get kataconfig example-kataconfig -o jsonpath='{.status.conditions[?(@.type=="InProgress")].status}' 2>/dev/null)
  INSTALLED=$(oc describe kataconfig 2>/dev/null | grep "Ready Node Count" | awk '{print $NF}')
  TOTAL=$(oc describe kataconfig 2>/dev/null | grep "Node Count:" | head -1 | awk '{print $NF}')

  if [ "$INPROG" = "False" ] && [ -n "$TOTAL" ] && [ "$TOTAL" != "0" ]; then
    echo "Kata installed on $TOTAL nodes."
    break
  fi

  echo "  installed=${INSTALLED:-?}/${TOTAL:-?}"

  # On SNO the API goes away during reboot
  if ! oc get nodes &>/dev/null; then
    echo "  API unavailable (node rebooting)..."
    wait_for_api
  fi

  sleep 30
done

echo "=== Step 3: Apply RHCOS layered image ==="
ROLE=$(detect_role)
echo "  detected MCP role: $ROLE"
apply_with_role "$SCRIPT_DIR/03-rhcos-layer.yaml" "$ROLE"

echo "=== Step 4: Apply kata-coldplug config ==="
apply_with_role "$SCRIPT_DIR/04-kata-coldplug.yaml" "$ROLE"

echo "Waiting for MCP rollout (nodes will reboot)..."
while true; do
  if ! oc get nodes &>/dev/null; then
    echo "  API unavailable (node rebooting)..."
    wait_for_api
    sleep 30
    continue
  fi

  POOL=$(detect_role)
  READY=$(oc get mcp $POOL -o jsonpath='{.status.readyMachineCount}' 2>/dev/null)
  TOTAL=$(oc get mcp $POOL -o jsonpath='{.status.machineCount}' 2>/dev/null)
  UPDATED=$(oc get mcp $POOL -o jsonpath='{.status.updatedMachineCount}' 2>/dev/null)
  DEG=$(oc get mcp $POOL -o jsonpath='{.status.degradedMachineCount}' 2>/dev/null)

  echo "  ready=$READY/$TOTAL updated=$UPDATED degraded=$DEG"

  if [ "$READY" = "$TOTAL" ] && [ "$UPDATED" = "$TOTAL" ] && [ "$TOTAL" != "0" ] 2>/dev/null; then
    echo "All nodes updated."
    break
  fi

  if [ "${DEG:-0}" != "0" ]; then
    echo "ERROR: MCP degraded!"
    oc get mcp $POOL -o jsonpath='{.status.conditions[?(@.type=="Degraded")].message}' 2>&1
    echo
    exit 1
  fi

  sleep 30
done

echo "=== Step 5: Verify ==="
oc get runtimeclass
echo ""
NODE=$(oc get nodes -l node-role.kubernetes.io/kata-oc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$NODE" ] && NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
echo "Checking node $NODE..."
oc debug node/$NODE -- chroot /host bash -c "
  echo 'RPM version:' && rpm -q kata-containers
  echo 'cold_plug_vfio:' && cat /etc/kata-containers/config.d/50-coldplug.toml
  echo 'mlx5 in initrd:' && lsinitrd /var/cache/kata-containers/osbuilder-images/kata.initrd 2>/dev/null | grep mlx5_core
" 2>&1 | grep -v "^Starting\|^Removing\|^To use"

echo ""
echo "=== Deployment complete ==="
echo "Test with: oc apply -f $SCRIPT_DIR/05-test-pod.yaml"
echo "Then:      oc exec kata-coldplug-test -- cat /proc/modules | grep mlx5"
