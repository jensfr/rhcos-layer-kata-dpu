# Kata DPU Cold-Plug VFIO via RHCOS Layer

Install Kata Containers 4.1.0 with DPU/SR-IOV cold-plug VFIO support
on OpenShift 4.22 using an RHCOS layered image. No OSC operator
installation required.

## What the layer provides

The RHCOS layer image contains kata-containers 4.1.0-3 with:

- Upstream PR #13103 (cold-plug VFIO, included natively in 4.1.0)
- Revert of upstream commit d3291b87 (TaskExit ordering, temporary)
- CRI-O handler `50-kata-coldplug`
- config.d drop-in `50-kata-coldplug.toml` (cold_plug_vfio=root-port,
  pcie_root_port=2, vfio_mode=guest-kernel)
- `/etc/modules-load.d/kata-vfio.conf` (boot-time vfio-pci loading)
- mlx5/InfiniBand modules in the dracut config (built into the guest
  initrd at boot by `kata-osbuilder-generate.service`)
- SELinux policy (osc_monitor module, from RPM postinstall)

No additional MachineConfig for CRI-O or kata configuration is needed.
The RPM ships all config files.

## Prerequisites

- OpenShift 4.22 cluster
- A MachineConfigPool targeting the desired nodes (e.g. `worker-dpu`)
- `oc` CLI authenticated to the cluster

For DPU clusters:
- NVIDIA DPF deployed with OVN-K webhook
- IOMMU enabled on DPU host nodes (BIOS or MachineConfig)

## Installation

```bash
./deploy.sh worker-dpu
```

For SNO testing:
```bash
./deploy.sh master
```

The script applies the RHCOS layer, waits for the MCP rollout (nodes
reboot), creates the RuntimeClass, and verifies the installation on
all target nodes.

### What deploy.sh does

1. Validates the target MCP exists and has nodes
2. Applies the RHCOS layer MachineConfig (nodes reboot)
3. Waits until the MCP has fully applied the rendered config containing
   the expected layer digest
4. Creates the `kata-coldplug` RuntimeClass with scheduling on the
   target nodes
5. Verifies on every target node: RPM version, initrd, kernel symlinks,
   CRI-O handler, config.d, vfio-pci module config, mlx5 in initrd

### Manual steps

```bash
# 1. Apply layer (adjust role to your MCP)
oc apply -f 03-rhcos-layer.yaml
# Wait for node reboot and MCP completion

# 2. Create RuntimeClass (adjust nodeSelector)
oc apply -f kata-coldplug-runtimeclass.yaml

# 3. Test
oc apply -f 05-test-pod.yaml
oc wait --for=condition=Ready pod/kata-coldplug-test --timeout=120s
oc exec kata-coldplug-test -- cat /proc/version
```

## Removing the layer

```bash
oc delete mc 99-kata-dpu-layered
oc delete runtimeclass kata-coldplug
# Wait for MCP rollout (nodes reboot to stock RHCOS)
```

## How it works without the OSC operator

The kata RPM includes a systemd service (`kata-osbuilder-generate.service`)
with a systemd preset that enables it at install time. On first boot after
the layer is applied, this service builds the guest initrd from the host
kernel using the dracut config shipped in the RPM. The SELinux policy module
(`osc_monitor`) is installed by the RPM's postinstall scriptlet.

No DS installer, no KataConfig CR, and no operator are involved.

## RHCOS layer image

- Image: `quay.io/jensfr/rhcos-kata-dpu:4.22-v6-kata410`
- Digest: `sha256:83140f34a7a25d77f0d98bbcc512dddf7dfbe9961f7e05ee9c896519d1736719`
- RPM: `kata-containers-4.1.0-3.rhaos4.22.el9` (Brew task 71976541)
- RPM branch: `dpu-4.1.0-rhel9` on gitlab.com/jfreiman/kata-containers
- Base: RHCOS 4.22 + OCP extensions (qemu-kvm-core, virtiofsd)

### Rebuilding

```bash
podman build --platform linux/amd64 \
  --authfile ~/Downloads/pull-secret.txt \
  -t quay.io/jensfr/rhcos-kata-dpu:4.22-v6-kata410 \
  -f Containerfile .
podman push quay.io/jensfr/rhcos-kata-dpu:4.22-v6-kata410
# Update digest in 03-rhcos-layer.yaml
```

## For DPU testing (Igal)

The layer targets `worker-dpu` by default in the manifests. Igal's
existing `worker-dpu` MCP is used directly. No `kata-oc` MCP conflict.

After layer installation, configure the NVIDIA OVN-K webhook:
```
--runtime-class-nad-mapping=kata-coldplug=<kata-nad-name>
```

VFIO passthrough and DPU network connectivity require DPU hardware
and are not covered by the layer-only test.

## Test results

### Fresh cluster (no prior kata installation)
- Cluster-Bot OCP 4.22 nightly, 3 worker nodes, no OSC operator
- Layer applied via MCP `worker`, all 3 nodes updated
- kata 4.1.0-3 active, initrd built with mlx5 modules
- CRI-O handler, config.d, vfio-pci module-load, SELinux all from RPM
- kata-coldplug pod: start, exec, delete, QEMU/Shim cleanup confirmed

### Existing cluster (SNO, prior DS installation removed)
- virtlab2400 OCP 4.22.13 GA, SNO
- Layer on top of prior DS installation (cleaned up)
- kata 4.1.0-3 active after reboot
- Pod lifecycle confirmed after additional reboot

### Open
- VFIO passthrough with DPU hardware (requires Igal's cluster)
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
