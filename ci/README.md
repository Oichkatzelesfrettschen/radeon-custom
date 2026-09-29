# Continuous integration

`gates.yml` runs every pull-request and push job on GitHub-hosted runners, and
`target-kernel.yml` runs the post-merge qualification on the RS482 target host.

## Job placement is a security boundary

| Machine | Labels | Runs |
| --- | --- | --- |
| GitHub-hosted VM | `ubuntu-24.04` | pull-request and push jobs in `gates.yml` |
| RS482 target | `cachyos-target`, `target-host`, `rs482` | `target-kernel.yml`, on merged `main` alone |

`gates.yml` triggers on `pull_request`, so its jobs execute repository-controlled
code from an unmerged branch. Each of those jobs runs on an ephemeral hosted VM,
and the target host carries only labels that `target-kernel.yml` requests, which
is what keeps unmerged code off the one piece of hardware this project cannot
replace. Verify the property by observing a pull-request run: `target-kernel` is
absent from its job list.

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

## Target runner maintenance

API configuration success and runner availability are separate properties, and
a service that stops leaves jobs queued rather than failed, so a queue drains
into a green history once the runner returns and nothing records the gap. Run
this on the target host after every label edit, service edit, runner upgrade,
and host reboot.

```sh
# 1. The unit is enabled as well as running. An enabled unit returns after a
#    reboot; a running unit that is disabled does not.
unit=$(cat ~/actions-runner-radeon-custom/.service)
systemctl is-enabled "$unit"
systemctl is-active "$unit"

# 2. The forge agrees the runner is online, and carries the labels the
#    workflows request and none they must never match.
gh api repos/OWNER/REPO/actions/runners \
  --jq '.runners[] | "\(.name) \(.status) \([.labels[].name]|join(","))"'
```

A runner installed with `svc.sh install` and started with `svc.sh start` runs
until the next reboot and stays down after it, because `start` is not `enable`.
Step 1 is the check that catches it, and `systemctl enable --now "$unit"` is the
fix.

Queued rather than failed is the signature of a runner problem. A job that fails
inside a step is a repository problem.
