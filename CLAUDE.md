@AGENTS.md

# Claude Code Loader for radeon-custom

## Loading rule

`AGENTS.md` owns the kernel-module rules; the `@AGENTS.md` import above loads
them. The import path is spelled in that exact case: imports resolve literally,
and this filesystem is case-sensitive. This file carries Claude Code operating
notes only; shared doctrine lands in `AGENTS.md`.

When Claude Code starts inside a parent workspace, a sibling checkout, or a
temporary worktree, load `radeon-custom/AGENTS.md` before editing kernel
patches, packaging, or scripts here. These rules govern every edit under this
repository regardless of launch directory.

## Claude Code operating notes

Inspect the real repository with Claude Code tools before editing; memory,
prior summaries, and recalled context are leads, and `AGENTS.md` plus the patch
series and kernel source are authority.

Inspect the diff after every edit; the adversarial staged-diff read from
`AGENTS.md` under `Regression-on-fix discipline` runs before any commit or
completion claim.

Claude Code task tracking is transient working state; durable state lands in
patches, packaging, scripts, commit messages, documentation, or retained
bundles in `steinmarder-r300`.

Hardware-touching probes run through the gates in `AGENTS.md` under
`Hazard gates` and `Security and hardware stop-line`. A run that reaches
RS482 or Palm silicon is attended and preflighted; an agent session runs the
source-side and package-side checks.

Commit trailers use `Assisted-by:` naming the tools used, per `AGENTS.md` under
`AI disclosure, authorship, and copyright`. The harness default
`Co-Authored-By:` trailer does not apply here.

## Response shape

Responses report results, decisions, evidence, and remaining uncertainty in
mechanism-first form: changed mechanism, evidence used, validation run, checks
not run and why, risks or unresolved falsifiers. Chained reasoning appears when
it explains the next action or a validation requirement; the rest of the
deliberation lives in thoughtspace. Responses are plain ASCII mechanism prose
under durable names.
