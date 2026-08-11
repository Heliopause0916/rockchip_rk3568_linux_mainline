# 内核整体升级专项规划（阶段三）

> 本文档为**内核版本整体升级**专项，完全聚焦于版本迁移（Linux 6.1.106 → 维护中 LTS）。
> 与 TRNG 加固是两项独立工作，TRNG 风险专项见 `.kilo/plans/rockchip-rng-hardening.md`，本文档不含 TRNG 加固细节。

## 1. 决策背景与顺序

- **升级优先于 TRNG 加固**（已定）。理由：
  - 当前锁定 **Linux 6.1.106**（`build-base.sh:8` KERNEL_VERSION、`archives/linux-6.1.106.tar.xz`），6.1 LTS 已近维护末期（按当前 2026-08 计算，6.1 LTS 生命周期尽头约 2026 年底）。
  - 先升级则大部分 TRNG 加固被主线吸收、无需在旧的 6.1 overlay 上重复投入；若先做加固再升级，会因 diff 基线变化被迫重做，且部分加固可能已并入主线而无需再做。
- 本仓库不引入 Armbian，策略为**主线内核 + debootstrap 自建 Debian**（rootfs 已 bookworm→trixie）。

## 2. 目标版本

- 目标版本为**当前受维护的 Linux LTS**（如 6.12.y 或更新，以 kernel.org 现行维护分支为准）。
- 正式动手前需向 kernel.org 确认 6.12.y 是否仍在维护或已有更新的 LTS，选择仍在维护的分支。

## 3. 构建机制与升级风险点

- 构建机制（`build-base.sh`）：
  - **kernel patches**：`for i in patches/kernel/*; do patch -Np1 ...` 逐个打入。**无 `set -e`**，hunk 失败会落入 `.rej` 并被静默跳过（不报错）→ 可能烧上残缺内核。
  - **kernel-overlay**：`cp -rf patches/kernel-overlay/. ./` 整体覆盖主线文件（无 `.rej` 问题）。
- 当前 `kernel/` 下无 `.rej`/`.orig` 残留，最近一次干净——但这只代表 6.1.106 基线。**升级换基线后所有 patch 必须重新逐个核验应用结果**。
- **回退保障**：保留一个已知能用的 6.1.106 完整镜像作兜底；迁移在**并行分支/独立构建**上进行，不破坏现状主干。

## 4. 升级核对清单（pieces 盘点）

### 4.1 `patches/kernel/` 共 51 个 `.patch`，需逐条在新基线重新核验

#### RNG 相关（2 个）
- `801-char-add-support-for-rockchip-hardware-random-number.patch`：新增 `CONFIG_HW_RANDOM_ROCKCHIP` 的 Kconfig/Makefile 条目。
- `802-arm64-dts-rockchip-add-hardware-random-number-genera.patch`：在 rk3328/rk3399/rk3568.dtsi 加 rng 节点；rk3568 节点 `rng@fe388000`，compatible=`rockchip,cryptov2-rng`，默认 disabled，由板级 overlay 置 okay；并在 rk3568 节点声明 `resets = <&cru SRST_TRNG_NS>; reset-names="reset";`。

#### HDMI（1 个）
- `440-drm-rockchip-enable-4k-hdmi-output-on-rk3568.patch`：小型稳定改动（297/594MHz 像素时钟 + mode_valid ±0.5% 容差，18+/1-），需核验是否已被更新主线原生收录。

#### 其余板级/驱动支持（48 个，按实际文件名逐条核验）
- 早期基础：`005`、`006`、`011-018`（Motorcomm yt8521/yt8531/yt8531s PHY 支持族）、`101`、`103`、`105`、`106`、`107`、`110`、`111`、`112`、`113`、`114`。
- rk3328/rk3399 板级：`201`、`202`、`203`、`204`、`205`、`210`、`211`。
- rk3328 DMC/时钟族：`803`、`804`、`805`、`806`、`807`。
- 无线/网络/杂项：`911`、`920`、`921`、`922`、`930`、`931`、`935`、`936`。
- 板级与驱动：`991`、`992`、`993`、`994`、`995`、`996`、`997`、`998`。

> 核对时**按实际文件名逐条**检查：hunk 是否干净应用、是否落入 `.rej`。凡更新主线已原生收录的板级 DTS patch，应**删除而非移植**。

### 4.2 `patches/kernel-overlay/` 共 30 个文件

#### 板级 DTS overlay（24 个 `arch/arm64/boot/dts/rockchip/`）
- rk3568：`rk3568-photonicat.dts`、`rk3568-photonicat-ex1.dts`、`rk3568-nanopi-r5s/r5c/r66s/r68s.dts`、`rk3568-rock-3a.dts`、`rk3568-opc-h68k/h66k/h69k.dts`、`rk3568-radxa-e25.dts`、`rk3568-radxa-cm3i.dtsi`、`rk3568-mrkaio-m68s.dts(.dtsi/.plus)`、`rk3568-fastrhino.dtsi`、`rk3568-hinlink-opc.dtsi`、`rk3568-roc-pc.dts`。
- rk3399：`rk3399-nanopi-r4se.dts`、`rk3399-mpc1903.dts`、`rk3399-king3399.dts`、`rk3399-h3399pc.dts`、`rk3399-guangmiao-g4c.dts`。
- rk3328：`rk3328-dram-default-timing.dtsi`。
- photonicat 两个 DTS overlay 均用 `&rng { status = "okay"; };` 启用 rng 节点（约 :496-498 与 :504-506）。

#### defconfig（1 个）
- `arch/arm64/configs/photonicat_defconfig`（6.1.106 完整生成）——需基于新基线重新生成/核对，相关条目：`CONFIG_HW_RANDOM=y`、`CONFIG_HW_RANDOM_ROCKCHIP=y`、`CONFIG_CRYPTO_DEV_ROCKCHIP=m`、`CONFIG_CRYPTO_RNG=m`。

#### 完整驱动 + 配套（5 个）
- `drivers/char/hw_random/rockchip-rng.c`（~310 行）。
- `drivers/power/supply/photonicat-pm.c`（~1716 行，仓库独有 serdev 驱动，主线无）。
- `drivers/devfreq/rk3328_dmc.c`（~852 行，rockchip 私有，主线无）。
- `drivers/power/supply/Makefile`（覆盖，末行 `obj-m += photonicat-pm.o`）。
- `include/dt-bindings/clock/rockchip-ddr.h`、`include/dt-bindings/memory/rk3328-dram.h`。

## 5. 升级执行步骤（建议）

1. 确认目标 LTS 版本仍在维护。
2. 在**并行分支/独立构建**上拉取新基线内核源码。
3. 逐条应用 `patches/kernel/*`（51 个），**核验无 `.rej`/`.orig` 残留**；被主线原生收录者删除。
4. 应用 `patches/kernel-overlay/`（整体覆盖），针对新基线修正 driver/DTS/defconfig 差异。
5. 重新生成/核对 `photonicat_defconfig`。
6. 完整构建出新内核镜像，与 6.1.106 兜底镜像并行验证。
7. 验证通过后再切换默认基线，保留 6.1.106 兜底不删除。

## 6. 不属于本文档范围

- TRNG 输出熵有效性校验等加固内容：见 `.kilo/plans/rockchip-rng-hardening.md`（执行时点排在升级之后）。
- 用户态 `pcat-manager` 内核集成文档：见 `.kilo/plans/pcat-manager-kernel-integration-plan.md`（已闭环，不改动）。
