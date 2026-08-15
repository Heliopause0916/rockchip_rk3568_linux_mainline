/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Minimal stub of <soc/rockchip/rockchip_ipa.h> for mainline 6.12.
 *
 * Mainline has no Rockchip IPA power-model support. The only type that
 * survives into compiled code is the `struct ipa_power_model_data *model_data;`
 * pointer member of struct rknpu_device (include/rknpu_drv.h); all real usage
 * lives in rknpu_devfreq.c, which is stubbed out under
 * CONFIG_ROCKCHIP_SYSTEM_MONITOR (not defined on mainline). A forward
 * declaration is therefore sufficient.
 */
#ifndef __SOC_ROCKCHIP_IPA_H
#define __SOC_ROCKCHIP_IPA_H

struct ipa_power_model_data;

#endif /* __SOC_ROCKCHIP_IPA_H */
