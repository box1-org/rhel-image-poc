# rhel-image-poc

Proof of concept for **RHEL 10 image mode (bootc)** virtual machines on Box1. It is the starting point for an RHDH VM golden-path template and the RHEL 10 Image Mode guest required by [box1-docs#25](https://github.com/box1-org/box1-docs/issues/25). Backlog item: [box1-docs#46](https://github.com/box1-org/box1-docs/issues/46).

The OS is a container image. Change it by committing here. A Tekton release then builds a new OS image and a VM disk.

```
Containerfile          FROM rhel10/rhel-bootc:10.2 (pinned index digest) + rootfs/ + bootc container lint
rootfs/                files layered onto the OS (systemd target/units, kargs, sudoers, motd)
disk/config.toml       bootc-image-builder settings (no credentials)
.tekton/               Pipelines-as-Code: PR build check, release build -> scan -> disk
deploy/                Namespace, DataVolume, VirtualMachine (applied manually for now)
local/                 build and boot an arm64 VM on an Apple Silicon Mac
```

## What the image does

- The default boot target is `box1-poc.target`. It requires `multi-user.target` and adds the `box1-poc-hello` service. #25's `box1-erp.target` uses the same shape.
- `box1-poc-hello` runs unprivileged (`DynamicUser`) and logs the image revision to journald every 10 minutes.
- Serial console kernel arguments are set per architecture in `/usr/lib/bootc/kargs.d`:
  - x86_64 uses `ttyS0`, for KubeVirt and `virtctl console`;
  - aarch64 uses `hvc0`, for vfkit.
- Members of `wheel` use sudo without a password. The image sets no passwords; administrators log in with SSH keys only.
- **qemu-guest-agent** is installed from the RHEL CDN. It starts through udev only when the KubeVirt guest-agent channel exists, so it stays idle under vfkit. Packages are installed with the cluster's Simple Content Access entitlement, passed as **build secrets** (`--secret id=entitlement-cert` / `entitlement-key`). The certificate is never written to an image layer. Repository definitions are in `build/repos/rhel10-cdn.repo`, which holds no credentials.

## Base image facts (rhel-bootc 10.2)

Checked on 2026-11-05 against the pinned digest.

| Package | Status |
| --- | --- |
| python3 3.12, openssh-server, sudo, podman 5.8, bootc 1.16 | present |
| cloud-init, qemu-guest-agent | **absent** (qemu-guest-agent is added by this image) |

Because cloud-init and the guest agent are missing, KubeVirt cloud-init user data and `accessCredentials` do nothing. Admin keys go in through bootc-image-builder's `[[customizations.user]]` when the disk is built. Installing packages needs the RHEL entitlement described above.

## Build and run locally (Apple Silicon)

You need a podman machine and a `registry.redhat.io` auth file stored under `/Users` or `/private`.

```sh
REGISTRY_AUTH_FILE=/path/to/auth.json ENTITLEMENT_DIR=/path/to/ent \
  local/build-local.sh                                       # arm64 image + local/output/disk.raw
local/run-local.sh                                           # boot with vfkit, serial console on this terminal
ssh cloud-user@<ip>    # IP: grep -A3 5a:94:ef:b0:c1:1 /var/db/dhcpd_leases
```

`build-local.sh` runs rootful podman inside the existing machine with `podman machine ssh sudo`. It also writes a local-only disk config that adds `cloud-user` with `~/.ssh/id_ed25519.pub`. Stop the VM with `pkill -f 'local/output/disk.raw'`, or by running `sudo poweroff` in the guest.

## Pipelines (OpenShift, namespace `box1-ci`)

| Event | PipelineRun | Service account | Result |
| --- | --- | --- | --- |
| PR to `main` | `.tekton/pull-request.yaml` | `ci-bootc-check` (privileged; no token, no push) | image builds and passes `bootc container lint` |
| Push to `main` | `.tekton/release.yaml` | `ci-bootc-release` (privileged; pushes to `box1-ci`) | `box1-ci/rhel-image-poc@<image-digest>` and `box1-ci/rhel-image-poc-disk@<disk-digest>` |

The release runs three tasks:

1. **build:** buildah builds the image with overlay storage. Privilege is required because the base has 66 layers, and vfs storage would copy the whole filesystem for each one.
2. **security:** the central `box1-security-gates` task in `observe` mode, which runs a TPA SBOM and an ACS scan.
3. **disk:** bootc-image-builder makes a qcow2, which is packaged as a KubeVirt containerDisk.

The CI identities and the PaC `Repository` live in `box1-gitops/platform/pipelines/ci/rhel-image-poc.yaml`. Two prerequisites are created outside Git:

- `box1-ci/redhat-registry-pull`: a dockerconfigjson that holds only the `registry.redhat.io` entry, copied from the cluster pull secret.
- `box1-ci/rhel-image-poc-admin-key` (optional): a ConfigMap whose key `ssh.pub` is the administrator's public key, which is baked into the disk.
- `box1-ci/etc-pki-entitlement`: a copy of `openshift-config-managed/etc-pki-entitlement` (`entitlement.pem`, `entitlement-key.pem`), mounted only into the bootc build tasks for `dnf`. The Insights operator rotates the source certificate, so refresh the copy when builds fail with CDN 403 errors:
  ```sh
  oc get secret etc-pki-entitlement -n openshift-config-managed -o json \
    | jq '{apiVersion, kind, type, data, metadata: {name: "etc-pki-entitlement", namespace: "box1-ci"}}' \
    | oc apply --server-side --field-manager=box1-rhel-image-poc -f -
  ```

## Deploy the VM (manual for the POC)

```sh
# 1. Put the release run's disk-digest into deploy/datavolume.yaml
oc apply -k deploy/
oc get dv,vm,vmi -n rhel-image-poc
virtctl console rhel-image-poc -n rhel-image-poc
virtctl ssh cloud-user@vm/rhel-image-poc -n rhel-image-poc
```

The root disk is a persistent PVC, imported once. After that, the OS changes **in place**.

## Updating the OS (bootc)

Installed VMs track the update channel `image-registry.openshift-image-registry.svc:5000/box1-ci/rhel-image-poc:main`. Each release that fully succeeds (build, security, disk) moves `:main` to the exact manifest it built, so the digests in `bootc status` match the release's `image-digest` result.

```sh
virtctl ssh -n rhel-image-poc cloud-user@vm/rhel-image-poc
sudo bootc upgrade --check     # is a newer :main available?
sudo bootc upgrade --apply     # download, stage and reboot into it
sudo bootc status              # booted / staged / rollback digests
sudo bootc rollback --apply    # reboot into the previous deployment
```

- **No unattended reboots.** `bootc-fetch-apply-updates.timer` is disabled in the image. Updates happen only when someone runs `bootc upgrade --apply`.
- **Registry access.** At boot, `box1-registry-setup.service` reads two KubeVirt disks:
  - `virtio-serviceca`: ConfigMap `openshift-service-ca.crt`, installed as `/etc/containers/certs.d/<registry>/ca.crt`.
  - `virtio-regtoken`: Secret `rhel-image-poc-updater-token`, written to `/run/ostree/auth.json` (tmpfs, 0600).

  To rotate the token, delete the Secret (the token controller recreates it), then restart the VM.
- **What persists.** `/etc` changes carry forward across upgrades (three-way merge). `/var` is never touched. `/usr` is replaced by the new image.
- **VMs installed before the update channel existed** track `localhost/rhel-image-poc:disk-build`. Move them over once with `sudo bootc switch image-registry.openshift-image-registry.svc:5000/box1-ci/rhel-image-poc:main` (run `box1-registry-setup` first if the image predates it).

To remove the POC VM: `oc delete -k deploy/`. This deletes the VM, the DataVolume/PVC and the namespace.
