/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Minimal stub of <soc/rockchip/rockchip_system_monitor.h> for mainline 6.12.
 *
 * Mainline has no Rockchip system-monitor driver. The only type that survives
 * into compiled code is the `struct monitor_dev_info *mdev_info;` pointer
 * member of struct rknpu_device (include/rknpu_drv.h); all real usage lives in
 * rknpu_devfreq.c, which is stubbed out under CONFIG_ROCKCHIP_SYSTEM_MONITOR
 * (not defined on mainline). A forward declaration is therefore sufficient.
 */
#ifndef __SOC_ROCKCHIP_SYSTEM_MONITOR_H
#define __SOC_ROCKCHIP_SYSTEM_MONITOR_H

struct monitor_dev_info;

#endif /* __SOC_ROCKCHIP_SYSTEM_MONITOR_H */
