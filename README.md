# DPU/SR-IOV Cold-Plug VFIO Backport for OSC

RHCOS layered image and deployment manifests for testing the DPU/SR-IOV
cold-plug VFIO backport (upstream PR #13103) on OpenShift Sandboxed Containers.

![Demo: Kata VM with cold-plugged BlueField-3 VF](demo-dpu-coldplug.gif)

## What's included

- **Patched kata-containers RPM** (3.31.0-3): 17 commits from upstream PR #13103
  backported onto the OCP 4.22 kata-containers base. Fixes end-to-end cold-plug
  VFIO with `vfio_mode = "guest-kernel"` for SR-IOV RoCE/InfiniBand (BlueField DPU).

- **RHCOS layered image**: Base RHCOS 4.22 + qemu-kvm-core + virtiofsd +
  patched kata RPM + mlx5/InfiniBand kernel modules in the kata guest initrd.

- **`kata-coldplug` RuntimeClass**: Device-neutral cold-plug VFIO runtime class.
  Uses the base kata configuration with `cold_plug_vfio = "root-port"` via config.d drop-in.

## Prerequisites

- OpenShift 4.22 cluster with nested virtualization support (for testing without DPU hardware)
  - Azure: Dv3/Dv4/Dv5/Ev5 series (NOT B-series)
  - AWS: metal instances or i3/m5/c5 with nested virt
  - Bare metal: works out of the box
- `oc` CLI authenticated to the cluster

## Quick deploy

```bash
./deploy.sh
```

Or step by step:

```bash
# 1. Install OSC operator
oc apply -f 01-osc-operator.yaml
# Wait for CSV to succeed

# 2. Create KataConfig (standard kata, no peer pods)
oc apply -f 02-kataconfig.yaml
# Wait for kata install on all nodes (10-30 min, involves node reboots)

# 3. Apply RHCOS layered image with DPU patches
oc apply -f 03-rhcos-layer.yaml
# Wait for MCP rollout (10-15 min per node)

# 4. Apply kata-coldplug CRI-O config + RuntimeClass
oc apply -f 04-kata-coldplug.yaml

# 5. Test
oc apply -f 05-test-pod.yaml
oc wait --for=condition=Ready pod/kata-coldplug-test --timeout=180s
oc exec kata-coldplug-test -- cat /proc/modules | grep -i "mlx5\|ib_"
```

## Verification

After deployment, verify on a kata-oc node:

```bash
NODE=$(oc get nodes -l node-role.kubernetes.io/kata-oc -o jsonpath='{.items[0].metadata.name}')
oc debug node/$NODE -- chroot /host bash -c "
  rpm -q kata-containers                        # should be 3.31.0-3
  cat /etc/crio/crio.conf.d/50-kata-coldplug    # CRI-O handler
  cat /etc/kata-containers/config.d/50-coldplug.toml  # cold_plug_vfio
  lsinitrd /var/cache/kata-containers/osbuilder-images/kata.initrd | grep mlx5
"
```

Inside a kata-coldplug pod, the mlx5/IB modules should be loaded:

```
mlx5_core    3100672  1 mlx5_ib
mlx5_ib       557056  0
ib_core       577536  3 ib_umad,mlx5_ib,ib_uverbs
ib_uverbs     221184  1 mlx5_ib
ib_umad        49152  0
mlxfw          49152  1 mlx5_core
```

## Rebuilding the RHCOS layer image

To modify the image (different base, different patches, different OCP version):

```bash
# Edit Containerfile as needed, then:
podman build --authfile ~/Downloads/pull-secret.txt \
  --platform linux/amd64 \
  -t quay.io/jensfr/rhcos-kata-dpu:4.22-v3 \
  -f Containerfile .

podman push quay.io/jensfr/rhcos-kata-dpu:4.22-v3

# Get the new digest
skopeo inspect docker://quay.io/jensfr/rhcos-kata-dpu:4.22-v3 --no-creds | grep Digest

# Update 03-rhcos-layer.yaml with the new digest
```

The Containerfile uses a multi-stage build:
1. Stage 1 (`extensions`): RHCOS extensions image with qemu/virtiofsd RPMs
2. Stage 2 (`repo`): Fedora with createrepo_c to build a local RPM repo
3. Stage 3: RHCOS base + rpm-ostree install from the local repo + dracut config

## Files

| File | Purpose |
|------|---------|
| `Containerfile` | Multi-stage build for the RHCOS layered image |
| `01-osc-operator.yaml` | Namespace, OperatorGroup, Subscription for OSC |
| `02-kataconfig.yaml` | KataConfig CR (standard kata, no peer pods) |
| `03-rhcos-layer.yaml` | MachineConfig with osImageURL pointing to the layered image |
| `04-kata-coldplug.yaml` | CRI-O drop-in + kata config.d drop-in + RuntimeClass |
| `05-test-pod.yaml` | Test pod using kata-coldplug RuntimeClass |
| `deploy.sh` | Automated deployment script |
| `50-kata-coldplug` | CRI-O drop-in source file (baked into 04-kata-coldplug.yaml) |
| `kata-coldplug-machineconfig.yaml` | Standalone MachineConfig for kata-coldplug (alternative to 04) |
| `kata-coldplug-runtimeclass.yaml` | Standalone RuntimeClass (included in 04) |

## DPU networking workaround (after host reboot)

After a host reboot the DPU loses the IPv4 address on `br-dpu`,
breaking all pod networking. This is a known DPF bug (documented in
DPF v24.10.0 release notes). Recovery steps:

```bash
# Get the DOCA admin kubeconfig
oc get secret doca-admin-kubeconfig -n dpf-operator-system \
  -o jsonpath='{.data.super-admin\.conf}' | base64 -d > /tmp/doca-kubeconfig.yaml

# Find the DPU node name
DPU_NODE=$(KUBECONFIG=/tmp/doca-kubeconfig.yaml oc get nodes -o jsonpath='{.items[0].metadata.name}')

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

## Brew scratch build

Latest RPM: Brew scratch build task 71569544 (kata-containers-3.31.0-5)
(target: rhaos-4.23-rhel-9-candidate, required for Go 1.25.10).

Previous RPM: task 71190778 (kata-containers-3.31.0-3, without DPU config files).

## What the RPM ships (3.31.0-5+)

The z-stream RPM includes everything needed for DPU support:

- 8 patches from upstream PR #13103 (cold-plug VFIO, VF admin MAC, IB support)
- `/etc/crio/crio.conf.d/50-kata-coldplug` (CRI-O runtime handler)
- `/etc/kata-containers/config.d/50-kata-coldplug.toml` (cold_plug_vfio=root-port, pcie_root_port=2, vfio_mode=guest-kernel)
- mlx5/InfiniBand kernel modules in the kata guest initrd dracut config

Customer prerequisites (documented, not shipped):
- IOMMU enabled (`intel_iommu=on iommu=pt` via MachineConfig or BIOS)
- RuntimeClass `kata-coldplug` created (`oc apply -f kata-coldplug-runtimeclass.yaml`)
- NVIDIA DPF configured (OVN-K webhook with runtimeClassMappings, VF pool, NAD)

No OSC operator upgrade required. RPM comes via OCP z-stream.

## Upstream PR

https://github.com/kata-containers/kata-containers/pull/13103

8 cherry-picked commits by Fabiano Fidencio (ffidencio@nvidia.com) for cold-plug VFIO
guest-kernel mode with BlueField DPU and OVN-Kubernetes.
