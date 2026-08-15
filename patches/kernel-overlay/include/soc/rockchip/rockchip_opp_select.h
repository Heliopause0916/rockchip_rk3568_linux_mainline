/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Minimal stub of <soc/rockchip/rockchip_opp_select.h> for mainline 6.12.
 *
 * Mainline has no Rockchip OPP-selection support. The rknpu driver's
 * rknpu_devfreq.c uses its APIs, but that file is stubbed out under
 * CONFIG_ROCKCHIP_SYSTEM_MONITOR (not defined on mainline). The only thing
 * that survives into compiled code is the `struct rockchip_opp_info opp_info;`
 * member of struct rknpu_device (include/rknpu_drv.h), which only needs a
 * complete (dummy) type definition here.
 */
#ifndef __SOC_ROCKCHIP_OPP_SELECT_H
#define __SOC_ROCKCHIP_OPP_SELECT_H

#include <linux/types.h>

struct rockchip_opp_info {
	unsigned long dummy;
};

#endif /* __SOC_ROCKCHIP_OPP_SELECT_H */
