# RS482 needs_review attended-read DKMS candidate reader (design, for attended build)

Design for the radeon DKMS read-table extension that the attended needs_review
sweep would use. It is a design artifact, not a patch in the applied series: the
real patch is generated against the post-0037 rs400.c at attended-build time so it
applies cleanly and does not break the DKMS build. What is under review here is
the content -- which registers, which reader, which guard -- not line offsets.

## What it adds (radeon/rs400.c, modelled on 0004-rs480-candidate-regs-debugfs)

A new candidate reader for the 28 tier2 attended candidates
(rs482_needs_review_attended_read_candidates.tsv, risk_tier == tier2_candidate),
reusing the existing rs480_candidate_reg_read() choke point, so every read passes
the rs480_offset_is_read_hazard() skip guard (0024) and the
radeon_rs480_hazard_readers_armed gate.

```c
static const struct rs480_candidate_reg rs480_candidate_attended_reg_list[] = {
	{ 0x0124, "RADEON_TEST_DEBUG_MUX", 0 },
	{ 0x013c, "RADEON_SW_SEMAPHORE", 0 },
	{ 0x0158, "RADEON_MEM_SDRAM_MODE_REG", 0 },
	{ 0x017c, "R300_MC_READ_CNTL_AB", 0 },
	{ 0x0230, "RADEON_OVR_CLR", 0 },
	{ 0x0234, "RADEON_OVR_WID_LEFT_RIGHT", 0 },
	{ 0x0238, "RADEON_OVR_WID_TOP_BOTTOM", 0 },
	{ 0x0264, "RADEON_CUR_HORZ_VERT_POSN", 0 },
	{ 0x0268, "RADEON_CUR_HORZ_VERT_OFF", 0 },
	{ 0x0288, "RADEON_FP2_GEN_CNTL", 0 },
	{ 0x02a4, "RADEON_TMDS_TRANSMITTER_CNTL", 0 },
	{ 0x02a8, "RADEON_TMDS_PLL_CNTL", 0 },
	{ 0x02f0, "RADEON_GRPH_BUFFER_CNTL", 0 },
	{ 0x03f0, "RADEON_GRPH2_BUFFER_CNTL", 0 },
	{ 0x0540, "RADEON_SUBPIC_CNTL", 0 },
	{ 0x0b00, "RADEON_SURFACE_CNTL", 0 },
	{ 0x0b04, "RADEON_SURFACE0_LOWER_BOUND", 0 },
	{ 0x0b08, "RADEON_SURFACE0_UPPER_BOUND", 0 },
	{ 0x0b0c, "RADEON_SURFACE0_INFO", 0 },
	{ 0x0c40, "RADEON_VIPH_CONTROL", 0 },
	{ 0x0e38, "RS400_DMIF_MEM_CNTL1", 0 },
	{ 0x15e0, "RADEON_GUI_SCRATCH_REG0", 0 },
	{ 0x15e4, "RADEON_GUI_SCRATCH_REG1", 0 },
	{ 0x15e8, "RADEON_GUI_SCRATCH_REG2", 0 },
	{ 0x15ec, "RADEON_GUI_SCRATCH_REG3", 0 },
	{ 0x15f0, "RADEON_GUI_SCRATCH_REG4", 0 },
	{ 0x15f4, "RADEON_GUI_SCRATCH_REG5", 0 },
	{ 0x1720, "RADEON_WAIT_UNTIL", 0 },
};

static int rs480_candidate_attended_regs_show(struct seq_file *m, void *unused)
{
	return rs480_candidate_regs_emit(m, m->private,
					 rs480_candidate_attended_reg_list,
					 ARRAY_SIZE(rs480_candidate_attended_reg_list));
}

DEFINE_SHOW_ATTRIBUTE(rs480_candidate_attended_regs);

/* in the debugfs init block: */
	debugfs_create_file("radeon_rs480_candidate_attended_regs", 0444, root, rdev,
			    &rs480_candidate_attended_regs_fops);
```

## Attended build and sweep procedure

1. Generate the patch against the post-0037 source on the target; add it as
   0038-rs480-needs-review-attended-candidate-reader.patch; bump the
   radeon-unified DKMS pkgrel and update the dkms.conf sha256 in the PKGBUILD.
2. Build + install the DKMS package; reboot to load the module.
3. With kernel.panic=10 / hardlockup_panic active (CPU-lockup recovery only -- a
   deep NB stall is NOT recoverable and needs a physical cold-cycle), arm
   rs480_hazard_readers_armed=1 and read radeon_rs480_candidate_attended_regs
   once, boot_id-guarded, with a reboot-persistent synced log.
4. Each register that reads cleanly is promoted toward read_validated and, with a
   benign rationale, into the benign manifest via the build_benign_readout_manifest
   VET; each that wedges is added to the hazard policy and excluded.
5. Draw-correlate the new readable registers (the behavior axis) to keep testing
   the conjecture that kernel-level exposure does not alter GPU behavior.

## Safety scope

tier2 only (display/memory config on an always-on clock). tier3_care (BIOS, low
system) and tier3_defer (command-processor/ring, IDCT) are NOT in this reader;
IDCT clock-gates and FORCE_IDCT does not de-risk it, and CP/ring registers carry
FIFO/ring semantics. The 0x2200-0x2504 range and index/data/port names are
excluded entirely. No read in this design is known-safe -- needs_review means
unproven -- so the sweep is attended, one-shot, boot-guarded, with cold-cycle
recovery available.
