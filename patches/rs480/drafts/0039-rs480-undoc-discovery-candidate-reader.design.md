# RS482 interior-gap regression/L3 DKMS reader (design, attended build)

The curated interior-gap frontier was already swept: an attended at-rest read of
the 107 gaps found 104 reading 0x0 and three responders that were PCI-config
shadow (0x5058/0x505c/0x5060 = config 0x58/0x5c/0x60), so the 107-gap frontier is
exhausted of novel GPU registers (finding 2026-06-10-rs480-frontier-107-gap-sweep-
exhausted-0x5xxx-is-pci-config-shadow). After removing the PCI-config shadow
(0x5000-0x507F) and the 0x4ff8/0x4ffc pixel-pipe action-register hazards, 88
interior gaps remain, all read 0x0 at rest.

This reader is therefore NOT a novel-discovery mechanism. It is the durable
driver-guarded path for two things: a regression re-read (confirm the 88 still
read 0x0) and the L3 rung, a re-read under a clocking workload, since a
clocked-empty 0x0 at rest cannot distinguish a decoded-but-unprogrammed register
from undecoded space. The genuine novel frontier is 0x3000-0x3FFF and
0x6000-0xFFFF, a separate page-base-triage patch, not this reader.

## What it adds (radeon/rs400.c, modelled on 0004-rs480-candidate-regs-debugfs)

A reader for the 88 cleaned interior gaps, routed through the existing
rs480_candidate_reg_read() choke point so each read inherits the
rs480_offset_is_read_hazard() skip guard.

```c
static const struct rs480_candidate_reg rs480_candidate_discovery_reg_list[] = {
	{ 0x1C30, "DISCOVERY_GAP_0x1C30", 0 },
	{ 0x1C34, "DISCOVERY_GAP_0x1C34", 0 },
	{ 0x1C9C, "DISCOVERY_GAP_0x1C9C", 0 },
	{ 0x1CA0, "DISCOVERY_GAP_0x1CA0", 0 },
	{ 0x1CA4, "DISCOVERY_GAP_0x1CA4", 0 },
	{ 0x1CA8, "DISCOVERY_GAP_0x1CA8", 0 },
	{ 0x1CAC, "DISCOVERY_GAP_0x1CAC", 0 },
	{ 0x1CB0, "DISCOVERY_GAP_0x1CB0", 0 },
	{ 0x1CB4, "DISCOVERY_GAP_0x1CB4", 0 },
	{ 0x1CB8, "DISCOVERY_GAP_0x1CB8", 0 },
	{ 0x1CBC, "DISCOVERY_GAP_0x1CBC", 0 },
	{ 0x1CC0, "DISCOVERY_GAP_0x1CC0", 0 },
	{ 0x1CC4, "DISCOVERY_GAP_0x1CC4", 0 },
	{ 0x1CC8, "DISCOVERY_GAP_0x1CC8", 0 },
	{ 0x1CCC, "DISCOVERY_GAP_0x1CCC", 0 },
	{ 0x1CD8, "DISCOVERY_GAP_0x1CD8", 0 },
	{ 0x1CDC, "DISCOVERY_GAP_0x1CDC", 0 },
	{ 0x1CE0, "DISCOVERY_GAP_0x1CE0", 0 },
	{ 0x1CE4, "DISCOVERY_GAP_0x1CE4", 0 },
	{ 0x1CE8, "DISCOVERY_GAP_0x1CE8", 0 },
	{ 0x1CEC, "DISCOVERY_GAP_0x1CEC", 0 },
	{ 0x1CF0, "DISCOVERY_GAP_0x1CF0", 0 },
	{ 0x1CF4, "DISCOVERY_GAP_0x1CF4", 0 },
	{ 0x1CF8, "DISCOVERY_GAP_0x1CF8", 0 },
	{ 0x1CFC, "DISCOVERY_GAP_0x1CFC", 0 },
	{ 0x1D1C, "DISCOVERY_GAP_0x1D1C", 0 },
	{ 0x1D20, "DISCOVERY_GAP_0x1D20", 0 },
	{ 0x1D30, "DISCOVERY_GAP_0x1D30", 0 },
	{ 0x1D38, "DISCOVERY_GAP_0x1D38", 0 },
	{ 0x1D3C, "DISCOVERY_GAP_0x1D3C", 0 },
	{ 0x1D4C, "DISCOVERY_GAP_0x1D4C", 0 },
	{ 0x1D50, "DISCOVERY_GAP_0x1D50", 0 },
	{ 0x1D54, "DISCOVERY_GAP_0x1D54", 0 },
	{ 0x1D60, "DISCOVERY_GAP_0x1D60", 0 },
	{ 0x1D64, "DISCOVERY_GAP_0x1D64", 0 },
	{ 0x1D68, "DISCOVERY_GAP_0x1D68", 0 },
	{ 0x1D6C, "DISCOVERY_GAP_0x1D6C", 0 },
	{ 0x1D70, "DISCOVERY_GAP_0x1D70", 0 },
	{ 0x1D74, "DISCOVERY_GAP_0x1D74", 0 },
	{ 0x1D78, "DISCOVERY_GAP_0x1D78", 0 },
	{ 0x1D88, "DISCOVERY_GAP_0x1D88", 0 },
	{ 0x1D8C, "DISCOVERY_GAP_0x1D8C", 0 },
	{ 0x1D90, "DISCOVERY_GAP_0x1D90", 0 },
	{ 0x1D94, "DISCOVERY_GAP_0x1D94", 0 },
	{ 0x1DBC, "DISCOVERY_GAP_0x1DBC", 0 },
	{ 0x1DC0, "DISCOVERY_GAP_0x1DC0", 0 },
	{ 0x1DC4, "DISCOVERY_GAP_0x1DC4", 0 },
	{ 0x1DC8, "DISCOVERY_GAP_0x1DC8", 0 },
	{ 0x1DCC, "DISCOVERY_GAP_0x1DCC", 0 },
	{ 0x1DE4, "DISCOVERY_GAP_0x1DE4", 0 },
	{ 0x1DE8, "DISCOVERY_GAP_0x1DE8", 0 },
	{ 0x1DEC, "DISCOVERY_GAP_0x1DEC", 0 },
	{ 0x1DF0, "DISCOVERY_GAP_0x1DF0", 0 },
	{ 0x1DF4, "DISCOVERY_GAP_0x1DF4", 0 },
	{ 0x1DF8, "DISCOVERY_GAP_0x1DF8", 0 },
	{ 0x1DFC, "DISCOVERY_GAP_0x1DFC", 0 },
	{ 0x2144, "DISCOVERY_GAP_0x2144", 0 },
	{ 0x2148, "DISCOVERY_GAP_0x2148", 0 },
	{ 0x214C, "DISCOVERY_GAP_0x214C", 0 },
	{ 0x2170, "DISCOVERY_GAP_0x2170", 0 },
	{ 0x2174, "DISCOVERY_GAP_0x2174", 0 },
	{ 0x2178, "DISCOVERY_GAP_0x2178", 0 },
	{ 0x217C, "DISCOVERY_GAP_0x217C", 0 },
	{ 0x21C8, "DISCOVERY_GAP_0x21C8", 0 },
	{ 0x21CC, "DISCOVERY_GAP_0x21CC", 0 },
	{ 0x21D0, "DISCOVERY_GAP_0x21D0", 0 },
	{ 0x21D4, "DISCOVERY_GAP_0x21D4", 0 },
	{ 0x21D8, "DISCOVERY_GAP_0x21D8", 0 },
	{ 0x4240, "DISCOVERY_GAP_0x4240", 0 },
	{ 0x4244, "DISCOVERY_GAP_0x4244", 0 },
	{ 0x4248, "DISCOVERY_GAP_0x4248", 0 },
	{ 0x424C, "DISCOVERY_GAP_0x424C", 0 },
	{ 0x42D0, "DISCOVERY_GAP_0x42D0", 0 },
	{ 0x42D4, "DISCOVERY_GAP_0x42D4", 0 },
	{ 0x42D8, "DISCOVERY_GAP_0x42D8", 0 },
	{ 0x42DC, "DISCOVERY_GAP_0x42DC", 0 },
	{ 0x42E0, "DISCOVERY_GAP_0x42E0", 0 },
	{ 0x42E4, "DISCOVERY_GAP_0x42E4", 0 },
	{ 0x42E8, "DISCOVERY_GAP_0x42E8", 0 },
	{ 0x42EC, "DISCOVERY_GAP_0x42EC", 0 },
	{ 0x42F0, "DISCOVERY_GAP_0x42F0", 0 },
	{ 0x42F4, "DISCOVERY_GAP_0x42F4", 0 },
	{ 0x42F8, "DISCOVERY_GAP_0x42F8", 0 },
	{ 0x42FC, "DISCOVERY_GAP_0x42FC", 0 },
	{ 0x4F68, "DISCOVERY_GAP_0x4F68", 0 },
	{ 0x4F6C, "DISCOVERY_GAP_0x4F6C", 0 },
	{ 0x4F70, "DISCOVERY_GAP_0x4F70", 0 },
	{ 0x4F74, "DISCOVERY_GAP_0x4F74", 0 },
};

static int rs480_candidate_discovery_regs_show(struct seq_file *m, void *unused)
{
	return rs480_candidate_regs_emit(m, m->private,
					 rs480_candidate_discovery_reg_list,
					 ARRAY_SIZE(rs480_candidate_discovery_reg_list));
}

DEFINE_SHOW_ATTRIBUTE(rs480_candidate_discovery_regs);

	debugfs_create_file("radeon_rs480_candidate_discovery_regs", 0444, root, rdev,
			    &rs480_candidate_discovery_regs_fops);
```

## Procedure and scope

Finalize against post-0037 rs400.c at attended-build; the 0x4ff8/0x4ffc hazards and
the 0x5000-0x507F PCI-config shadow are excluded by the discovery generator and
hard-denied by the userspace reader, so neither can enter this list. Regression: a
re-read that returns 0x0 confirms stability; a non-zero is a regression to RCA. L3:
draw-correlate under a clocking workload. No offset here is known-safe; the sweep
is attended, boot-guarded, cold-cycle-ready (auto-reboot recovers CPU-lockups only).
