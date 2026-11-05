#!/usr/bin/env bash
# Build the bootc image and a raw disk for Apple Silicon (arm64) inside the
# existing podman machine. Rootful podman runs inside the machine via
# `podman machine ssh sudo`; the machine itself stays rootless.
#
#   REGISTRY_AUTH_FILE=/path/to/auth.json local/build-local.sh
#
# REGISTRY_AUTH_FILE must contain a registry.redhat.io credential and must live
# under /Users or /private so the machine can read it. It is never copied into
# the repository.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
AUTH=${REGISTRY_AUTH_FILE:?set REGISTRY_AUTH_FILE to a registry.redhat.io auth.json}
SSH_PUB=${SSH_PUB:-$HOME/.ssh/id_ed25519.pub}
OUT=${OUT:-$REPO/local/output}
IMAGE=localhost/rhel-image-poc:local
BIB=registry.redhat.io/rhel10/bootc-image-builder:10.2@sha256:14adeb06f5fca459c8ac534b59f1dec6d08576dfdf4605b0b27f177ad19f1de8
REV=$(git -C "$REPO" rev-parse --verify -q HEAD || echo local)
WORK=/var/tmp/rhel-image-poc   # inside the machine, off virtiofs

mkdir -p "$OUT"
# The local-only disk config adds an admin user with your SSH public key.
{
  cat "$REPO/disk/config.toml"
  printf '\n[[customizations.user]]\nname = "cloud-user"\nkey = "%s"\ngroups = ["wheel"]\n' "$(cat "$SSH_PUB")"
} > "$OUT/config.local.toml"

vm() { podman machine ssh -- "$@"; }

vm sudo podman build --platform linux/arm64 --authfile "$AUTH" \
  --build-arg SOURCE_REVISION="$REV" -t "$IMAGE" "$REPO"
vm sudo podman pull -q --authfile "$AUTH" "$BIB"
vm sudo rm -rf "$WORK"
vm sudo mkdir -p "$WORK/output"
vm sudo podman run --rm --privileged --pull=never \
  --security-opt label=type:unconfined_t \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$OUT/config.local.toml:/config.toml:ro" \
  -v "$WORK/output:/output" \
  "$BIB" --type raw --rootfs xfs "$IMAGE"
vm sudo cp --sparse=always "$WORK/output/image/disk.raw" "$OUT/disk.raw"
vm sudo rm -rf "$WORK"
echo "disk: $OUT/disk.raw"
