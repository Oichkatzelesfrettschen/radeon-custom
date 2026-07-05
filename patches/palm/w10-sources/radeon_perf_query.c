/*
 * radeon_perf_query.c -- DRM_RADEON_PERF_QUERY ioctl handler.
 *
 * Exposes the closed allowlist in perf_register_whitelist.h as a
 * read-only batch MMIO sample to unprivileged userspace through the
 * render node.  Replaces the CAP_SYS_ADMIN debugfs path provided by
 * the out-of-tree radeon_sq_debugfs module for production callers
 * (VK_KHR_performance_query, GL_AMD_performance_monitor).
 *
 * Family gate: Evergreen / TeraScale-2 (CHIP_CEDAR..CHIP_HEMLOCK) plus
 * Palm (Wrestler GPU, CHIP_PALM, Evergreen / TeraScale-2 VLIW5).  The
 * registers in the whitelist are family-stable across Evergreen and
 * Northern Islands; the family gate is conservative and may be widened
 * once Cayman/Aruba have been smoke-tested.
 *
 * Drop-in location: drivers/gpu/drm/radeon/radeon_perf_query.c plus a
 * single line in radeon_ioctls_kms[] (see radeon_drv.c.patch).
 */

#include <linux/pm_runtime.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

#include <drm/drm_device.h>
#include <drm/drm_file.h>
#include <drm/drm_ioctl.h>

#include "radeon.h"
#include "radeon_drm.h"
#include "perf_register_whitelist.h"

/*
 * Family gate.  Returns true when the running silicon implements the
 * Evergreen SQ perf-counter layout (event-select at 0x9038/0x9040, live
 * sample at 0x9050/0x9054).
 */
static bool radeon_perf_family_supported(struct radeon_device *rdev)
{
    switch (rdev->family) {
    case CHIP_CEDAR:
    case CHIP_REDWOOD:
    case CHIP_JUNIPER:
    case CHIP_CYPRESS:
    case CHIP_HEMLOCK:
    case CHIP_PALM:
    case CHIP_SUMO:
    case CHIP_SUMO2:
    case CHIP_BARTS:
    case CHIP_TURKS:
    case CHIP_CAICOS:
    case CHIP_CAYMAN:
    case CHIP_ARUBA:
        return true;
    default:
        return false;
    }
}

/*
 * Optional DPM gate: pin SCLK to the high performance level for the
 * duration of the readback batch.  Mitigates the empirical Palm finding
 * that SQ live counters read 0 under workload when DPM gates SCLK
 * between dispatches.  Reversible; the caller MUST pair every successful
 * "force" with a "restore" before returning.
 */
struct radeon_perf_dpm_guard {
    bool active;
    int prev_level;
};

static int radeon_perf_dpm_force_high(struct radeon_device *rdev,
                                      struct radeon_perf_dpm_guard *g)
{
    g->active = false;
    g->prev_level = 0;

    if (!rdev->pm.dpm_enabled)
        return 0;

    g->prev_level = rdev->pm.dpm.forced_level;

    mutex_lock(&rdev->pm.mutex);
    if (rdev->asic->dpm.force_performance_level) {
        int r = radeon_dpm_force_performance_level(rdev,
                    RADEON_DPM_FORCED_LEVEL_HIGH);
        if (r) {
            mutex_unlock(&rdev->pm.mutex);
            return r;
        }
    }
    mutex_unlock(&rdev->pm.mutex);

    g->active = true;
    return 0;
}

static void radeon_perf_dpm_restore(struct radeon_device *rdev,
                                    struct radeon_perf_dpm_guard *g)
{
    if (!g->active)
        return;

    mutex_lock(&rdev->pm.mutex);
    if (rdev->asic->dpm.force_performance_level)
        radeon_dpm_force_performance_level(rdev, g->prev_level);
    mutex_unlock(&rdev->pm.mutex);
    g->active = false;
}

/*
 * Atomic batch readback.  All MMIO accesses serialize against other
 * in-kernel radeon MMIO traffic via mmio_idx_lock (the same lock used
 * by the indirect-MMIO helpers in r100.c / evergreen.c).
 */
static int radeon_perf_read_batch(struct radeon_device *rdev,
                                  const u32 *offsets,
                                  u32 *values,
                                  u32 reg_count,
                                  u32 flags)
{
    unsigned long irqflags;
    u32 i;
    u32 saved_gfx_index = 0;
    bool restore_gfx_index = false;

    spin_lock_irqsave(&rdev->mmio_idx_lock, irqflags);

    if (flags & RADEON_PERF_QUERY_SE0_ONLY) {
        saved_gfx_index = RREG32(R_00802C_GRBM_GFX_INDEX);
        WREG32(R_00802C_GRBM_GFX_INDEX,
               S_00802C_INSTANCE_BROADCAST(1) |
               S_00802C_SH_BROADCAST(1) |
               S_00802C_SE_INDEX(0));
        restore_gfx_index = true;
    }

    for (i = 0; i < reg_count; i++)
        values[i] = RREG32(offsets[i]);

    if (restore_gfx_index)
        WREG32(R_00802C_GRBM_GFX_INDEX, saved_gfx_index);

    spin_unlock_irqrestore(&rdev->mmio_idx_lock, irqflags);
    return 0;
}

/*
 * ioctl entry point.  Bound to DRM_IOCTL_RADEON_PERF_QUERY with
 * DRM_AUTH | DRM_RENDER_ALLOW so unprivileged Vulkan/GL clients can call
 * it on the same render node they already opened.
 */
int radeon_perf_query_ioctl(struct drm_device *dev, void *data,
                            struct drm_file *filp)
{
    struct drm_radeon_perf_query *args = data;
    struct radeon_device *rdev = dev->dev_private;
    struct radeon_perf_dpm_guard dpm_guard = { 0 };
    u32 *offsets = NULL;
    u32 *values = NULL;
    size_t bytes;
    u32 i;
    int ret;

    if (!radeon_perf_family_supported(rdev))
        return -EOPNOTSUPP;

    if (args->version != 1)
        return -EINVAL;
    if (args->_pad != 0)
        return -EINVAL;
    if (args->reserved[0] != 0 || args->reserved[1] != 0)
        return -EINVAL;
    if (args->flags & ~(RADEON_PERF_QUERY_HOLD_SCLK |
                        RADEON_PERF_QUERY_SE0_ONLY))
        return -EINVAL;
    if (args->reg_count == 0 ||
        args->reg_count > RADEON_PERF_QUERY_MAX_REGS)
        return -EINVAL;

    bytes = (size_t)args->reg_count * sizeof(u32);
    offsets = kmalloc(bytes, GFP_KERNEL);
    values  = kmalloc(bytes, GFP_KERNEL);
    if (!offsets || !values) {
        ret = -ENOMEM;
        goto out_free;
    }

    if (copy_from_user(offsets, u64_to_user_ptr(args->regs_ptr), bytes)) {
        ret = -EFAULT;
        goto out_free;
    }

    for (i = 0; i < args->reg_count; i++) {
        if (!radeon_perf_reg_allowed(offsets[i])) {
            ret = -EINVAL;
            goto out_free;
        }
    }

    if (args->flags & RADEON_PERF_QUERY_HOLD_SCLK) {
        ret = pm_runtime_get_sync(dev->dev);
        if (ret < 0) {
            pm_runtime_put_autosuspend(dev->dev);
            goto out_free;
        }
        ret = radeon_perf_dpm_force_high(rdev, &dpm_guard);
        if (ret) {
            pm_runtime_put_autosuspend(dev->dev);
            goto out_free;
        }
    }

    ret = radeon_perf_read_batch(rdev, offsets, values,
                                 args->reg_count, args->flags);

    if (args->flags & RADEON_PERF_QUERY_HOLD_SCLK) {
        radeon_perf_dpm_restore(rdev, &dpm_guard);
        pm_runtime_put_autosuspend(dev->dev);
    }

    if (ret)
        goto out_free;

    if (copy_to_user(u64_to_user_ptr(args->values_ptr), values, bytes)) {
        ret = -EFAULT;
        goto out_free;
    }

    ret = 0;

out_free:
    kfree(offsets);
    kfree(values);
    return ret;
}
