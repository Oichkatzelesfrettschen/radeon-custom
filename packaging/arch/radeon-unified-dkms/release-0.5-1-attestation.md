# radeon-unified 0.5-1 artifact attestation

The 0.5-1 split packages are built from the pinned profiled source and
verified through the full package transition matrix, including real DKMS
module builds. This record is the release-quality identity set the
mutate-dev deployment contract requires before any target install.

## Source identity

- source: `Oichkatzelesfrettschen/linux-radeon-gororoba` commit
  `1b1f515d300f6590eb822c3e8a127e8dfc9a9abb`, tag
  `radeon-unified-0.5-profiled-source` (tag object
  `b6d737acd0a03657bfd60ce0a9ccbe5438a7102d`), verified against
  `source-identity.toml` (schema 2) at build time.
- feature policy: `policy/build-features.toml` sha256
  `8e2b957a49405b5e1689b5a5c1572c848b1e2a40e017addf9d53b4776661fecd`.
- admission gate: `check_radeon_package_profiles.py --self-test` PASS
  (including the hazard-stack literal-dependency known-bad fixture)
  immediately before `makepkg -f --cleanbuild`.

## Artifacts (2026-08-02 build, sha256)

- `radeon-unified-dkms-0.5-1-x86_64.pkg.tar.zst`
  `3ce6a5250b4496aa9a3dd7a9f372a6e120d4bd78d836f3fe8be60bfec532db53`
  (profile prod; provides `radeon-unified=0.5-1`; conflicts
  `radeon-unified-dkms-dev`).
- `radeon-unified-dkms-dev-0.5-1-x86_64.pkg.tar.zst`
  `d0828701fff50c32d5b6c1992fdbf2398ef69d2e87637c1a5d3d8853993c952c`
  (dkms.conf builds with `RADEON_BUILD_PROFILE=mutate-dev`; provides
  `radeon-unified=0.5-1`; conflicts `radeon-unified-dkms`).
- `radeon-rs482-policy-0.5-1-x86_64.pkg.tar.zst`
  `6d9a2250c9452bb2158b2ced1aacf472e835ec9f76148fcf292bbcec8df19272`
  (depends `radeon-unified=0.5-1`).

Companion packages exercised with the matrix:
`rs480-reset-hazard-stack-0.2-5-any.pkg.tar.zst` (capability dependency
`radeon-unified>=0.4`) and `sp5100-tco-ioapic-dkms-0.4-4-x86_64.pkg.tar.zst`.

## Transition matrix results

`test_radeon_package_transitions.sh` in a disposable pacstrap root, both
without and with `--with-kernel` (kernel 7.1.5-arch1-2 DKMS target):

- rows 1-8c, 10: PASS in both runs (install, prod-to-dev, profile
  selection, admission refusal, override cleanup, dev-to-prod, removal
  guard, foreign-override retention, board-policy refusal).
- row 6 kernel legs: `row6-prod-module` and `row6k-kernel-upgrade` PASS;
  the DKMS module compiles and reinstalls against the real kernel.
- row 11 `row11-hazard-stack-survival`: PASS; the hazard stack rides the
  prod-to-dev and dev-to-prod swaps through the shared `radeon-unified`
  capability.
- row 9 legacy rollback: not run (no `--legacy-package` artifact supplied;
  the 0.4-3 signed set installed on the target is the rollback authority).

Deployment beyond this record (target install, mutate-dev boot, any fire)
requires separate explicit user authorization.
