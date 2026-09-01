# Kata Containers DPU/SR-IOV Cold-Plug VFIO Support

Cold-plug VFIO passthrough for BlueField-3 SR-IOV VFs into Kata VMs
on OpenShift with DPF (DOCA Platform Framework) and OVN-Kubernetes.

![Demo: Kata VM with cold-plugged BlueField-3 VF](demo-dpu-coldplug.gif)

## What it does

A BlueField-3 SR-IOV VF is passed into a Kata VM via VFIO at VM launch
(cold-plug). The OVN-K webhook automatically injects the correct DPU
network attachment. Inside the VM, the mlx5 driver loads and provides
a 100 GbE network interface with L2 connectivity to the OVN gateway.

## Prerequisites

- OpenShift 4.22 cluster with DPF (DOCA Platform Framework) deployed
- OSC (OpenShift Sandboxed Containers) operator installed
- NVIDIA OVN-K webhook configured with `--runtime-class-nad-mapping=kata-coldplug=<kata-nad>`
- SR-IOV VF pool for kata (e.g. `openshift.io/bf3-p1-vfs-kata`)
- IOMMU enabled on DPU host nodes (`intel_iommu=on iommu=pt`)

## Deployment options

| Method | When to use | Guide |
|--------|-------------|-------|
| **RPM only** | 1-2 test nodes, or z-stream production | [DEPLOY-RPM-ONLY.md](DEPLOY-RPM-ONLY.md) |
| **RHCOS layer** | Multiple test nodes without z-stream | See below |

For most cases, the **RPM-only** path is recommended. The RHCOS layer
is only needed if you cannot install the RPM via `rpm-ostree override replace`
(e.g. no VPN access to download the RPM).

## Quick start: RHCOS layer (test cluster, multiple nodes)

For testing without a z-stream OCP release. Uses an RHCOS layered
image that the MCO rolls out to all nodes in the MachineConfigPool
automatically.

### Step 1: Deploy RHCOS layer + OSC operator

```bash
# Install OSC operator (skip if already installed)
oc apply -f 01-osc-operator.yaml
# Wait for CSV to succeed

# Create KataConfig
oc apply -f 02-kataconfig.yaml
# Wait for kata install (10-30 min, involves node reboots)

# Apply RHCOS layered image with patched kata RPM
oc apply -f 03-rhcos-layer.yaml
# Wait for node reboot (10-15 min)
```

### Step 2: Enable IOMMU

```bash
# Create MachineConfig for IOMMU kernel args
cat <<EOF | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: kata-oc
  name: 99-iommu-enable
spec:
  kernelArguments:
    - intel_iommu=on
    - iommu=pt
EOF
# Wait for node reboot

# Note: on image-layered RHCOS, kernelArguments may not work.
# The RHCOS layer image includes bootc kargs.d as a fallback.
```

### Step 3: Create RuntimeClass

```bash
oc apply -f kata-coldplug-runtimeclass.yaml
```

### Step 4: DPU networking recovery (after every host reboot)

See "DPU networking workaround" section below.

### Step 5: Test

```bash
# Adjust the VF resource name to match your DPF device plugin
oc apply -f 05-test-pod.yaml
oc wait --for=condition=Ready pod/kata-dpu-test --timeout=180s

# Verify VF is in the VM
oc exec kata-dpu-test -- cat /sys/class/net/eth0/speed    # 100000 (100 GbE)
oc exec kata-dpu-test -- cat /proc/modules | grep mlx5     # mlx5_core loaded
oc exec kata-dpu-test -- cat /proc/net/arp                 # ARP to gateway
```

### Run the full test suite

```bash
export VF_RESOURCE=openshift.io/bf3-p1-vfs-kata  # adjust to your pool
./test.sh
```

### Record a demo

```bash
export KUBECONFIG=/path/to/kubeconfig
export DOCA_KUBECONFIG=/path/to/doca-kubeconfig
asciinema rec demo-dpu-coldplug.cast
bash demo-dpu-coldplug.sh
exit
agg demo-dpu-coldplug.cast demo-dpu-coldplug.gif
```

## Alternative: install RPM directly (1-2 test nodes)

For quick testing on a small number of nodes where OSC is already
installed. Must be repeated on each node individually.

```bash
# Download RPM from Brew (requires RH VPN)
RPM_URL=https://download.devel.redhat.com/brewroot/work/tasks/9551/71569551/kata-containers-3.31.0-5.rhaos4.22.el9.x86_64.rpm

# On each DPU host node:
oc debug node/<node> -- chroot /host bash -c "
  curl -skL -o /tmp/kata.rpm $RPM_URL
  rpm-ostree override replace /tmp/kata.rpm
"
# Reboot the node
oc debug node/<node> -- chroot /host systemctl reboot
```

Then apply RuntimeClass and IOMMU MachineConfig (Steps 2-3 above).

## Production deployment (z-stream)

With the z-stream OCP release containing kata-containers 3.31.0-5+,
no RHCOS layer is needed. The RPM ships everything:

- 8 patches from upstream PR #13103
- CRI-O handler for `kata-coldplug`
- config.d drop-in (cold_plug_vfio, pcie_root_port, vfio_mode)
- mlx5/IB modules in the kata guest initrd dracut config

Customer steps:
1. Upgrade to the OCP z-stream release
2. Enable IOMMU via MachineConfig (see Step 2 above)
3. Create RuntimeClass: `oc apply -f kata-coldplug-runtimeclass.yaml`
4. Configure DPF (NVIDIA side: webhook, VF pool, NAD)

No OSC operator upgrade required.

## DPU networking workaround (after host reboot)

After a host reboot the DPU loses the IPv4 address on `br-dpu`,
breaking all pod networking. This is a known DPF bug (documented in
DPF v24.10.0 release notes). Recovery steps:

```bash
# Get the DOCA admin kubeconfig
oc get secret doca-admin-kubeconfig -n dpf-operator-system \
  -o jsonpath='{.data.super-admin\.conf}' | base64 -d > /tmp/doca-kubeconfig.yaml

# Find the DPU node name
DPU_NODE=$(KUBECONFIG=/tmp/doca-kubeconfig.yaml oc get nodes \
  -o jsonpath='{.items[0].metadata.name}')

# 1. Restart OVS on DPU (fixes DPDK attach errors after host reboot)
KUBECONFIG=/tmp/doca-kubeconfig.yaml oc debug node/$DPU_NODE -- \
  chroot /host systemctl restart openvswitch

# 2. Add host management IP to br-dpu (use /32 to avoid route conflicts)
HOST_IP=$(oc get node <host-node> -o jsonpath='{.status.addresses[0].address}')
KUBECONFIG=/tmp/doca-kubeconfig.yaml oc debug node/$DPU_NODE -- \
  chroot /host ip addr add $HOST_IP/32 dev br-dpu

# 3. Restart OVN pod on DPU cluster
KUBECONFIG=/tmp/doca-kubeconfig.yaml oc delete pod -n dpf-operator-system <doca-ovn-pod>

# 4. Restart OVN pod on host cluster
oc delete pod -n openshift-ovn-kubernetes <ovnkube-node-dpu-host-pod>
```

Wait 2-3 minutes after step 4, then pods should start normally.

Root cause: OVN-K masquerade reconciler needs a non-link-local IPv4 on br-dpu.
The code filters out 169.254.x.x addresses (`IsLinkLocalUnicast`), so the host
management IP (e.g. 10.26.16.30) must be used. Use /32 to avoid routing conflicts
with the DPU management bridge (br-comm-ch on the same /24 subnet).

## Stale VF cleanup

If a kata pod fails during startup, it may leave VFs with
`driver_override=vfio-pci` set. Subsequent pods that get these VFs
from the device plugin will fail because the VF has no netdev.

```bash
oc debug node/<node> -- chroot /host bash -c '
for pf in $(ls /sys/class/net/ | grep np); do
  for vf in /sys/class/net/$pf/device/virtfn*; do
    pci=$(basename $(readlink $vf))
    driver=$(basename $(readlink /sys/bus/pci/devices/$pci/driver) 2>/dev/null || echo "UNBOUND")
    if [ "$driver" != "mlx5_core" ]; then
      echo "" > /sys/bus/pci/devices/$pci/driver_override
      echo $pci > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null
      echo $pci > /sys/bus/pci/drivers/mlx5_core/bind
      echo "Fixed $pci"
    fi
  done
done'
```

## Files

| File | Purpose |
|------|---------|
| `Containerfile` | RHCOS layered image build (for test clusters) |
| `01-osc-operator.yaml` | OSC operator install |
| `02-kataconfig.yaml` | KataConfig CR |
| `03-rhcos-layer.yaml` | MachineConfig pointing to the layered image |
| `04-kata-coldplug.yaml` | MachineConfig + RuntimeClass (not needed with z-stream RPM) |
| `05-test-pod.yaml` | Test pod spec |
| `kata-coldplug-runtimeclass.yaml` | Standalone RuntimeClass YAML |
| `test.sh` | Automated test suite |
| `demo-dpu-coldplug.sh` | Demo recording script |

## Brew scratch build

Latest RPM: task 71569544 (kata-containers-3.31.0-5, target rhaos-4.23-rhel-9-candidate).

RPM spec branch: `dpu-coldplug-zstream` on gitlab.com/jfreiman/kata-containers

## Upstream

https://github.com/kata-containers/kata-containers/pull/13103
