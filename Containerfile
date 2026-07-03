FROM quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:1d01c0e95b87c90432b50cbcd31c434eee9b2630953b6d92bbd67d204cee64cd AS extensions

# Build a local RPM repo in Fedora where we have createrepo_c
FROM fedora:latest AS repo
RUN dnf install -y createrepo_c
COPY --from=extensions /usr/share/rpm-ostree/extensions/qemu-kvm-core-*.rpm /tmp/rpms/
COPY --from=extensions /usr/share/rpm-ostree/extensions/qemu-kvm-common-*.rpm /tmp/rpms/
COPY --from=extensions /usr/share/rpm-ostree/extensions/qemu-img-*.rpm /tmp/rpms/
COPY --from=extensions /usr/share/rpm-ostree/extensions/virtiofsd-*.rpm /tmp/rpms/
COPY --from=extensions /usr/share/rpm-ostree/extensions/edk2-ovmf-*.rpm /tmp/rpms/
COPY --from=extensions /usr/share/rpm-ostree/extensions/seabios-bin-*.rpm /tmp/rpms/
COPY --from=extensions /usr/share/rpm-ostree/extensions/seavgabios-bin-*.rpm /tmp/rpms/
COPY --from=extensions /usr/share/rpm-ostree/extensions/ipxe-roms-qemu-*.rpm /tmp/rpms/
COPY --from=extensions /usr/share/rpm-ostree/extensions/capstone-*.rpm /tmp/rpms/
COPY --from=extensions /usr/share/rpm-ostree/extensions/libfdt-*.rpm /tmp/rpms/
COPY --from=extensions /usr/share/rpm-ostree/extensions/libpmem-*.rpm /tmp/rpms/
COPY --from=extensions /usr/share/rpm-ostree/extensions/libpng-*.rpm /tmp/rpms/
COPY --from=extensions /usr/share/rpm-ostree/extensions/lm_sensors-libs-*.rpm /tmp/rpms/
COPY --from=extensions /usr/share/rpm-ostree/extensions/ndctl-libs-*.rpm /tmp/rpms/
COPY --from=extensions /usr/share/rpm-ostree/extensions/daxctl-libs-*.rpm /tmp/rpms/
COPY --from=extensions /usr/share/rpm-ostree/extensions/pixman-*.rpm /tmp/rpms/
COPY --from=extensions /usr/share/rpm-ostree/extensions/protobuf-*.rpm /tmp/rpms/
COPY --from=extensions /usr/share/rpm-ostree/extensions/librdmacm-*.rpm /tmp/rpms/
COPY kata-containers-3.31.0-3.rhaos4.22.el9.x86_64.rpm /tmp/rpms/
RUN createrepo_c /tmp/rpms

# Final RHCOS image
FROM quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:6599ea587737de2929740f76233b300f85e9b039dbc4665c88a240a2483ee3e8

# Copy the pre-built repo and install via rpm-ostree
COPY --from=repo /tmp/rpms /tmp/rpms
RUN echo -e '[kata-local]\nname=kata-local\nbaseurl=file:///tmp/rpms\nenabled=1\ngpgcheck=0' \
      > /etc/yum.repos.d/kata-local.repo && \
    rpm-ostree install \
      kata-containers-3.31.0-3.rhaos4.22.el9 \
      qemu-kvm-core \
      virtiofsd && \
    rpm-ostree cleanup -m && \
    rm -rf /tmp/rpms /etc/yum.repos.d/kata-local.repo

# CRI-O drop-in for kata-coldplug runtime handler
COPY 50-kata-coldplug /etc/crio/crio.conf.d/50-kata-coldplug

# kata-coldplug configuration: copy base config and enable cold_plug_vfio
RUN mkdir -p /etc/kata-containers/kata-coldplug && \
    cp /etc/kata-containers/configuration.toml /etc/kata-containers/kata-coldplug/configuration.toml && \
    sed -i \
      -e 's/^hot_plug_vfio = .*/# hot_plug_vfio = "no-port"/' \
      -e 's/^cold_plug_vfio = .*/cold_plug_vfio = "root-port"/' \
      /etc/kata-containers/kata-coldplug/configuration.toml

# Add mlx5/InfiniBand kernel modules to kata guest initrd dracut config
RUN echo 'drivers+=" mlx5_core mlxfw ib_core ib_uverbs ib_umad mlx5_ib "' >> \
    /usr/libexec/kata-containers/osbuilder/dracut/dracut.conf.d/15-dracut.conf

RUN ostree container commit
