# RHEL 10 image mode (bootc) proof of concept for box1-org/box1-docs#46.
# The base is pinned by its multi-arch index digest, so the same file builds
# arm64 (local Mac) and amd64 (OpenShift) images. Refresh with:
#   skopeo inspect --raw docker://registry.redhat.io/rhel10/rhel-bootc:10.2 | sha256sum
FROM registry.redhat.io/rhel10/rhel-bootc:10.2@sha256:80485ddb9025df594891c36e23f865c63910739c10d37f41ae7247b0c64c2884

ARG SOURCE_REVISION=unknown

# No dnf install: RHEL repositories need entitlement, which neither the local
# podman machine nor the box1-ci build pods have yet. This image only layers
# files and systemd units onto the base.
COPY rootfs/ /

RUN printf 'BOX1_POC_REVISION=%s\n' "${SOURCE_REVISION}" > /usr/lib/box1-poc-release \
 && chmod 0755 /usr/libexec/box1-poc/hello \
 && chmod 0440 /etc/sudoers.d/90-box1-wheel && visudo -cf /etc/sudoers.d/90-box1-wheel \
 && systemctl set-default box1-poc.target \
 && bootc container lint

LABEL org.opencontainers.image.source="https://github.com/box1-org/rhel-image-poc" \
      org.opencontainers.image.revision="${SOURCE_REVISION}" \
      org.opencontainers.image.title="rhel-image-poc" \
      containers.bootc="1"
