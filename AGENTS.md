# radeon-custom Agent and Developer Reference

## Instruction source

`AGENTS.md` is the root instruction file for `radeon-custom` and owns the
kernel-module rules. Codex, compatible agents, and human contributors read it
directly.

`CLAUDE.md` is a tracked repository-relative symbolic link to `AGENTS.md`, so Claude Code reads this same body and the rules live in one place.

`README.md` owns repository content: the promotion ladder, the proves/does-not
table, the package layout, the scripted checks, and the cross-repository
contract. This file owns the rules and points at `README.md` for those facts.

## Contributor essentials

- Create a branch before the first edit and stage paths by name: an uncommitted edit has no owner. Every change lands through a branch and a pull request into `main`; set the branch name, first commit subject, and PR title before the first push.
- Write a commit subject as a component prefix plus the mechanism (`rs480: register GART reader after DRM root`); write the body in one to five sentences naming the invariant, the change, and the evidence. Each commit builds and bisects, with formatting apart from logic. Keep a forge-appended `(#NNN)` off subjects.
- Name branches, patch files, doc files, PR titles, commits, comments, and identifiers by mechanism and target, never by phase, wave, session, reviewer, or agent: `rs480/phase4a-fix` becomes `fix/rs480-gart-debugfs-primary-root`. Ordinal containers such as `set5` or `batch_2` and the word `tranche` stay out of names.
- Write text emoji-free in American English; meaningful symbols stay. Project-authored prose carries no em or en dash; recast the sentence with a colon, semicolon, comma, or period. `scripts/check_project_prose_style.py` also refuses a standalone ASCII `--` run in prose.
- Keep secrets, private hostnames, IP literals, per-user toolchains, and absolute local paths out of tracked files, commits, and logs; paths are repository-relative or PATH-resolved (`repo_root=$(git rev-parse --show-toplevel)`).
- Commits and PRs carry no AI attribution trailer; `Co-authored-by:` names human co-authors only. A patch sent to another project follows that project's disclosure policy, which the owner decides per submission.
- Build warning-clean, run the scripted checks under Validation expectations, and report an unrun check as `not run` with its reason. A new probe, lint, or verdict script calibrates on a known-good and a known-bad input first.
- Keep compile, install, runtime, and silicon evidence apart; the promotion ladder in `README.md` states what each licenses. Mark known, hypothesized, and speculative claims, and cite how a code symbol was found with the location.
- Comments state present-tense mechanisms with the authority by name, and carry no PR numbers, phase labels, local paths, or deictic time. A TODO names the missing mechanism, the constraint that defers it, and its tracking artifact.
- Live RS485M or Palm hardware runs are attended and preflighted and open only through the Hazard gates; an agent session runs the source-side and package-side checks.
- Merge by synthesis: keep every contribution that evidence has not refuted, and read `git diff --staged` before each commit.

## Hard rules

### Boundary and ownership

- `linux-radeon-gororoba` owns active kernel code. `radeon-custom` owns the
  signed source pin, package contents, historical patch order, dependencies,
  and safe defaults. `steinmarder-r300` owns RS485M probes,
  evidence bundles, falsifiers, and hardware verdicts. `mesa-26-gororoba` owns
  r300g/r3v userspace behavior. Every file keeps its home repository; a
  kernel fix may cite sibling evidence, and the code lands here.

### Root cause and evidence

- A behavior change names the exact chip, register, kernel function, patch, and
  module parameter first.
- PCI IDs, register sources, and measurements identify silicon; RS480 / RS482 /
  RS485M name one RS4xx-class IGP, and Palm/Wrestler names a separate hardware
  generation. Palm evidence does not validate RS485M, and RS485M evidence does not
  validate Palm.
- Root cause comes from primary sources before opinion: register document,
  kernel function, AMD ISA section, retained capture.
- GPU-behavior analysis starts from a `dmesg` check for DRM CS validation and
  lockup messages, and from `boot_id` stability to separate a driver bug from a
  hardware wedge.

### Builds, tests, and verdicts

- Touched code builds cleanly under the kernel build's warning flags and adds no
  warnings.
- A patch-series change re-runs the scripted checks named in `README.md`:
  `check_pkgbuild_sha256sums.sh`, `check_radeon_patch_series_compiles.sh`, and
  `verify_radeon_unified_dkms_sources.sh`.
- A patch added to or reordered in the series updates `dkms.conf` `PATCH[]`,
  the `PKGBUILD` `source`/`sha256sums` arrays, and the `pkgrel`.
- The patch series still applies in `dkms.conf` order after any change to it.

### Languages and scripts

- Kernel C follows the Linux kernel style of the file it patches: tabs, 8-column
  indentation, and the subsystem's existing idiom.
- Shell scripts are POSIX `sh`; a script that requires `bash` declares it, and
  `README.md` records which checks need `bash` because they source the PKGBUILD
  or use arrays.
- Python tooling targets CPython 3.12 through 3.14 inclusive.
- Shell changes pass `shellcheck`; Python changes pass the configured `ruff`
  rules.

### Hazard gates

- A hazardous path opens on the exact token its declaration names as armed, and
  the three arming domains in this series close differently. Read the
  declaration before assuming a value is inert; parameter presence alone is not
  consent.
  - Boolean gates open at exactly `1`: `radeon_rs480_r400_us_cs` and
    `rs480_hazard_readers_armed`. Zero closes these.
  - Index selectors use `-1` as the no-selection sentinel, and the guard reads
    `idx < 0 || idx >= ARRAY_SIZE(...)`. Every in-range nonnegative value
    selects an entry and performs the read, so
    `radeon_rs480_force_clock_index=0` selects the first entry and drives a
    force-clocked MMIO read. Zero arms these.
  - The reset-mask selector resolves to a mask rather than to nothing.
    `RS480_RESET_MASK_BASELINE = 0`, so `rs480_reset_mask=0` selects the
    baseline mask, named nonzero values select experimental masks, and an
    out-of-range value collapses to baseline. Zero selects here.
- `options radeon lockup_timeout=0` is the safe default and stays until an
  attended RS485M run demonstrates GPU recovery rather than host survival.
- `radeon-re.conf` is package-owned policy.
  `radeon-re-experiment-allowlist.conf` is owner-managed experiment state; an
  entry there is retained while the experiment runs, removed with its file when
  the experiment concludes, or promoted into `radeon-re.conf` under policy
  review.
- Destructive runs rely on explicit preflight, boot-persistent netconsole,
  retained manifests, and manual recovery. The SB600 watchdog is not a
  deferrable dead-man fuse for multi-second GPU wedges; retained calibration
  shows the reset event ignores `WDIOC_SETTIMEOUT`, `WDIOC_KEEPALIVE`, and
  magic close.

### Authorship, copyright, and license

- `Co-authored-by:` names human co-authors only. Historical pre-policy
  `Co-Authored-By: Claude` trailers stand in merged history.
- Kernel patches modify GPL-2.0 radeon DRM source. Upstream headers stay
  verbatim through movement and refactoring, author name and year intact, with
  no second project-collective line above them.
- A new file matches the header style of its neighbors. Kernel-side sources
  under `patches/` carry a file-purpose header comment and no copyright or SPDX
  line, as `radeon_palm_cs_observer.c` does. A standalone tool under `scripts/`
  carries `SPDX-License-Identifier: MIT` and a one-line purpose description, as
  `scripts/rs480_gui_debug_readdiff.c` does; where the license format requires
  a holder, the line reads `Copyright (c) YYYY First Principalists`.
- A fabricated personal name (`Copyright (c) YYYY <git config user.name>`) and
  an invented collective are template output and get stripped. AI disclosure
  stays out of file headers.

## Project scope and priorities

`linux-radeon-gororoba` is the active out-of-tree Radeon DRM source.
`radeon-custom` is the package and deployment authority for the RS480/RS482/RS485M
and Palm/Wrestler safety and reverse-engineering lanes.
`README.md` carries the package layout, build commands, and status table.

Priority order is fixed: host safety, containment, evidence fidelity,
recovery capability, performance. Earlier priorities override later ones.

A fast workaround is not a fix when it breaks containment. A workaround that
weakens a safety gate is a named scope cut that records its cost, containment,
and removal condition.

## Evidence rank

When sources conflict, higher rank controls.

1. Silicon evidence: retained probe output, register readback, attended
   hardware run on the target host.
2. Register and hardware documentation: AMD RS4xx/R3xx/R5xx register documents,
   Evergreen ISA for the Palm lane, SB600 and platform documentation.
3. Kernel source: mainline radeon DRM, `r300.c`, `rs400.c`, `radeon_cs.c`, the
   DRM core, and the kernel commit log.
4. This repository's patch series and package contents.
5. Retained findings and manifests in `steinmarder-r300`.
6. Documentation and comments, only when consistent with ranks 1 through 5.

Implementation-affecting claims require a rank 1 through 4 source by name.
Claims without that backing are hypotheses. A comment that conflicts with a
higher-ranked source is annotated or removed, citing that source.

## Prediction form

- If this fix is correct, this observable changes: `[state]`.
- If `[alternative condition]`, the hypothesis is falsified.

A hardware-RCA fix records the validation command or retained bundle path and
the expected host or GPU state movement before the change.

## Patch names

The patch series is the calibration set:
`rs480-parked-gpu-debugfs-readers-hard-return.patch`,
`rs480-atomic-one-shot-reset-mask-consume-cmpxchg.patch`, and
`rs480-skip-discrete-r300-mc-idle-wait-on-igp.patch` each name a target, a
mechanism, and an outcome.

## Kernel patch style

Patches expose the domain directly: chip generation, register field, MMIO
access, debugfs node, module parameter, lock scope, and error path. Names,
structs, register tables, and cleanup labels carry most of the explanation.

Follow the style of the patched file: kernel tabs, existing prefixes, existing
lock idiom. Public entry points carry the `radeon_rs480_` or `radeon_palm_`
prefix. Local helpers use mechanism verbs such as `read`, `emit`, `gate`,
`validate`, `arm`, and `park`.

Treat error paths as ownership topology. Labels such as `out`, `err_*`, `free`,
and `unlock` show which object is live, which invariant failed, and which
cleanup edge runs next. Follow kernel ABI: negative errno, `WARN`/`BUG_ON`
fences where the subsystem uses them. External input from debugfs and ioctl is
validated and rejected; assertions guard impossible internal states.

Use data tables for finite maps: safe-register lists, candidate-register lists,
force-clock cohorts, reset-mask candidates, and probe indices. Preserve
distinctions when cases differ materially; abstraction is valid only while it
preserves the chip, ABI, and evidence boundary that made the case exist.

A debugfs reader is read-only, root-only, bounded in output rows, and emits a
fixed column schema. A reader on a parked or wedged GPU hard-returns before any
register access.

Patch quality is proof density: the smallest mechanism that preserves exact
domains, visible state transitions, reviewable cleanup, and a falsifiable
consequence.

## Comments and Markdown

Use these hunks as style anchors: the page-table decode block in
`rs480-gart-page-table-readonly-debugfs.patch` around
`rs400_gart_cpu_pat_index` and `lookup_address`, and the parked-classifier
guard in `rs480-parked-gpu-debugfs-readers-hard-return.patch`.

For a silicon bug or workaround, name the affected chip or register, state the
observable failure in one sentence, and cite a public bug URL or register
document when one exists. A workaround comment separates what was observed, on
which chip and path, what the code enforces, and what remains hypothetical.
Documented behavior takes the plain indicative; reproduced-but-undocumented
behavior names the part and the path where it was observed; conjecture carries
a marker (`appears to`, `seems to`) or leaves.

A comment spends vocabulary its kernel-maintainer reader holds. A symbol grepped
from the tree defines itself (`gpu_parked`, `exclusive_lock`, `TTM_PL_VRAM`,
`dma_resv`, `RADEON_GEM_DOMAIN_GTT`), and a term of the field stays a term
(`critical section`, `buffer object`, `page table entry`, `fence`). A frame
borrowed from another field or a compression coined for this project gives way
to its mechanism: `absorbing state` becomes reset recovery has failed and the
device stays parked until reboot, `imported BO` becomes a buffer object created
for a dma-buf import, and `new object lifetime` becomes allocates a buffer
object. Those frames keep their home in findings, `README.md`, and commit
bodies, where the surrounding prose defines them; the rule governs source
comments, policy tables, and identifiers.

A compact semantic table that encodes a register layout, a bit layout, or a
state transition is content; delimiter lines, banner boxes, and ASCII art are
decoration.

Markdown in this repository uses exactly one H1, heading depth no deeper than
`###`, language tags on code fences, exact cross-references, and rule text as
direct positive-declarative statements. Tables appear only when the columns
carry independent comparison value; simple lists stay bullets.

Command flags such as `git diff --staged` and `--show-toplevel` are code and
keep their exact spelling. The dash rule governs project-authored Markdown,
comments, and commit prose; upstream text and checked-in patch bodies keep their
bytes, since the packaging sha256sums verify those exact bytes.

## Validation expectations

Minimum validation depends on the changed surface.

- Kernel patch content: `check_radeon_patch_series_compiles.sh`, plus
  `verify_radeon_unified_dkms_sources.sh` when the source tree or patch chain
  changes.
- `PKGBUILD` or patch-file content: `check_pkgbuild_sha256sums.sh`, and
  `verify_radeon_unified_dkms_package.sh` once a package artifact exists.
- Module parameters, modprobe policy, or debugfs surface:
  `check_radeon_unified_runtime_policy.sh` on a host running the unified module.
- Shell scripts: `shellcheck`, plus a known-good and a known-bad path.
- Python tooling: `ruff`, plus the script's own calibration inputs.
- Comments and docs: comment hygiene, Markdown structure, and a source-reference
  audit that verifies every symbol named against the patched source.

A test blocked by hardware safety names the required gate. A clean build or
install promotes a claim only to `compile-verified` or `installed`; promotion to
`hardware-run`, `partial`, `hardware-pass`, or `refuted` requires a retained
target-silicon bundle in `steinmarder-r300`.

## Security and hardware stop-line

Unsafe MMIO, BAR, `/dev/mem`, raw-submit, reset, or privileged debugfs access
outside the lane's explicit gate stops normal feature work: contain and report
before continuing. A register write, reset path, or firmware-injection probe
reaches hardware only through an armed gate, an attended run, and a recorded
preflight.
