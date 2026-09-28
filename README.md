# HOWTO: Install Kata 4.1 with DPU Cold-Plug VFIO via RHCOS Layer

Layer-only installation of Kata Containers 4.1.0-3 with SR-IOV cold-plug
VFIO support for BlueField-3 DPU on OpenShift 4.22. No OSC operator
installation needed.

The image contains Kata, the coldplug configuration, guest initrd
generation and mlx5 modules. You do not need to build anything.

Installation on a fresh cluster, pod lifecycle and an additional reboot
have been tested. Actual DPU passthrough and networking still need
validation on DPU hardware.

## 1. Check the starting state

You need an OpenShift 4.22 x86_64 test cluster, cluster-admin access,
and `git`, `bash`, `python3` and `oc` locally.

```bash
oc whoami --show-server
oc get clusterversion version
oc get mcp worker-dpu
oc get nodes -l node-role.kubernetes.io/worker-dpu -o wide
```

The commands below assume that the `worker-dpu` pool selects
MachineConfigs labelled `machineconfiguration.openshift.io/role: worker-dpu`,
and its nodes carry `node-role.kubernetes.io/worker-dpu`.

**No OSC installer may manage these nodes in parallel.** If your previous
OSC/KataConfig installation is still active or stuck, resolve it before
applying the layer:

```bash
oc get kataconfig
oc get ds,pods -n openshift-sandboxed-containers-operator -o wide
```

Simply deleting installer pods is insufficient because the operator
recreates them. Deleting KataConfig starts an uninstall, so complete
any previous cleanup before installing this layer.

Keep the existing ClusterImagePolicy enabled.

## 2. Check out the reviewed version

```bash
git clone --branch layer-only \
  https://github.com/jensfr/rhcos-layer-kata-dpu.git \
  rhcos-layer-kata-dpu-layer-only

cd rhcos-layer-kata-dpu-layer-only

git checkout --detach 4119781
```

If `99-kata-dpu-layered` already exists from an earlier attempt, save its
current definition before replacing it:

```bash
oc get mc 99-kata-dpu-layered -o yaml > previous-kata-layer.yaml
```

Skip that backup command if the MachineConfig does not exist.

## 3. Install on worker-dpu

```bash
bash ./deploy.sh worker-dpu
```

**This rolls out an OS image and reboots the target nodes.** Plan for
workload disruption on that pool.

The script applies the pinned image, waits for the correct
image/configuration to finish rolling out, creates `kata-coldplug` with
node scheduling, and checks each target node.

You can monitor progress in another terminal:

```bash
oc get mcp worker-dpu -w
```

Completion should show `UPDATED=True`, `UPDATING=False`, and
`DEGRADED=False`.

For SNO testing without a `worker-dpu` pool:

```bash
bash ./deploy.sh master
```

## 4. Run the smoke test

Use a dedicated test project. Run this before starting other Kata
workloads, because the cleanup check assumes no other Kata VMs on the
test node.

```bash
oc new-project kata-dpu-smoke
bash ./test.sh worker-dpu
```

If the project already exists, select it with `oc project kata-dpu-smoke`.

The test checks the installed files and version, starts a `kata-coldplug`
pod, executes a command inside it, deletes it, and checks QEMU/Shim
cleanup. Expect a final summary with zero failures.

## 5. Test the DPU workload

After the smoke test passes:

- Confirm IOMMU is active on the DPU host.
- Configure your OVN-K webhook/NAD mapping for `kata-coldplug`.
- Use `runtimeClassName: kata-coldplug` in your DPU workload.
- Use your actual NAD and VF resource name.
- Verify the device and mlx5 driver inside the guest, network
  connectivity, and cleanup after pod deletion.

The repository's `05-test-pod.yaml` does **not** request a DPU device;
it only checks the Kata runtime.

## Removal

First stop the test workloads. Then remove the MachineConfig and
RuntimeClass:

```bash
oc delete runtimeclass kata-coldplug
oc delete mc 99-kata-dpu-layered
oc get mcp worker-dpu -w
```

This causes another OS rollout/reboot. If you replaced an existing layer
MachineConfig, restore its saved definition instead of deleting it.

## What the layer provides

The RHCOS layer image contains kata-containers 4.1.0-3 with:

- Upstream PR #13103 (cold-plug VFIO, included natively in 4.1.0)
- Revert of upstream commit d3291b87 (TaskExit ordering, temporary
  until upstream fix lands)
- CRI-O handler `50-kata-coldplug`
- config.d drop-in `50-kata-coldplug.toml` (cold_plug_vfio=root-port,
  pcie_root_port=2, vfio_mode=guest-kernel)
- `/etc/modules-load.d/kata-vfio.conf` (boot-time vfio-pci loading)
- mlx5/InfiniBand modules in the dracut config (built into the guest
  initrd at boot by `kata-osbuilder-generate.service`)
- SELinux policy (osc_monitor module, from RPM postinstall)

No additional MachineConfig for CRI-O or kata configuration is needed.
The RPM ships all config files. The osbuilder service builds the guest
initrd at boot. This installation is independent of the OSC operator.

## RHCOS layer image

- Image: `quay.io/jensfr/rhcos-kata-dpu:4.22-v6-kata410`
- Digest: `sha256:83140f34a7a25d77f0d98bbcc512dddf7dfbe9961f7e05ee9c896519d1736719`
- RPM: `kata-containers-4.1.0-3.rhaos4.22.el9` (Brew task 71976541)
- RPM branch: `dpu-4.1.0-rhel9` on gitlab.com/jfreiman/kata-containers
- Base: RHCOS 4.22 + OCP extensions (qemu-kvm-core, virtiofsd)

## Rebuilding the layer

```bash
podman build --platform linux/amd64 \
  --authfile ~/Downloads/pull-secret.txt \
  -t quay.io/jensfr/rhcos-kata-dpu:4.22-v6-kata410 \
  -f Containerfile .
podman push quay.io/jensfr/rhcos-kata-dpu:4.22-v6-kata410
# Update digest in 03-rhcos-layer.yaml
```

## Test results

### Fresh cluster (no prior kata installation)
- Cluster-Bot OCP 4.22 nightly, 3 worker nodes, no OSC operator
- Layer applied via MCP `worker`, all 3 nodes updated
- deploy.sh and test.sh: 36/36 checks passed, 0 failures
- kata 4.1.0-3 active, initrd built with mlx5 modules
- CRI-O handler, config.d, vfio-pci module-load, SELinux all from RPM
- kata-coldplug pod: start, exec, delete, QEMU/Shim cleanup confirmed

### Existing cluster (SNO, prior DS installation removed)
- virtlab2400 OCP 4.22.13 GA, SNO
- Layer on top of prior DS installation (cleaned up)
- kata 4.1.0-3 active after reboot
- Pod lifecycle confirmed after additional reboot

### Open
- VFIO passthrough with DPU hardware (requires DPU cluster)
- DPU br-dpu recovery after host reboot (known DPF bug)
- L3 connectivity through DPU OVN pipeline

## Files

| File | Purpose |
|------|---------|
| `Containerfile` | RHCOS layer build (4.1.0-3 + extensions) |
| `03-rhcos-layer.yaml` | MachineConfig with osImageURL |
| `kata-coldplug-runtimeclass.yaml` | RuntimeClass (adjust nodeSelector) |
| `05-test-pod.yaml` | Test pod (no DPU device request) |
| `deploy.sh` | Automated deploy + verify |
| `test.sh` | Automated test suite |
