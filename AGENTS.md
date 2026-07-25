# radeon-custom Agent and Developer Reference

## Instruction source

`AGENTS.md` is the root instruction file for `radeon-custom` and owns the
kernel-module rules. Codex, compatible agents, and human contributors read it
directly. Other root agent files exist only to load it for tools that require a
tool-specific filename.

`CLAUDE.md` loads `@AGENTS.md`, spelled in that exact case because imports
resolve literally on a case-sensitive filesystem, and adds Claude Code loading
notes only. Doctrine lives in `AGENTS.md` alone, since copied text drifts into
conflicting instructions.

`README.md` owns repository content: the promotion ladder, the proves/does-not
table, the package layout, the scripted checks, and the cross-repository
contract. This file owns the rules and points at `README.md` for those facts.

## Hard rules

These rules are enforceable. Later sections explain mechanism and never weaken
them.

### Generating principles

Seven principles generate every rule here. A case no rule names resolves by the
nearest principle.

1. Durable mechanism identity: every durable artifact -- name, comment, claim,
   citation -- carries mechanism or content identity; chronology, actors, and
   process ride in commits, PR descriptions, and registry metadata.
2. Indicative voice: rules, comments, and reports state what an artifact is and
   does, present tense, artifact as subject. A boundary takes its positive dual:
   the restriction (`root-only read-only debugfs`), the named home (`hardware
   verdicts live in steinmarder-r300`), or the mechanism itself (`the parked
   reader hard-returns before any MMIO access`). The positive form entails the
   absence a negation would state. A hard-stop safety boundary keeps its
   prohibition, where that is the whole content.
3. Authority by name and rank: a load-bearing claim binds to a named source at
   the highest available evidence rank; provenance detail rides in the commit
   message and the finding.
4. Evidence-class separation: known, hypothesized, and speculative stay marked;
   compile-verified, installed, hardware-run, hardware-pass, and refuted stay
   distinct; prediction precedes observation, and deviation is the finding.
5. Single home per fact: each fact keeps one canonical location and other sites
   point to it.
6. Smallest complete mechanism: a patch, comment, or script carries exactly its
   distinct load-bearing facts, free of stubs, decoration, and repetition.
7. Fail-closed gates: hazardous paths open on exact opt-in values only; unset,
   empty, and zero stay closed; a verdict-producing script earns trust by
   calibration on known-good and known-bad inputs first.

### Boundary and paths

- `radeon-custom` owns kernel code, package contents, patch order,
  dependencies, and safe defaults. `steinmarder-r300` owns RS482 probes,
  evidence bundles, falsifiers, and hardware verdicts. `mesa-26-gororoba` owns
  r300g/r3v userspace behavior. Every file keeps its home repository; a
  kernel fix may cite sibling evidence, and the code lands here.
- Paths in checked-in work are repository-relative or PATH-resolved tools;
  discover the root with `repo_root=$(git rev-parse --show-toplevel)`.
- Local absolute paths, private host FQDNs, per-user toolchains, raw IP
  literals, and worktree names are workspace-local facts and live outside the
  tree.
- Checked-in text is plain ASCII.

### Root cause and evidence

- A behavior change names the exact chip, register, kernel function, patch, and
  module parameter first.
- PCI IDs, register sources, and measurements identify silicon; RS480 / RS482 /
  RS485 name one RS4xx-class IGP, and Palm/Wrestler names a separate hardware
  generation. Palm evidence does not validate RS482, and RS482 evidence does not
  validate Palm.
- Root cause comes from primary sources before opinion: register document,
  kernel function, AMD ISA section, retained capture.
- Patches, comments, and docs mark known, hypothesized, and speculative claims
  distinctly.
- A code claim carries its symbol-discovery method with the location:
  `(git grep -n SYMBOL)`, `(global -r SYMBOL)`, `(ast-grep --pattern PATTERN)`.
- A hardware-RCA fix records the observation, register or source constraint,
  implementation hypothesis, falsifier, validation command or retained bundle
  path, and expected host or GPU state movement before the change.
- GPU-behavior analysis starts from a `dmesg` check for DRM CS validation and
  lockup messages, and from `boot_id` stability to separate a driver bug from a
  hardware wedge.
- Compile, install, runtime, and silicon stay separate evidence classes. The
  promotion ladder in `README.md` is the one home for what each class licenses.

### Builds, tests, and verdicts

- Warnings and unexpected tool output are defects until explained.
- Unexpected results surface immediately.
- Touched code builds cleanly under the kernel build's warning flags and adds no
  warnings.
- The report records what was built, tested, skipped, blocked, or unavailable.
  An unrun test reads `not run` with its reason.
- A new probe, lint, or verdict-producing script earns trust by calibration
  against known-good and known-bad inputs first.
- A patch-series change re-runs the scripted checks named in `README.md`:
  `check_pkgbuild_sha256sums.sh`, `check_radeon_patch_series_compiles.sh`, and
  `verify_radeon_unified_dkms_sources.sh`.
- A patch added to or reordered in the series updates `dkms.conf` `PATCH[]`,
  the `PKGBUILD` `source`/`sha256sums` arrays, and the `pkgrel`.

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

- A hazardous path opens on an exact opt-in value. `radeon_rs480_r400_us_cs=1`,
  `rs480_hazard_readers_armed`, and the reset-mask and probe-index parameters
  are closed when unset, empty, or zero; parameter presence alone is not
  consent.
- `options radeon lockup_timeout=0` is the safe default and stays until an
  attended RS482 run demonstrates GPU recovery rather than host survival.
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

### Git, merge, and submission

- Branches, commit subjects, PR titles, source comments, and doc filenames carry
  durable mechanism names. The branch name, first commit subject, and PR title
  are set before first push. Wave, phase, mission, session, PR, reviewer, and
  agent labels live in registry metadata at most.
- Merges preserve all non-refuted content; the default resolution is union plus
  synthesis. `git merge -X theirs`, `git checkout --theirs`, blanket
  conflict-marker stripping, and unreviewed deletion are not synthesis.
- Every change lands through a branch and a pull request into `main`. A merged
  branch is deleted local and remote.
- A force-push to `main` or a shared branch carries explicit user sign-off and a
  commit message explaining why.
- Formatting churn and logic changes ride separate commits. Each commit stays
  buildable, reviewable, and bisectable.

### AI disclosure, authorship, and copyright

- The commit carries the `Assisted-by:` trailer naming the tools used, or
  `Generated-by:` when AI generated almost the entire change. The established
  form in this history is `Assisted-by: Claude (Fable 5)`, one line per tool.
- `Co-authored-by:` names human co-authors only. Historical pre-policy
  `Co-Authored-By: Claude` trailers stand; a force-push to scrub them stays out.
- Kernel patches modify GPL-2.0 radeon DRM source. Upstream headers stay
  verbatim through movement and refactoring, author name and year intact, with
  no second project-collective line above them.
- A new file matches the header style of its neighbors. Kernel-side sources
  under `patches/` carry a file-purpose header comment and no copyright or SPDX
  line, as `radeon_palm_cs_observer.c` does. A standalone tool under `scripts/`
  carries `SPDX-License-Identifier: MIT`, a real holder line, and a one-line
  purpose description, as `scripts/rs480_gui_debug_readdiff.c` does.
- A copyright line appears only when it names a real holder; absent attribution
  beats invented attribution. A fabricated personal name
  (`Copyright (c) YYYY <git config user.name>`) and an invented collective are
  LLM-template output and get stripped. AI disclosure such as `(LLM-assisted)`
  lives in commit trailers, not file headers.

### Comments, prose, and safety

- A source comment stands on its own for a kernel maintainer six months later,
  without this project's tracker. It cites no fork issue number, PR chronology,
  wave label, task number, author tag, local path, private host, or deictic
  time.
- New or modified comments, commit messages, and documentation use American
  English spelling. A behavior patch leaves upstream comment spelling alone.
- A patch changes behavior or structure with intent: no mass reformat, no stub,
  placeholder, dead code, or `TODO: finish later` prose absent tracked rationale
  and user agreement.
- A critical security defect or an unsafe hardware-access defect stops normal
  feature work; contain and report it, then resume.
- Shared workspace paths stay intact; a destructive command such as
  `sudo rm -rf` on them stays out.

## Project scope and priorities

`radeon-custom` is the single active out-of-tree Radeon DRM/DKMS source for the
RS480/RS482/RS485 and Palm/Wrestler safety and reverse-engineering lanes.
`README.md` carries the package layout, build commands, and status table.

Priority order is fixed: host safety, containment, evidence fidelity,
recovery capability, performance. Earlier priorities override later ones.

A fast workaround is not a fix when it breaks containment. A workaround that
weakens a safety gate is considered only when its cost, containment, and removal
path are recorded.

Investigate before editing. Read the patch series in `dkms.conf` order, the
kernel functions it touches, the module parameters it adds, `dmesg`, retained
sibling evidence, and commit history. Work in this order: scope the task,
identify the patch and kernel path, split claims, collect primary evidence,
model the mechanism, design the change, implement, verify, record the result.

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

## Falsification record

Before code changes for hardware RCA, record the direct observation, the source
or register constraint, the implementation hypothesis, the falsification
criterion, the validation command or retained bundle path, and the expected
host or GPU state movement.

Prediction form:

- If this fix is correct, this observable changes: `[state]`.
- If `[alternative condition]`, the hypothesis is falsified.

When a run deviates from prediction, the deviation is the finding. Open a new
RCA instead of changing the prediction after observation.

Stop implementation and report when a hypothesis survives three independent
falsification attempts, a hypothesis fails in an unexpected way, the fix
requires a non-obvious architecture choice, or a measurement contradicts a
rank-1 or rank-2 source. Report the evidence chain, alternatives, tradeoffs, and
the next evidence needed. Treat surprise as a finding; a silent pivot buries it.

## Durable names

Use names from mechanism or content, not chronology, actors, sessions, or review
process. This applies to branch names, patch filenames, doc filenames, PR
titles, commit subjects, source comments, and checked-in identifiers.

The patch series is the calibration set:
`rs480-parked-gpu-debugfs-readers-hard-return.patch`,
`rs480-atomic-one-shot-reset-mask-consume-cmpxchg.patch`, and
`rs480-skip-discrete-r300-mc-idle-wait-on-igp.patch` each name a target, a
mechanism, and an outcome.

Examples:

- Branch: avoid `rs480/phase4a-fix`; use
  `fix/rs480-gart-debugfs-primary-root`.
- Commit subject: avoid `Wave 5 follow-ups`; use
  `rs480: register GART reader after DRM root`.
- Comment: avoid `Phase 1E-atomic case`; use `parked-GPU debugfs reader path`.

The first commit subject matters because a squash merge may reuse it even when
the PR title was corrected later. Set branch name, first commit subject, and PR
title before first push.

Phase, wave, and chronology terms appear only as secondary registry metadata,
such as a `phase:` field in finding frontmatter.

`tranche` is forbidden in branches, filenames, identifiers, and comments; it is
aggregation jargon and names no content. `set`, `batch`, and `group` are
forbidden only as ordinal containers (`set5`, `batch_2`); descriptive domain
compounds such as `mask_group` and `batch_size` are allowed.

To derive a durable name: read the artifact, state in one line what it does or
contains, isolate the mechanism and object, then name those.

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

## Comments, commits, and Markdown

The code is the primary text. Comments explain mechanisms that are not obvious
from the next line of code. A useful comment records a silicon constraint, a
register rule, a kernel validation rule, a lock or lifetime invariant, a
measured quirk, or the reason a gate preserves containment.

Source comments cite public, durable authority. Task numbers, private issue
numbers, PR numbers, companion-PR breadcrumbs, phase labels, worktree names,
agent names, author tags, local absolute paths, private host FQDNs, deictic time
(`currently`, `previously`, `as of today`), and deictic chip names (`this chip
family`, `our GPU`) live in commits, PR descriptions, and findings.

Source comments name durable mechanisms: exact chip, register rule, kernel
function, module parameter, or measured behavior.

### Stating mechanism as fact

State what a thing is and does, in positive declarative form. Name the mechanism
and let the binding constraint stand as fact: `the parked classifier runs before
any MMIO access, so the reader hard-returns -EIO without touching the wedged
engine`. Correctness follows from the mechanism, so the reviewer assumes it and
contrast framing falls away.

A boundary takes its positive dual: the restriction (`root-only`), the named
home (`hardware verdicts live in steinmarder-r300`), or the mechanism itself. A
stacked absence collapses to the positive fact its members share (`CPU-only`).
An apparent negation names a mechanism, so write the mechanism: `the caller
retains the allocation`; `radeon's sync is implicit dma_resv only`. A hard-stop
safety boundary keeps its prohibition, where that is the whole content.

Write third-person present tense: `the kernel reads the GART entry`,
`rs400_gart_cpu_pat_index selects the PAT bit by page-table level`. Ceremonial
prose falls away; when terse prose hides the mechanism, the missing invariant is
the fix.

For a silicon bug or workaround, name the affected chip or register, state the
observable failure in one sentence, and cite a public bug URL or register
document when one exists. A workaround comment separates what was observed, on
which chip and path, what the code enforces, and what remains hypothetical.

### Comment shape

Use these hunks as style anchors: the page-table decode block in
`rs480-gart-page-table-readonly-debugfs.patch` around
`rs400_gart_cpu_pat_index` and `lookup_address`, and the parked-classifier
guard in `rs480-parked-gpu-debugfs-readers-hard-return.patch`.

A full mechanism comment orders its facts: the load-bearing claim, the named
authority (kernel function, register macro, register document rule), the
consequence with an inline code fragment when clearer than prose, the test or
retained-bundle reference when the comment explains a fixed failure, and the
gating parameter grouped at the end. Most comments carry one or two of those
elements; the order is a dependency order, so a comment carrying one fact is one
sentence.

Mechanism controls comment length: the number of distinct load-bearing facts
sets the length, and a line threshold does not. Every sentence carries a
distinct contract, cause, consequence, scope, or falsifier; a sentence that
paraphrases another is removed. Default to a one-line trailing comment on the
load-bearing line; use a short block for a constraint with interacting parts,
and a longer block only when each added sentence still carries a distinct fact.
Architecture that persists across a file moves to file scope; the point of use
keeps the local link in the chain. Mechanical code reads bare.

Use one thought per comment. Stack separate comments when steps are distinct.
Use active voice, and a causal connective when one fact forces another, or
sequence when the order itself is the mechanism:

```text
lookup_address returns the page-table level with the raw entry. Then
rs400_gart_cpu_pat_index picks _PAGE_PAT at PG_LEVEL_4K and _PAGE_PAT_LARGE at
PG_LEVEL_2M and PG_LEVEL_1G, so a large-page bit cannot masquerade as a
physical-address bit in the emitted row.
```

A compact semantic table that encodes a register layout, a bit layout, or a
state transition is content. Delimiter lines, banner boxes, ASCII art, and
wrappers such as `/* ----- */` and `// =====` are decoration.

### TODO comments

A deferred-work comment opens with `TODO:`, `FIXME:`, `XXX:`, or `HACK:`, and a
new marker comes from that four-item set. It names three mechanism elements: the
missing work (function, register, kernel symbol, or document chapter that needs
the change), the deferral reason (silicon, ABI, or evidence constraint blocking
completion now), and the tracking artifact (durable function name, register
name, upstream issue URL, or silicon-constraint name). When no external issue
exists, the named function or register is the tracking artifact.

A TODO body carries mechanism only. Reviewer breadcrumbs, PR-thread references,
phase labels, AGENTS.md rule citations, and deictic references live in the
commit message or PR description.

Right shape:

```text
/* TODO: rs400_debugfs_gart_page_table_show decodes each entry to a DMA
 *       address, so a non-dummy row reports backing rather than BO ownership.
 *       Closing that join needs a retained target capture from the RS482
 *       host.  Tracking: rs400_debugfs_gart_page_table_show.
 */
```

`TODO`, `FIXME`, `XXX`, `HACK`, and existing `PLACEHOLDER` comments are
evidence-bearing artifacts. Changing or removing one starts from its local
context, historical reason, and testability.

### Commits, PRs, and Markdown

Commit subjects use a component prefix and a concise mechanism:
`rs480: register GART reader after DRM root`. The body makes the invariant,
change, and evidence reviewable in one to five sentences: name the root cause or
constraint, name the fix, cite the kernel function or register when
load-bearing, and state the checks run plainly.

Build invocations, tool output, host names, and validation checklists live in
the PR description. A body that reads like a worklog with nested bullets means
the commits were not granular enough: split them or compress to the aggregate
mechanism. Commit prose is plain ASCII mechanism text with no `WHY`/`WHAT`/`HOW`
scaffolding headers.

Markdown in this repository uses exactly one H1, heading depth no deeper than
`###`, language tags on code fences, exact cross-references, and rule text as
direct positive-declarative statements. Emphasis comes from the claim, not from
typography. Tables appear only when the columns carry independent comparison
value; simple lists stay bullets. A sentence whose removal leaves the rule
unchanged is removed.

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

A pass claim rests on a run. An unrun test reads `not run` with its reason. A
test blocked by hardware safety names the required gate. A clean build or
install promotes a claim only to `compile-verified` or `installed`; promotion to
`hardware-run`, `partial`, `hardware-pass`, or `refuted` requires a retained
target-silicon bundle in `steinmarder-r300`.

## Security and hardware stop-line

A critical security defect or an unsafe hardware-access defect stops normal
feature work. Contain and report before continuing if a change exposes
credentials or private request bodies, command injection through shell wrappers
or generated scripts, path traversal or unchecked filesystem writes, sensitive
data in logs or manifests, or unsafe MMIO, BAR, `/dev/mem`, raw-submit, reset,
or privileged debugfs access outside the lane's explicit gate.

Untrusted input passes allow-lists, normalization, and containment checks before
any shell or path use; `sh -c`, `eval`, generated shell fragments, and path
concatenation take vetted values only.

A register write, reset path, or firmware-injection probe reaches hardware only
through an armed gate, an attended run, and a recorded preflight.

## Regression-on-fix discipline

A targeted fix for one issue leaves unrelated behavior intact. After changes to
patches, scripts, packaging, or comments:

- read `git diff --staged` adversarially;
- verify each removed line was intentional, duplicated elsewhere, or refuted;
- verify every symbol named in comments or docs against the patched source;
- confirm the patch series still applies in `dkms.conf` order;
- confirm `PKGBUILD` `source`, `sha256sums`, and `pkgrel` match the series;
- calibrate each new verdict-producing script on known-good and known-bad
  inputs.

When a reviewer finds a defect, fix the class, not only the instance. Add the
rule, lint, test, or documented check that would have caught it.
