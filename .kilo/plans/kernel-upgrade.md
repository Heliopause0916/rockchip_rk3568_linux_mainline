# 内核整体升级专项规划

> 本文档为**内核版本整体升级**的独立系统工程专项，完全聚焦于版本迁移（Linux 6.1.106 → 维护中 LTS）。
> 本次升级是独立于其它改进项（TRNG 加固、pcat-manager 内核集成等）的一项完整系统工程技术，单独规划、单独执行、单独验收。

## 1. 背景与现状

- 本仓库路线为**主线内核 + debootstrap 自建 Debian**（不引入 Armbian）：rootfs 已由 bookworm 升级到 trixie（Debian 13）。
- 当前锁定 **Linux 6.1.106**：`build-base.sh:8` 的 `KERNEL_VERSION="linux-6.1.106"`、源码包 `archives/linux-6.1.106.tar.xz`、`kernel/Makefile` 为 VERSION=6/PATCHLEVEL=1/SUBLEVEL=106。
- **升级动因**：6.1 LTS 已近维护末期（截至 2026-08，6.1 LTS 生命周期尽头约为 2026 年底）。迁移到一个仍在维护的 LTS，以获得持续的安全与修复支持，是本次升级的核心目标。
- **定位**：升级是一项**独立系统工程**——涉及新内核基线、全部自定义补丁/overlay 的迁移与逐条核验、构建流程适配、验证与回退，与 TRNG 加固等其它专项相互独立、互不依赖。

## 2. 目标版本

- 目标版本为**当前受维护的 Linux LTS**（如 6.12.y 或更新），以 kernel.org 现行维护分支为准。
- 正式动手前需向 kernel.org 确认候选 LTS 是否仍在维护，选择仍在维护的分支；落定后把具体版本写入 `build-base.sh:8` 的 `KERNEL_VERSION`，并将对应源码 tarball 放入 `archives/`。

## 3. 构建机制与升级风险点

- 构建机制（`build-base.sh`）：
  - **kernel patches**（`:55`）：`for i in patches/kernel/*; do patch -Np1 < "$i"; done` 逐个打入。**无 `set -e`**，hunk 失败会落入 `.rej` 并被静默跳过（不报错）→ 可能烧上残缺内核。
  - **kernel-overlay**（`:56`）：`cp -rf patches/kernel-overlay/. ./` 整体覆盖主线文件（无 `.rej` 问题）。
  - **defconfig**（`:67`）：`make O=build photonicat_defconfig`，来源为 overlay 的 `arch/arm64/configs/photonicat_defconfig`。
  - **构建产物**：`O=build` 溢出构建（Image、modules、modules_install、modules_prepare、headers_install），产出 `deploy/kmods.tar.gz`、`kheaders.tar.gz`、`kbuild.tar.gz`。
- 当前 `kernel/` 下无 `.rej`/`.orig` 残留、最近一次构建干净（唯一残留系 kernel 自身 `MAINTAINERS.orig`）——但这只代表 6.1.106 基线。**升级换基线后所有 patch 必须重新逐个核验应用结果**。
- **回退保障**：保留一个已知能用的 6.1.106 完整镜像作兜底（tarball 与构建产物均不删除）；迁移在**并行分支/独立构建**上进行，不破坏现状主干。

## 4. 升级核对清单（pieces 盘点）

> 核对时**按实际文件名逐条**检查：hunk 是否干净应用、是否落入 `.rej`。凡更新主线已原生收录的板级 DTS patch，应**删除而非移植**。

### 4.1 `patches/kernel/` 共 51 个 `.patch`

按功能分组，逐条在新基线重新核验：

- **基础/板级（rk3568 系）**：`005`、`006`、`011-018`（Motorcomm yt8521/yt8531/yt8531s PHY 支持族）、`101`、`103`、`105`、`106`、`107`、`110`、`111`、`112`、`113`、`114`。
- **rk3328/rk3399 板级**：`201`、`202`、`203`、`204`、`205`、`210`、`211`。
- **rk3328 DMC/时钟族**：`803`、`804`、`805`、`806`、`807`。
- **无线/网络/CAN/杂项**：`911`、`920`、`921`、`922`、`930`、`931`、`935`、`936`。
- **板级与驱动**：`991`、`992`、`993`、`994`、`995`、`996`、`997`、`998`。
- **硬件随机数（RNG 节点）支持**：`801`（新增 `CONFIG_HW_RANDOM_ROCKCHIP` 的 Kconfig/Makefile 条目）、`802`（rk3328/rk3399/rk3568.dtsi 加 rng 节点；rk3568 节点 `rng@fe388000`、compatible=`rockchip,cryptov2-rng`，默认 disabled 由板级 overlay 置 okay，并声明 `resets = <&cru SRST_TRNG_NS>; reset-names="reset";`）。这两项为板级硬件功能支持 patch，需随新基线核验/迁移。
- **HDMI**：`440`（297/594MHz 像素时钟 + mode_valid ±0.5% 容差，18+/1-），需核验是否已被更新主线原生收录。

### 4.2 `patches/kernel-overlay/` 共 31 个文件

- **板级 DTS overlay（24 个 `arch/arm64/boot/dts/rockchip/`）**：
  - rk3568：`rk3568-photonicat.dts`、`rk3568-photonicat-ex1.dts`、`rk3568-nanopi-r5s/r5c/r66s/r68s.dts`、`rk3568-rock-3a.dts`、`rk3568-opc-h68k/h66k/h69k.dts`、`rk3568-radxa-e25.dts`、`rk3568-radxa-cm3i.dtsi`、`rk3568-mrkaio-m68s.dts(.dtsi/.plus)`、`rk3568-fastrhino.dtsi`、`rk3568-hinlink-opc.dtsi`、`rk3568-roc-pc.dts`。
  - rk3399：`rk3399-nanopi-r4se.dts`、`rk3399-mpc1903.dts`、`rk3399-king3399.dts`、`rk3399-h3399pc.dts`、`rk3399-guangmiao-g4c.dts`。
  - rk3328：`rk3328-dram-default-timing.dtsi`。
- **defconfig（1 个）**：`arch/arm64/configs/photonicat_defconfig`（6.1.106 完整生成），需基于新基线重新生成/核对。
- **完整驱动 + 配套（6 个）**：
  - `drivers/char/hw_random/rockchip-rng.c`（~310 行，仓库自制精简版）。
  - `drivers/power/supply/photonicat-pm.c`（~1716 行，仓库独有 serdev 驱动，主线无）。
  - `drivers/devfreq/rk3328_dmc.c`（~852 行，rockchip 私有，主线无）。
  - `drivers/power/supply/Makefile`（覆盖，末行 `obj-m += photonicat-pm.o`）。
  - `include/dt-bindings/clock/rockchip-ddr.h`、`include/dt-bindings/memory/rk3328-dram.h`。

> 注：`rockchip-rng.c`、`photonicat-pm.c`、`rk3328_dmc.c` 等均为仓库自制/私有驱动。升级换基线后需逐一核对在新内核 API/Kconfig/DTS 下的编译与行为（尤其 serdev、power_supply、hw_random、devfreq 等子系统的 API 变化）。

## 5. 协同与依赖项

- **rootfs 侧**：rootfs 已为 trixie；需确认新内核的模块安装产物（`deploy/kmods.tar.gz` 等）在升级后与 rootfs 的落位路径/依赖仍一致。
- **独占/自制驱动**：`photonicat-pm` 等由 overlay 内建或模块装载，升级后需重新编译并确认 auto-probe（OF-modalias / depmod）正常；详见 `.kilo/plans/pcat-manager-kernel-integration-plan.md`。
- **defconfig 差异**：新基线内核的 Kconfig 选项可能改名/新增/移除，`photonicat_defconfig` 需重新生成并核对关键硬件功能使能项随板级 patch 保持开启。

## 6. 升级执行步骤（建议）

1. 确认目标 LTS 版本仍在维护（kernel.org），落定版本号。
2. 下载目标版本源码 tarball 到 `archives/`，更新 `build-base.sh:8` 的 `KERNEL_VERSION`。
3. 在**并行分支/独立构建**上拉取新基线内核源码。
4. 逐条应用 `patches/kernel/*`（51 个），**核验无 `.rej`/`.orig` 残留**；被主线原生收录者删除。
5. 应用 `patches/kernel-overlay/`（整体覆盖），针对新基线修正 driver/DTS/defconfig 差异并逐一核验编译。
6. 重新生成/核对 `photonicat_defconfig`。
7. 完整构建出新内核镜像（`O=build`，含 modules 与模块安装产物）。
8. 烧录验证通过后再切换默认基线；保留 6.1.106 兜底（tarball 与镜像）不删除。

## 7. 验证与验收

- **构建期**：无 `.rej`/`.orig` 残留；`make O=build` 全量编译通过（Image + modules）。
- **运行时**：
  - 目标板（Photonicat v1 / RK3568）正常启动，串口/网络/存储正常；
  - `photonicat-pm` 等自定义驱动自动 probe、功能正常（看门狗喂狗、RTC、电源、温度）；
  - 板级功能回归：PHY、CAN、HDMI 4K、RNG、rfkill 等随板级 patch 提供的功能按预期工作；
  - 长时间运行观察无异常复位/崩溃。
- **回归基准**：以 6.1.106 兜底镜像为对照，逐项比对升级前后的功能行为。

## 8. 不属于本文档范围（独立专项）

- **TRNG 输出熵有效性校验等加固**：独立专项，见 `.kilo/plans/rockchip-rng-hardening.md`。两文档性质独立、分开规划与执行，互不构成前置依赖。
- **用户态 pcat-manager 内核集成（photonicat-pm）**：已闭环，见 `.kilo/plans/pcat-manager-kernel-integration-plan.md`（不改动；升级后由本文档第 5 节保证跨基线兼容）。
