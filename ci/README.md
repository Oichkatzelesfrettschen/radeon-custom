# Self-hosted CI

Both repositories run on self-hosted runners because the compile verdict needs
a CachyOS kernel build tree and no hosted image carries one.

## Job placement is a security boundary

Label sets are disjoint, so a job reaches exactly the machine class it names.

| Machine | Labels | Runs |
| --- | --- | --- |
| workstation | `cachyos`, `workstation-host`, `primary-compile-host` | pull-request and push jobs in `gates.yml` |
| RS482 target | `cachyos-target`, `target-host`, `rs482` | `target-kernel.yml`, on merged `main` alone |

`gates.yml` triggers on `pull_request`, so its jobs execute repository-controlled
code from an unmerged branch. The target host carries no label those jobs
request, which is what keeps unmerged code off the one piece of hardware this
project cannot replace. Verify the property by observing a pull-request run:
`target-kernel` is absent from its job list.

## Repository variables

Each names a workspace-local path, which stays outside the tree. The value is
content-checked against a committed manifest or hash file before use, so a
variable repointed at other content fails closed rather than producing a verdict
about a tree the repository never described.

| Variable | Content | Checked against |
| --- | --- | --- |
| `RADEON_KERNEL_BUILD_ROOT_618` | retained pre-7.0 kernel build tree | `ci/kernel-build-roots/6.18.38-2-cachyos-lts.sha256` |
| `RADEON_UPSTREAM_RADEON_TREE` | pristine upstream `drivers/gpu/drm/radeon/` | the subtree object in `linux-radeon-gororoba/UPSTREAM_BASE.toml`, then `docs/upstream-radeon-v6.18-manifest.tsv` |

`RADEON_UPSTREAM_RADEON_TREE` points into a `linux-radeon-gororoba` checkout on
the workstation, so the `package` job depends on a sibling repository's working
tree. Two checks make that dependency safe, and each catches what the other
cannot. `docs/upstream-radeon-v6.18-manifest.tsv` was emitted from this path, so
comparing the path back against it detects an uncommitted edit and a repointed
variable while saying nothing about which revision is checked out. The git
subtree object is a content address for the whole directory, so it identifies
the revision. `UPSTREAM_BASE.toml` is the one home for that constant, and the
job reads it from the sibling checkout rather than keeping a second copy.

## Upstream history

Origin attribution runs `git log -S` and `git log -G` over
`drivers/gpu/drm/radeon`, which needs commit history and blob content. The
importer fetches `--depth 1 --filter=blob:none`, so the imported subtree serves
none of it. A separate full bare mirror of `linux.git` carries that history, and
its path is a workspace-local fact recorded alongside the other roots.

```sh
git clone --bare https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git \
  /opt/gororoba/upstream/linux.git
```

A bare mirror over a blobless clone, because every query is then local: a
blobless clone fetches blobs per `-S` query, and the origin map runs dozens.

## Runner maintenance

API configuration success and runner availability are separate properties, and
a service that stops leaves jobs queued rather than failed, so a queue drains
into a green history once the runner returns and nothing records the gap. Run
this after every label edit, service edit, runner upgrade, and host reboot.

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

# 3. A no-op dispatch completes rather than queueing.
gh workflow run gates.yml && gh run list --workflow=gates.yml --limit 1
```

A runner installed with `svc.sh install` and started with `svc.sh start` runs
until the next reboot and stays down after it, because `start` is not `enable`.
Step 1 is the check that catches it, and `systemctl enable --now "$unit"` is the
fix.

Queued rather than failed is the signature of a runner problem. A job that fails
inside a step is a repository problem.
