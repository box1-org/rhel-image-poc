# RHEL 10 image mode (bootc) proof of concept for box1-org/box1-docs#46.
# The base is pinned by its multi-arch index digest, so the same file builds
# arm64 (local Mac) and amd64 (OpenShift) images. Refresh with:
#   skopeo inspect --raw docker://registry.redhat.io/rhel10/rhel-bootc:10.2 | sha256sum
FROM registry.redhat.io/rhel10/rhel-bootc:10.2@sha256:80485ddb9025df594891c36e23f865c63910739c10d37f41ae7247b0c64c2884

ARG SOURCE_REVISION=unknown

# Packages come from the RHEL CDN using the cluster's Simple Content Access
# entitlement, supplied only at build time as secrets (never stored in a layer):
#   --secret id=entitlement-cert,src=.../entitlement.pem
#   --secret id=entitlement-key,src=.../entitlement-key.pem
# build/repos/rhel10-cdn.repo holds the repository definitions (no credentials).
# subscription-manager is disabled for this step: in container mode it expects
# a host-provided redhat.repo.
RUN --mount=type=secret,id=entitlement-cert,target=/run/secrets/entitlement/entitlement.pem,required=true \
    --mount=type=secret,id=entitlement-key,target=/run/secrets/entitlement/entitlement-key.pem,required=true \
    --mount=type=bind,source=build/repos,target=/run/box1-repos \
    dnf -y --disableplugin=subscription-manager,product-id --setopt=reposdir=/run/box1-repos \
        --setopt=install_weak_deps=False install \
        qemu-guest-agent \
 && dnf clean all \
 && rm -rf /var/cache/dnf /var/cache/ldconfig /var/lib/dnf /var/lib/rhsm /var/log/dnf* /var/log/hawkey.log /var/log/rhsm /var/log/qemu-ga

COPY rootfs/ /

RUN rm -rf /run/secrets/entitlement /run/box1-repos /run/rhsm \
 && printf 'BOX1_POC_REVISION=%s\n' "${SOURCE_REVISION}" > /usr/lib/box1-poc-release \
 && chmod 0755 /usr/libexec/box1-poc/hello \
 && chmod 0440 /etc/sudoers.d/90-box1-wheel && visudo -cf /etc/sudoers.d/90-box1-wheel \
 && systemctl set-default box1-poc.target \
 && rpm -q qemu-guest-agent \
 && bootc container lint

LABEL org.opencontainers.image.source="https://github.com/box1-org/rhel-image-poc" \
      org.opencontainers.image.revision="${SOURCE_REVISION}" \
      org.opencontainers.image.title="rhel-image-poc" \
      containers.bootc="1"
