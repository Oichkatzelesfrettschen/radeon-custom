# mutate-dev boot and rollback contract for cachyos-vostro1000

This contract fixes the boot state, install sequence, and rollback authority
for running the radeon-unified 0.5-1 development module at runtime profile
`profile_dev=mutate-dev` on the RS482 target. The verified radeon state below
comes from the live target and the retained 0.5-1 acceptance bundle; the
install sequence itself executes only under separate explicit user
authorization.

## Verified target state (0.5-1 prod acceptance, bundle cachyos_vostro1000_rs482_radeon_unified_0.5-1_prod_runtime_20260803T010326Z)

- Installed: `radeon-unified-dkms 0.5-1` (prod) and `radeon-rs482-policy
  0.5-1`, loaded module srcversion `31F533E702034AA5546BF48` bonded to source
  commit `1b1f515d300f6590eb822c3e8a127e8dfc9a9abb`,
  `gororoba_build_profile=prod`, `lockup_timeout=0`, `profile_dev` and every
  fork development parameter and debugfs node absent (prod registers no
  wedge-induction surface). The signed 0.4-3 set stays the rollback authority,
  so the next dev transition is prod 0.5-1 to dev 0.5-1. The
  `sp5100-tco-ioapic-dkms` and `rs480-reset-hazard-stack` platform packages
  carry from the pre-reboot record; the passive acceptance capture did not
  re-verify their versions.
- Boot: Limine with two independent kernel entries, `linux-cachyos`
  7.1.3-2 (running) and `linux-cachyos-lts` 6.18.38-2. DKMS builds the
  radeon module for every installed kernel, so the LTS entry is a kernel
  fallback, never a module fallback: module rollback goes through pacman,
  not the bootloader. The bootloader needs no change for the experiment;
  `profile_dev` and `lockup_timeout` are modprobe.d policy
  (`mutate-dev.conf`, `radeon-re.conf`), not kernel cmdline.

## Rollback authority

The signed 0.4-3 release set is retained at
`/var/lib/radeon-unified-rollback/` (durable; relocated from the
`/var/tmp` validation staging):

- `radeon-unified-dkms-0.4-3-x86_64.pkg.tar.zst`
  `0839d7c1f2255e7d91b1b83ea9aae3667a603f4635e3b5a2509500601513ba9f`
  with detached `.sig`
  `6cc4e88f1f6f47ab2089456e6c4ce88fcecd4c00976333c3868c2f9472d61eba`.
- `radeon-rs482-policy-0.4-3-x86_64.pkg.tar.zst`
  `bdd4f4d46f13b780365dd61d3601d87c7d59ef0ef1013ab38719924ab6b0d5a1`
  with detached `.sig`
  `0ae5580430e60e50dea7c1aea47bcc5da687bb3e929c095eb20330f065c1d739`.
- `radeon-unified-0.4-3-release-attestation.toml`
  `a4c8673e40b509daa790ef82382977dfcae80e547464cc3106ee9e5e6a74770d`
  and `release-allowed-signers`
  `2fdb2ff653b87748d05c8683b691c7f135fa6575935a28655d54ce8e4bf34631`.

Rollback procedure (any time, including after a failed fire):

1. Boot either Limine entry; a wedged 7.1.3 boot falls back to the LTS
   entry.
2. `sudo pacman -U /var/lib/radeon-unified-rollback/radeon-unified-dkms-0.4-3-x86_64.pkg.tar.zst`
   (pacman replaces the dev package through the mutual conflict; the
   hazard stack at >=0.2-5 survives via the shared `radeon-unified`
   capability).
3. Reboot; verify `modinfo radeon` shows srcversion
   `414694187A1E399BBE6DA26` and `gororoba_build_profile=prod`.

## Authorized install sequence (0.5-1 mutate-dev)

Preconditions in force before step 1: the 0.5-1 artifacts match the
sha256 set in `release-0.5-1-attestation.md`, and the transition matrix
including row 11 has passed with those exact artifacts.

1. Upgrade the hazard stack to `rs480-reset-hazard-stack 0.2-5`
   (capability dependency); the installed 0.2-1 carries the literal
   `radeon-unified-dkms` dependency, and the prod-to-dev swap would
   remove it.
2. Install `radeon-unified-dkms-dev 0.5-1` (replaces prod through the
   conflict) and `radeon-rs482-policy 0.5-1`.
3. Select the runtime profile: install the `mutate-dev.conf` modprobe
   policy (`profile_dev=mutate-dev`); `radeon-re.conf` keeps
   `lockup_timeout=0`; `rs480_reset_mask` stays 0 (baseline claim).
4. Reboot into `linux-cachyos` 7.1.3-2 and verify before any hazard:
   loaded srcversion equals the installed dev package srcversion,
   `gororoba_build_profile` reports the dev profile,
   `/sys/module/radeon/parameters/rs480_reset_hang_probe` exists and is
   disarmed, `rs480_reset_mask` reads 0, `lockup_timeout` reads 0. The
   SIGBUS cell re-checks every one of these in its fail-closed admission
   and refuses (exit 82) on any mismatch.
5. The attended fire runs only with the operator physically present and
   receiver-confirmed netconsole capture; after a fired reset the box
   reboots by operator action and either stays on the dev module for a
   follow-up fire or rolls back per the procedure above.
