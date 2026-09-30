# Continuous integration

`gates.yml` is the only workflow, and every job in it runs on a GitHub-hosted
`ubuntu-24.04` runner. No job targets a self-hosted or custom label, and the
jobs read no repository variable.

`gates.yml` triggers on `pull_request`, so its jobs execute repository-controlled
code from an unmerged branch on an ephemeral hosted VM. The RS482 machine is
outside CI: compilation against its kernel build root is an attended manual run
described under "Target kernel compile".

## Build environment

The `static`, `package`, and `compat-6-18` jobs run in the
`archlinux:base-devel` container pinned by image digest in `gates.yml`. The
first step points pacman at one dated Arch Linux Archive snapshot, the
workflow-level `ARCH_ARCHIVE_SNAPSHOT`, and installs every tool the job needs
from it, so a rerun of the same commit resolves the same package versions.
Before checkout the job installs `git`, because `actions/checkout` produces a
repository with history only when `git` exists inside the container.

The container runs as root. `makepkg` refuses root, and a compile run by an
account that cannot write the root-owned kernel build root leaves it unchanged
by construction, so each build job creates the unprivileged `builder` account
and runs `makepkg` and every module compile under it. The DKMS lifecycle and
the pacman transition matrix need root and run as root; the `package` job's
container is privileged because the transition matrix bind-mounts its
disposable root and `arch-chroot` mounts `proc`, `sys`, and `dev` inside it.

## Inputs

| Input | Source | Identity check |
| --- | --- | --- |
| Radeon source | `https://github.com/` plus `source_repository` in `packaging/arch/radeon-unified-dkms/source-identity.toml`, cloned with full history into `RUNNER_TEMP` | `scripts/check_radeon_source_pin.py`: pinned commit, trees, signed tags, and equivalence ancestry |
| upstream `drivers/gpu/drm/radeon/` | the `subtree_tree` object in the pinned source's `UPSTREAM_BASE.toml`, archived from that clone | the object ID, then `docs/upstream-radeon-v6.18-manifest.tsv` |
| 7.x kernel build root | `linux-headers`, version pinned in the `package` job | `scripts/check_packaged_kernel_build_root.sh`, then `scripts/check_shared_build_root_identity.py` before and after every compile |
| pre-7.0 kernel build root | `linux-lts-headers`, version pinned in the `compat-6-18` job | the same pair, with a `LINUX_VERSION_CODE` range below `KERNEL_VERSION(7, 0, 0)` |

`ci/kernel-build-roots/README.md` describes the kernel build-root identity
proof. A snapshot move changes `ARCH_ARCHIVE_SNAPSHOT` and both pinned header
versions and releases in one commit.

The hosted jobs read no repository variable. The variables that named
workstation paths (`RADEON_UNIFIED_SOURCE_REPOSITORY`,
`RADEON_KERNEL_BUILD_ROOT_71`, `RADEON_KERNEL_BUILD_ROOT_618`, and
`RADEON_UPSTREAM_RADEON_TREE`) have no reader in either workflow.

## Upstream history

Origin attribution runs `git log -S` and `git log -G` over
`drivers/gpu/drm/radeon`, which needs commit history and blob content. The
importer fetches `--depth 1 --filter=blob:none`, so the imported subtree serves
none of it. A separate full bare mirror of `linux.git` carries that history, and
its path is a workspace-local fact.

```sh
git clone --bare https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git \
  /opt/gororoba/upstream/linux.git
```

A bare mirror over a blobless clone, because every query is then local: a
blobless clone fetches blobs per `-S` query, and the origin map runs dozens.

## Target kernel compile

Compiling the merged production package against the RS482 target's own kernel
build root needs the physical machine (PCI `1002:5974`, subsystem `1028:022a`,
host bridge `1002:5950`), so the run is manual. It compiles and verifies; it
loads no module, arms no hazard gate, and performs no register access.
Hardware operation stays an attended run with a recorded preflight, and its
verdicts live in steinmarder-r300.

A push to `main` uploads the three split packages of one `makepkg` run and a
`SHA256SUMS` file listing them as the `radeon-unified-<sha>-<run_id>` artifact
of the `gates` run. `admit_target_gate_artifact.py` extracts the production
package alone; the development and policy packages stay in the archive for the
target install, and `sha256sum -c SHA256SUMS` checks them from the archive's
own copy. On the target, from a checkout of the same commit:

```sh
sha=$(git rev-parse HEAD)
run_id=$(gh run list --workflow gates --branch main --commit "$sha" \
  --status success --json databaseId --jq '.[0].databaseId')
name="radeon-unified-${sha}-${run_id}"
work=$(mktemp -d)
expected=$(python3 scripts/resolve_workflow_artifact_digest.py \
  --repository OWNER/REPO --run-id "$run_id" --artifact-name "$name")
gh run download "$run_id" --name "$name" --dir "$work/download"
python3 scripts/admit_target_gate_artifact.py \
  --download-directory "$work/download" --output-directory "$work/package" \
  --expected-sha256 "$expected"
for id in vendor:0x1002 device:0x5974 subsystem_vendor:0x1028 subsystem_device:0x022a; do
  [ "$(cat "/sys/bus/pci/devices/0000:01:05.0/${id%%:*}")" = "${id#*:}" ]
done
package=$(find "$work/package" -type f -name 'radeon-unified-dkms-*.pkg.tar.zst' \
  ! -name 'radeon-unified-dkms-dev-*')
sh scripts/with_build_slot.sh sh scripts/check_radeon_packaged_source_compiles.sh \
  --package "$package" --kernel-build-root "/lib/modules/$(uname -r)/build"
```

`gh run download` reads the artifact ZIP unmodified, and
`admit_target_gate_artifact.py` binds it to the API digest before extraction.
The identity loop fails closed on a machine other than the RS482 target.
