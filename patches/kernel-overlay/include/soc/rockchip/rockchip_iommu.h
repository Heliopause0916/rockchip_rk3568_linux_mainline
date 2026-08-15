/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Minimal stub of <soc/rockchip/rockchip_iommu.h> for mainline 6.12.
 *
 * The Rockchip BSP exposes helper wrappers on top of the mainline
 * rockchip-iommu driver through this SOC header. Mainline 6.12 does not
 * ship this header, so the rknpu driver cannot compile against it as-is.
 *
 * Only the symbols that the *non-stubbed* rknpu driver actually calls are
 * provided here (see rknpu_drv.c: rockchip_iommu_is_enabled used in a
 * readx_poll_timeout() on the multi-domain power-off path). For the
 * RK3568 non-IOMMU attach path the helper must report "IOMMU disabled",
 * so it returns false. rknpu_devfreq.c also names several other helpers,
 * but that file is stubbed out under CONFIG_ROCKCHIP_SYSTEM_MONITOR (not
 * defined on mainline), so those symbols are unnecessary here.
 */
#ifndef __SOC_ROCKCHIP_IOMMU_H
#define __SOC_ROCKCHIP_IOMMU_H

#include <linux/types.h>
#include <linux/device.h>

static inline bool rockchip_iommu_is_enabled(struct device *dev)
{
	return false;
}

#endif /* __SOC_ROCKCHIP_IOMMU_H */
