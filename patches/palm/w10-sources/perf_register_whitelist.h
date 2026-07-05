/*
 * perf_register_whitelist.h -- closed allowlist of Evergreen / TeraScale-2
 * performance-counter MMIO offsets the DRM_RADEON_PERF_QUERY ioctl will
 * accept.
 *
 * Each entry cites the public AMD reference where the register is
 * documented.  Internal-repo extracts are intentionally NOT cited here --
 * the surface is meant to be reviewable from the public docs alone.
 *
 * Macros (R_NNNNNN_NAME) follow the radeon in-tree convention used by
 * drivers/gpu/drm/radeon/evergreend.h and r600d.h.  Where the in-tree
 * header already defines the macro under a different name, the comment
 * notes the alias so a grep for either form finds this file.
 */

#ifndef _RADEON_PERF_REGISTER_WHITELIST_H
#define _RADEON_PERF_REGISTER_WHITELIST_H

#include <linux/types.h>

/*
 * GRBM / SRBM status block.
 *
 * Per AMD Evergreen-Family ISA, GRBM section: GRBM_STATUS reports per-block
 * busy bits.  GRBM_STATUS_SE0 / _SE1 narrow the SQ/SPI busy bits to a
 * specific shader engine.  Palm (Wrestler GPU, CHIP_PALM, Evergreen /
 * TeraScale-2 VLIW5) is single-SE, so the SE1 alias reads identically to
 * SE0 on this silicon; the slot is kept open for forward-compat with
 * Cypress (RV870) and Cayman.
 */
#define R_008010_GRBM_STATUS                    0x8010
#define R_008014_GRBM_STATUS_SE0                0x8014
#define R_008018_GRBM_STATUS_SE1                0x8018
#define R_000E50_SRBM_STATUS                    0x0E50

/*
 * SQ live performance counters.
 *
 * Per AMD Evergreen-Family ISA, ch. 12 (SQ Performance Counters):
 * PERFCOUNTER_CTRL bit0 ENABLE, bit1 FREEZE.
 * PERFCOUNTERn_SELECT bits[7:0] = event code.
 * PERFCOUNTERn_LIVE returns the instantaneous (non-accumulating) sample.
 *
 * Note: in-tree r600d.h aliases 0x9054 as SX_DEBUG_1.  On Evergreen and
 * later the same offset is the SQ live counter 1 alias; the SX_DEBUG_1
 * macro is a holdover from R600 and reads undefined on Evergreen if
 * SQ_PERFCOUNTER_CTRL has not been armed.
 */
#define R_009030_SQ_PERFCOUNTER_CTRL            0x9030
#define R_009038_SQ_PERFCOUNTER0_SELECT         0x9038
#define R_009040_SQ_PERFCOUNTER1_SELECT         0x9040
#define R_009050_SQ_PERFCOUNTER0_LIVE           0x9050
#define R_009054_SQ_PERFCOUNTER1_LIVE           0x9054

/*
 * CP busy / perfmon arm.
 *
 * Per AMD Evergreen-Family ISA, CP section: CP_BUSY_STAT enumerates which
 * CP sub-block is keeping CP_BUSY asserted (DMA, ME, PFP, CE, scratch,
 * EOP wait, etc.).  CP_STAT exposes the live FIFO levels.
 * CP_PERFMON_CNTL is the global perfmon-enable register; reading it is
 * required to confirm the ENABLE bit is set before trusting SQ live
 * counter sample values.
 */
#define R_00867C_CP_BUSY_STAT                   0x867C
#define R_008680_CP_STAT                        0x8680
#define R_0087FC_CP_PERFMON_CNTL                0x87FC

/*
 * Per-SE/SH/instance broadcast select.
 *
 * Per AMD Evergreen-Family ISA, GRBM section: GRBM_GFX_INDEX selects which
 * shader engine / shader array / instance subsequent indirect-access
 * reads target.  Required for forward-compat with multi-SE Cypress when
 * the RADEON_PERF_QUERY_SE0_ONLY flag is honored.
 */
#define R_00802C_GRBM_GFX_INDEX                 0x802C

/*
 * S_/G_ accessors for fields the ioctl ABI exposes to clients in the
 * select/control registers.  Provided for parity with the radeon
 * convention and so userspace can decode flags returned in PERFCOUNTER_CTRL
 * without rederiving the bit layout.
 */
#define S_009030_PERFCOUNTER_ENABLE(x)          (((x) & 0x1) << 0)
#define G_009030_PERFCOUNTER_ENABLE(v)          (((v) >> 0) & 0x1)
#define S_009030_PERFCOUNTER_FREEZE(x)          (((x) & 0x1) << 1)
#define G_009030_PERFCOUNTER_FREEZE(v)          (((v) >> 1) & 0x1)
#define S_009038_PERFCOUNTER_SELECT(x)          (((x) & 0xFF) << 0)
#define G_009038_PERFCOUNTER_SELECT(v)          (((v) >> 0) & 0xFF)

#define S_00802C_INSTANCE_INDEX(x)              (((x) & 0xFF) << 0)
#define S_00802C_SH_INDEX(x)                    (((x) & 0xFF) << 8)
#define S_00802C_SE_INDEX(x)                    (((x) & 0xFF) << 16)
#define S_00802C_INSTANCE_BROADCAST(x)          (((x) & 0x1) << 29)
#define S_00802C_SH_BROADCAST(x)                (((x) & 0x1) << 30)
#define S_00802C_SE_BROADCAST(x)                (((x) & 0x1) << 31)

/*
 * Allowlist table.  Lookup is linear; the table is small (12 entries)
 * and the ioctl is not hot-path.  Lookup happens once per regs_ptr
 * element so total cost is O(reg_count * 12) -- bounded by reg_count <= 64.
 */
struct radeon_perf_reg_entry {
    u32 offset;
    const char *name;
};

static const struct radeon_perf_reg_entry radeon_perf_reg_whitelist[] = {
    { R_008010_GRBM_STATUS,            "GRBM_STATUS" },
    { R_008014_GRBM_STATUS_SE0,        "GRBM_STATUS_SE0" },
    { R_008018_GRBM_STATUS_SE1,        "GRBM_STATUS_SE1" },
    { R_000E50_SRBM_STATUS,            "SRBM_STATUS" },
    { R_009030_SQ_PERFCOUNTER_CTRL,    "SQ_PERFCOUNTER_CTRL" },
    { R_009038_SQ_PERFCOUNTER0_SELECT, "SQ_PERFCOUNTER0_SELECT" },
    { R_009040_SQ_PERFCOUNTER1_SELECT, "SQ_PERFCOUNTER1_SELECT" },
    { R_009050_SQ_PERFCOUNTER0_LIVE,   "SQ_PERFCOUNTER0_LIVE" },
    { R_009054_SQ_PERFCOUNTER1_LIVE,   "SQ_PERFCOUNTER1_LIVE" },
    { R_00867C_CP_BUSY_STAT,           "CP_BUSY_STAT" },
    { R_008680_CP_STAT,                "CP_STAT" },
    { R_0087FC_CP_PERFMON_CNTL,        "CP_PERFMON_CNTL" },
    { R_00802C_GRBM_GFX_INDEX,         "GRBM_GFX_INDEX" },
};

#define RADEON_PERF_REG_WHITELIST_COUNT \
    (sizeof(radeon_perf_reg_whitelist) / sizeof(radeon_perf_reg_whitelist[0]))

#define RADEON_PERF_QUERY_MAX_REGS 64

static inline bool radeon_perf_reg_allowed(u32 offset)
{
    unsigned i;
    for (i = 0; i < RADEON_PERF_REG_WHITELIST_COUNT; i++) {
        if (radeon_perf_reg_whitelist[i].offset == offset)
            return true;
    }
    return false;
}

#endif /* _RADEON_PERF_REGISTER_WHITELIST_H */
