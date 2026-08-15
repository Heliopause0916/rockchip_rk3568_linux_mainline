/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Minimal stub of <soc/rockchip/rockchip_nvmem.h> for mainline 6.12.
 *
 * The Rockchip BSP wraps the mainline nvmem API through this SOC header.
 * Mainline 6.12 does not ship this header, so the rknpu driver cannot
 * compile against it as-is. The mainline equivalent is
 * nvmem_cell_read_u8(struct device *, const char *, u8 *), which takes a
 * struct device * instead of a struct device_node * as first argument,
 * hence a drop-in call is not possible.
 *
 * Only the symbol the *non-stubbed* rknpu driver actually calls is provided
 * here (see rknpu_drv.c: rknpu_get_invalid_core_mask()), which is only
 * reachable for the RK3583/RK3588 multi-core path. For the RK3568
 * non-IOMMU out-of-the-box build this is dead code, so the helper simply
 * reports "nvmem cell unavailable".
 *
 * Return value rationale (-ENODEV instead of 0): on success the caller
 * reads the value out of the nvmem cell; on failure (the mainline case)
 * it treats the read as failed, logs and falls back to the default
 * invalid-core mask (RKNPU_CORE2_MASK, i.e. core0+core1 valid). Returning
 * -ENODEV keeps that error path and leaves *val untouched, so the caller
 * retains its initialized value (0) OR'd with the default CORE2 mask, which
 * matches the hardware default. Returning 0 would silently claim a
 * successful read that never happened.
 */
#ifndef __SOC_ROCKCHIP_NVMEM_H
#define __SOC_ROCKCHIP_NVMEM_H

#include <linux/of.h>
#include <linux/errno.h>

static inline int rockchip_nvmem_cell_read_u8(struct device_node *np,
					      const char *cell, u8 *val)
{
	return -ENODEV;
}

#endif /* __SOC_ROCKCHIP_NVMEM_H */
