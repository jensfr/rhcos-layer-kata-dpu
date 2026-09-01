# Deploy DPU Support with RPM Only (No RHCOS Layer)

This guide describes how to deploy Kata Containers with BlueField-3
DPU cold-plug VFIO support using only the patched RPM and two YAML
manifests. No RHCOS layer image or operator upgrade required.

## Prerequisites

- OCP 4.22 cluster with BlueField-3 DPU nodes
- OSC operator installed, KataConfig applied, kata running on nodes
- NVIDIA DPF deployed (OVN-K, device plugin, webhook)
- The patched kata-containers RPM (3.31.0-5)

## What the RPM contains

The RPM ships everything needed for DPU support:

- 8 backported patches from upstream PR #13103 (cold-plug VFIO)
- CRI-O runtime handler (`/etc/crio/crio.conf.d/50-kata-coldplug`)
- Kata config drop-in (`/etc/kata-containers/config.d/50-kata-coldplug.toml`)
- mlx5/InfiniBand kernel modules in the kata guest initrd dracut config

## Step 1: Install the RPM on DPU host nodes

On each DPU host node, replace the existing kata RPM:

```bash
NODE=<dpu-host-node-name>

# Download the RPM (requires RH VPN)
RPM_URL=https://download.devel.redhat.com/brewroot/work/tasks/6204/71706204/kata-containers-3.31.0-5.rhaos4.22.el9.x86_64.rpm

# Install via rpm-ostree override replace
oc debug node/$NODE -- chroot /host bash -c "
  curl -skL -o /tmp/kata.rpm $RPM_URL
  rpm-ostree override replace /tmp/kata.rpm
  rm /tmp/kata.rpm
"

# Reboot the node to activate
oc debug node/$NODE -- chroot /host systemctl reboot
```

Repeat for each DPU host node. Wait for each node to become Ready
before proceeding to the next.

Note: for clusters with multiple DPU nodes, consider using the RHCOS
layer approach instead (see README.md) which rolls out to all nodes
via the MachineConfigOperator.

## Step 2: Enable IOMMU

Apply a MachineConfig to enable IOMMU on DPU host nodes:

```bash
oc apply -f - <<'EOF'
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
```

Wait for nodes to reboot (~10 min per node).

Verify:
```bash
oc debug node/$NODE -- chroot /host bash -c \
  'cat /proc/cmdline | grep -o "intel_iommu=on" && ls /sys/kernel/iommu_groups/ | wc -l'
```

## Step 3: Create the RuntimeClass

```bash
oc apply -f - <<'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-coldplug
handler: kata-coldplug
overhead:
  podFixed:
    cpu: 250m
    memory: 350Mi
scheduling:
  nodeSelector:
    node-role.kubernetes.io/kata-oc: ""
EOF
```

## Step 4: Configure the NVIDIA OVN-K webhook

The OVN-K resource injector webhook needs to know that pods with
`runtimeClassName: kata-coldplug` should receive a DPU VF.

Add this flag to the webhook deployment:
```
--runtime-class-nad-mapping=kata-coldplug=<kata-nad-name>
```

The webhook automatically injects the VF resource request and the
Multus network annotation into matching pods. The NAD must have a
`k8s.v1.cni.cncf.io/resourceName` annotation pointing to the kata
VF pool (e.g. `openshift.io/bf3-p1-vfs-kata`).

This step is typically done by the DPF/NVIDIA team.

## Step 5: Deploy a workload

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: kata-dpu-test
spec:
  runtimeClassName: kata-coldplug
  containers:
  - name: test
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["sleep", "3600"]
EOF
```

No `resources.limits` needed -- the webhook injects the VF resource
automatically.

## Verification

```bash
# Pod is running with an IP from OVN
oc get pod kata-dpu-test -o wide

# 100 GbE BlueField VF inside the VM
oc exec kata-dpu-test -- cat /sys/class/net/eth0/speed

# mlx5 driver loaded in the guest VM
oc exec kata-dpu-test -- cat /proc/modules | grep mlx5

# L2 connectivity to the OVN gateway
oc exec kata-dpu-test -- cat /proc/net/arp

# QEMU has the VF cold-plugged via VFIO
oc debug node/$NODE -- chroot /host \
  ps aux '|' grep qemu-kvm '|' grep vfio-pci
```

## Brew scratch build

RPM: kata-containers-3.31.0-5.rhaos4.22.el9

| Build | Task ID | Date |
|-------|---------|------|
| Latest | [71706048](https://brewweb.engineering.redhat.com/brew/taskinfo?taskID=71706048) | 2026-09-01 |
| Previous | [71569544](https://brewweb.engineering.redhat.com/brew/taskinfo?taskID=71569544) | 2026-08-15 |

RPM spec: [gitlab.com/jfreiman/kata-containers](https://gitlab.com/jfreiman/kata-containers/-/tree/dpu-coldplug-zstream) (branch `dpu-coldplug-zstream`)

## Known issues

### DPU networking after host reboot

After a host reboot, the DPU loses its br-dpu IPv4, breaking all pod
networking. This is a known DPF bug. See the "DPU networking
workaround" section in [README.md](README.md) for recovery steps.

### Stale VF driver_override

If a kata pod fails during startup, VFs may be left with
`driver_override=vfio-pci`. See the "Stale VF cleanup" section in
[README.md](README.md).
