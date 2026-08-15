# RK3568 NPU（RKNN）支持——实施规划

- **项目**：rockchip_rk3568_linux_mainline（Photonicat）
- **内核**：主线 6.12.103（`kernel/` 为完整源码，由 `build-base.sh` 从 kernel.org `linux-6.12.103.tar.xz` 解压）
- **目标**：为 RK3568 NPU 落地 RKNN 支持的最小可行方案（DRM GEM 模式，先跑通、再扩展）
- **原则**：与仓库现有机制一致——`patches/kernel/NNN-*.patch` 用于修改内核既有文件；`patches/kernel-overlay/` 用 `cp -rf` 覆盖式新增全新文件；rootfs 用 `mk-rootfs-debian.sh`/`mk-rootfs-ubuntu.sh`。
- **本文档状态**：实施规划（M0 素材未齐，尚未进入编译）

---

## 0. 背景与目标

本项目采用“主线内核 + 补丁 + overlay”三合一机制构建 6.12.103 内核：
- `patches/kernel/*.patch` 按 `NNN-` 前缀排序，`kernel/` 不存在时用 `patch -Np1` 逐个应用（`build-base.sh` 第 55 行）。
- `patches/kernel-overlay/` 在打补丁后 `cp -rf` 覆盖到 `kernel/`（第 56 行）。
- 编译配置：`patches/kernel-overlay/arch/arm64/configs/photonicat_defconfig`（`make photonicat_defconfig`）。
- rootfs：`rootfs/mk-rootfs-debian.sh`、`rootfs/mk-rootfs-ubuntu.sh`（debootstrap + apt）。

目标：为 RK3568 NPU 建立 RKNN（rknn-toolkit2 v2.x 世代）支持——**最小可行 = 内核驱动 `rknpu` 能在 DRM GEM 模式下载入、DT 能 probe、`librknnrt` 能 init 并跑通一个示例**。不做 devfreq/OPP、不做 SRAM/NBUF、不强制 IOMMU（先非-IOMMU 跑通）。

---

## 1. 前置调研结论（浓缩引用，均已在前两轮核验）

- **硬件**：`npu@fde40000`（0x10000）+ `GIC_SPI 151`（level-high）；电源域 `RK3568_PD_NPU=6`（VD_NPU 组）；`qos_npu: qos@fe180000`（0x20）主线已存在；NPU IOMMU 基址 `0xfde4b000`；与 GPU `0xfde60000` 相邻但独立。
- **驱动来源**：主线 6.12 无 rknpu、无 binding；Rockchip `rockchip-linux/kernel` **无 develop-6.12**，最近 BSP 分支为 `develop-6.6`（其次 `develop-6.1`）。`drivers/rknpu` 为 **GPL v2**，可随仓库分发。
- **6.12 适配点**（很小）：
  1. `struct drm_driver.gem_prime_mmap` 字段在 6.12 已移除 → 删除该赋值行；
  2. 厂商头 `soc/rockchip/rockchip_iommu.h` 主线缺失 → overlay 提供最小头文件/桩；
  3. `rknpu_devfreq.c` 依赖厂商 `CONFIG_ROCKCHIP_SYSTEM_MONITOR` → 桩化；
  4. 优先非-IOMMU 模式（DT 不挂 `iommus`）。
- **已确认在 6.12.103 主线存在**：`CLK_NPU=35`/`ACLK_NPU=40`/`HCLK_NPU=41`、`SRST_A_NPU=43`/`SRST_H_NPU=44`（`include/dt-bindings/clock/rk3568-cru.h`）；`drivers/clk/rockchip/clk-rk3568.c` 已注册 PD_NPU 时钟；`rockchip,rk3568-iommu` compatible（`drivers/iommu/rockchip-iommu.c`）；`RK3568_PD_NPU=6`（`include/dt-bindings/power/rk3568-power.h`）；DRM/prime/dma 辅助函数全部在（仅 `drm_prime_sg_to_page_array` 标 deprecated）。
- **用户态**：`librknnrt.so`（RK356X）**闭源二进制 v2.3.2**，Debian/Ubuntu 官方仓库无此包，须由用户从 `airockchip/rknpu2` 下载后由 rootfs 脚本落位。

---

## 2. 详细实施步骤

> 编号建议：现有内核补丁分区大致为 `006-018`(PHY)、`10x`(杂项)、`20x`(board)、`80x`(TRNG/cpu)、`91x-99x`(杂项)。为避免编号冲突并便于归类，本计划新补丁**统一落在 `3xx` 区段**（当前无 3xx 占用），可扩展。

### Step 1 —— 内核驱动移植（overlay 放源码，补丁挂 Kconfig/Makefile）

**做什么**：把 Rockchip `develop-6.6`（或 `develop-6.1`）的 `drivers/rknpu/` 复制进 overlay，并对三处 6.12 适配做定点修改。

**涉及文件**：
- 新增（overlay，`cp -rf` 覆盖，无同名冲突）：
  - `patches/kernel-overlay/drivers/rknpu/`（整个目录：`Kconfig`、`Makefile`、`include/`、`rknpu_drv.c`、`rknpu_gem.c`、`rknpu_iommu.c`、`rknpu_mem.c`、`rknpu_mm.c`、`rknpu_reset.c`、`rknpu_devfreq.c`、`rknpu_fence.c`、`rknpu_job.c`、`rknpu_debugger.c`）
  - `patches/kernel-overlay/include/soc/rockchip/rockchip_iommu.h`（最小桩，见下）
- 新增（补丁 hook，因为 `drivers/Kconfig`/`drivers/Makefile` 是主线巨型文件，不能整文件 overlay）：
  - `patches/kernel/3XX-rknpu-integrate.patch`

**Key：overlay 覆盖语义**——`cp -rf kernel-overlay/. kernel/` 会用 overlay 中同名文件**整体替换**内核文件。`drivers/Kconfig`/`drivers/Makefile` 数以千行，整体替换会破坏 6.12 其余内容，故**必须用补丁追加这两行 hook**；而整个新目录 `drivers/rknpu/` 与头文件 `include/soc/rockchip/` 主线不存在，放 overlay 最省事（无冲突）。

**3XX-rknpu-integrate.patch 关键内容**（示意，应用时对齐 6.12.103 上下文行）：
```diff
--- a/drivers/Kconfig
+++ b/drivers/Kconfig
@@ ... @@ source "drivers/avf/Kconfig"
 source "drivers/rtc/Kconfig"
 source "drivers/misc/Kconfig"
 source "drivers/rapidio/Kconfig"
+source "drivers/rknpu/Kconfig"
--- a/drivers/Makefile
+++ b/drivers/Makefile
@@ ... @@ obj-$(CONFIG_DRM)		+= gpu/drm/
 obj-$(CONFIG_GPU_TRACE_POINTS)	+= gpu/trace/
+obj-$(CONFIG_ROCKCHIP_RKNPU)   += rknpu/
```

**`drivers/rknpu/Makefile`（overlay 内，对齐 develop-6.6 的 Makefile；核心结构示意）**：
```make
# SPDX-License-Identifier: GPL-2.0
obj-$(CONFIG_ROCKCHIP_RKNPU) += rknpu.o
rknpu-y := \
	rknpu_drv.o rknpu_gem.o rknpu_iommu.o rknpu_mem.o \
	rknpu_mm.o rknpu_reset.o rknpu_devfreq.o rknpu_fence.o \
	rknpu_job.o rknpu_debugger.o
ccflags-y += -Idrivers/rknpu/include
```
> 以 develop-6.6 实际 Makefile 为准（若其含 `rknpu-$(CONFIG_ROCKCHIP_RKNPU_DEBUG_FS)` 之类，应一并保留）。

**6.12 适配①——删除 `.gem_prime_mmap`（rknpu_drv.c）**：
```diff
 #if KERNEL_VERSION(6, 1, 0) <= LINUX_VERSION_CODE
 	.enable_atomic_workarounds	= ...,
 	.gem_prime_mmap = drm_gem_prime_mmap,   /* 6.12 字段已移除 → 删除此行 */
 #else
 	...
 #endif
```
若希望代码更语义化，可在原有 `#if KERNEL_VERSION(6,1,0) <= ...` 之上再按 6.12 分支：`#if KERNEL_VERSION(6,12,0) > LINUX_VERSION_CODE` 才赋 `.gem_prime_mmap`，否则不赋（PRIME 用户 mmap 走 `DEFINE_DRM_GEM_FOPS` 的 `.mmap = drm_gem_mmap` 默认路径）。**推荐直接删除该行**（最小改动）。

**6.12 适配②——`rockchip_iommu.h` 最小桩（overlay 新增文件）**：
驱动在 `rknpu_drv.c`/`rknpu_iommu.c` 中 `#include <soc/rockchip/rockchip_iommu.h>`，并引用厂商符号。对 RK3568（单核、单电源域、`multiple_domains=false`、非-IOMMU 优先），这些符号运行路径多用不到，但需头文件过编译。给出最小头文件（原型与空实现；以能过编译为度，注明需在移植时按实际引用核对）：
```c
/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __SOC_ROCKCHIP_ROCKCHIP_IOMMU_H
#define __SOC_ROCKCHIP_ROCKCHIP_IOMMU_H
#include <linux/types.h>
#include <linux/io-pgtable.h>
/* 按 develop-6.6 中被引用的符号清单补齐原型；以下为常见最小集 */
int rockchip_iommu_is_enabled(struct device *dev);
int rockchip_iommu_domain_get_and_switch(struct device *dev, int id);
void rockchip_iommu_domain_put(struct device *dev);
struct iommu_domain *rockchip_iommu_get_domain(struct device *dev);
#endif
```
> 说明：此桩只用于“过编译”。若最终启用 IOMMU 模式，需为 `rockchip_iommu_domain_*` 提供真正可用实现（绕过主流 IOMMU 域架构），这属于“再扩展”阶段，本 M1 不强制。**首发内置定非-IOMMU 姿态**，则这些函数可以是 `-EOPNOTSUPP`/空实现。

**6.12 适配③——`rknpu_devfreq.c` 桩化**：
厂商 `rknpu_devfreq` 依赖 `rockchip_system_monitor`（主线无）。在 `rknpu_drv.c` 中把以下调用改为 no-op 桩（或以 `#ifndef CONFIG_ROCKCHIP_SYSTEM_MONITOR` 关闭）：
- `rknpu_devfreq_init(rknpu_dev)` → 返回 0（或空）
- `rknpu_devfreq_remove(rknpu_dev)` → 空
- `rknpu_devfreq_lock` / `rknpu_devfreq_unlock` → 空
- `rknpu_devfreq_runtime_suspend/resume` → `pm_runtime_force_suspend/resume` 或返回 0
> 以最小改动为目标：在 overlay 的 `rknpu_devfreq.c` 顶层加 `#if CONFIG 保护` 或提供最简 `rknpu_devfreq.c` 替身（仅 `#include` + 空函数）。首发不需要 OPP 电压调节（project photonicat 无 `vdd_npu` regulator，驱动 `devm_regulator_get_optional("rknpu")` 容忍缺失）。

**验证方法（M1）**：`cd kernel && make O=build photonicat_defconfig && make O=build M=drivers/rknpu` 之类编译驱动模块，确认 `rknpu.ko` 生成、无未解析符号；`modprobe rknpu`（对板）后 `dmesg` 无 probe 报错。

---

### Step 2 —— 设备树（补丁改 rk356x.dtsi + photonicat overlay 启用）

**做什么**：在 6.12.103 的 `rk356x.dtsi` 增加 ①`RK3568_PD_NPU` 电源域、②`npu@fde40000`、③`rknpu_mmu`（首发不挂 `iommus`）；在 photonicat.dts 用 `&rknpu { status="okay"; }` 启用。

**涉及文件**：
- 新增补丁 `patches/kernel/3XX-arm64-dts-rockchip-rk3568-add-npu.patch`（针对 `kernel/arch/arm64/boot/dts/rockchip/rk356x.dtsi`）。
- 修改 overlay：`patches/kernel-overlay/arch/arm64/boot/dts/rockchip/rk3568-photonicat.dts`（追加 `&rknpu`）。

**补丁 3XX-arm64-dts-rockchip-rk3568-add-npu.patch 内容**（hunk 按 6.12.103 上下文，落地时用 `patch -Np1` 校验）：
```diff
--- a/arch/arm64/boot/dts/rockchip/rk356x.dtsi
+++ b/arch/arm64/boot/dts/rockchip/rk356x.dtsi
@@ -/* power-controller 内，PD_RKVDEC/RKVENC 附近插入 */ @@
+			/* These power domains are grouped by VD_NPU */
+			power-domain@RK3568_PD_NPU {
+				reg = <RK3568_PD_NPU>;
+				clocks = <&cru ACLK_NPU_PRE>,
+					 <&cru HCLK_NPU_PRE>,
+					 <&cru PCLK_NPU_PRE>;
+				pm_qos = <&qos_npu>;
+			};
@@ -/* 在 gpu@fde60000 之前插入 NPU 及其 IOMMU */ @@
+	rknpu: npu@fde40000 {
+		compatible = "rockchip,rk3568-rknpu", "rockchip,rknpu";
+		reg = <0x0 0xfde40000 0x0 0x10000>;
+		interrupts = <GIC_SPI 151 IRQ_TYPE_LEVEL_HIGH>;
+		clocks = <&cru CLK_NPU>, <&cru ACLK_NPU>, <&cru HCLK_NPU>;
+		clock-names = "clk", "aclk", "hclk";
+		assigned-clocks = <&cru CLK_NPU>;
+		assigned-clock-rates = <600000000>;
+		resets = <&cru SRST_A_NPU>, <&cru SRST_H_NPU>;
+		reset-names = "srst_a", "srst_h";
+		power-domains = <&power RK3568_PD_NPU>;
+		status = "disabled";
+	};
+
+	rknpu_mmu: iommu@fde4b000 {
+		compatible = "rockchip,rk3568-iommu";
+		reg = <0x0 0xfde4b000 0x0 0x40>;
+		interrupts = <GIC_SPI 151 IRQ_TYPE_LEVEL_HIGH>;
+		clocks = <&cru ACLK_NPU>, <&cru HCLK_NPU>;
+		clock-names = "aclk", "iface";
+		power-domains = <&power RK3568_PD_NPU>;
+		#iommu-cells = <0>;
+		status = "disabled";
+	};
```

**photonicat.dts overlay 追加**（与现有 `&gpu` 一致）：
```dts
&rknpu {
	status = "okay";
};

/* 首发非-IOMMU：不要挂 rknpu_mmu 到 rknpu->iommus 即可；
 * 若日后启用 IOMMU，把 rknpu 的 iommus=<&rknpu_mmu> 加上并使能：
&rknpu_mmu {
	status = "okay";
};
 */
```

**验证**：`make O=build rockchip/rk3568-photonicat.dtb` 应无 dtc 报错；`fdtdump`/`dtc -I dtb` 确认 `npu@fde40000` 与 `RK3568_PD_NPU` 电源域存在。

---

### Step 3 —— defconfig

**做什么**：在 `photonicat_defconfig` 追加 `CONFIG_ROCKCHIP_RKNPU=m`（及可选子项）。

**依赖满足（已核验）**：`CONFIG_CMA=y`、`CONFIG_DRM=y`、`CONFIG_DRM_ROCKCHIP=y`、`CONFIG_ROCKCHIP_IOMMU=y`、`CONFIG_ROCKCHIP_PM_DOMAINS=y` 均已启用，满足 `ROCKCHIP_RKNPU` 的 `depends on DRM || ...` 与 DRM GEM 内存后端、power-domain、IOMMU（如开启）依赖。`CONFIG_IOMMU_SUPPORT` 需为 y（`CONFIG_ROCKCHIP_IOMMU=y` 隐含）。

**在 `photonicat_defconfig` 追加**（建议放在 `CONFIG_ROCKCHIP_PM_DOMAINS=y`（约 1050 行）附近，并按 `scripts/savedefconfig` 归位到合理区）：
```
CONFIG_ROCKCHIP_RKNPU=m
CONFIG_ROCKCHIP_RKNPU_DEBUG_FS=y
CONFIG_ROCKCHIP_RKNPU_PROC_FS=y
# CONFIG_ROCKCHIP_RKNPU_SRAM is not set
# CONFIG_ROCKCHIP_RKNPU_DRM_GEM 为默认，无需显式
```
> `CONFIG_ROCKCHIP_RKNPU_FENCE=y`（`depends on CONFIG_SYNC_FILE`）为可选优化，M1 可不启、M3/M4 需要再看；若开启需确保 `CONFIG_SYNC_FILE` 已置位。

**验证**：`make O=build photonicat_defconfig && grep ROCKCHIP_RKNPU build/.config` 确认生效。

---

### Step 4 —— rootfs（安装闭源 librknnrt）

**做什么**：在 `mk-rootfs-debian.sh`/`mk-rootfs-ubuntu.sh` 的 minimal chroot 段加入“放置闭源 runtime”。

**约定与变量（用户预下载）**：
- 闭源 blob 由用户预先下载到仓库外的素材目录（**不 git 进仓库**），例如 `$HOME/downloads/rknn/RK356X/Linux/librknn_api/`，含 `aarch64/librknnrt.so` 与 `include/rknn_api.h`、`include/rknn_matmul_api.h`。
- 脚本开头新增变量，例如：
```bash
RKNN_ASSET_DIR="${RKNN_ASSET_DIR:-/path/to/user/downloaded/rknn_assets}"
```
  构建时若 `-z "${RKNN_ASSET_DIR}"` 或目录不存在，则**跳过 NPU 安装并打印警告**（不阻塞 rootfs 其它部分）。

**在 minimal chroot（`mk-rootfs-debian.sh`/`mk-rootfs-ubuntu.sh` 的 `cat << EOF | chroot ...` 段内）追加**（示意，实以脚本注释为准）：
```bash
# 安装 RKNN 闭源运行时（若素材已就位）
if [ -d "${RKNN_ASSET_DIR}/aarch64" ]; then
    install -m 0644 "${RKNN_ASSET_DIR}/aarch64/librknnrt.so" /usr/lib/librknnrt.so
    mkdir -p /usr/include/rknn
    install -m 0644 "${RKNN_ASSET_DIR}/include"/*.h /usr/include/rknn/
    echo '/usr/lib' > /etc/ld.so.conf.d/rknn.conf
    ldconfig
    # 确保用户有 render 组（Photonicat 由 photonicat 用户）以访问 /dev/dri/renderD*
    usermod -a -G render photonicat || true
fi
```
> 说明：
> - DRM render 节点（`/dev/dri/renderD*`）由 udev 以 `render` 组授权；脚本已把 `photonicat` 加入 `render`。若走非-IOMMU + `/dev/rknpu` misc 节点（`CONFIG_ROCKCHIP_RKNPU_DMA_HEAP` 不可用下一般不产生），则另需 udev。首发统一走 DRM render 节点即可。
> - `librknnrt` 放 `/usr/lib` 或 `/opt/rockchip/lib` 皆可；此处用 `/usr/lib` + ldconfig。

**验证（M3）**：chroot 完成后 `ls -l <rootfs>/usr/lib/librknnrt.so`、`ldd` 示例引用；目标板上 `echo $LD_LIBRARY_PATH`/`ldconfig -p | grep rknn`。

---

### Step 5 —— 编译与实机验证

**编译顺序与预期排查点**：
1. `build-base.sh`（会先打全部补丁再 `cp -rf` overlay）。若补丁失败（`.rej`），先核对 6.12.103 上下文，不要强打。
2. `make O=build photonicat_defconfig` → 确认 `CONFIG_ROCKCHIP_RKNPU=m`。
3. `make O=build Image` → 编译期内核。
4. `make O=build rockchip/rk3568-photonicat.dtb` → 验证 DT。
5. `make O=build modules` → 重点：`rknpu.ko` 是否生成，`dmesg` 编译日志有无未解析符号/错误。**预期报错点逐一排查清单**：
   - `.gem_prime_mmap` 不存在 → 已删（Step 1①）。
   - `<soc/rockchip/rockchip_iommu.h>` 找不到 → overlay 头到位（Step1②）。
   - `rockchip_system_monitor`/`rknpu_devfreq` 相关 → 桩化（Step1③）。
   - `drm_prime_sg_to_page_array` deprecated → 仅告警，可忽略或改用新 API。
   - Kconfig 缺 `config ROCKCHIP_RKNPU` → 检查 `source "drivers/rknpu/Kconfig"` 已打。
6. `make O=build modules_install` 打进 `kmods.tar.gz` 供 rootfs/镜像。

**实机验证路径（M4）**：
```
# 板上
modprobe rknpu
dmesg | grep -i rknpu            # 期望 probe 成功、'rockchip,rk3568-rknpu' 匹配
ls -l /dev/dri/renderD*          # DRM GEM 模式下应出现 renderD1xx
# 编译并跑 rknn 示例（rknn_model_zoo 的 mobilenet/YOLOv5 单图）
gcc -o rknn_demo demo.c -lrknnrt -I/usr/include/rknn
./rknn_demo model.rknn test.jpg   # rknn_init==0 且推理输出合理
```

---

## 3. 外部素材收集清单（用户/实施者下载任务）

| # | 素材 | 来源 URL | 合规 | 放哪 |
|---|---|---|---|---|
| M0-1 | `drivers/rknpu/` 源码 | `github.com/rockchip-linux/kernel` branch `develop-6.6`（备选 `develop-6.1`），`drivers/rknpu/` | **GPL v2，可随仓库分发** | overlay `patches/kernel-overlay/drivers/rknpu/` |
| M0-2 | （可选）`rockchip_iommu.h` 原版作参考 | 同仓库 `include/soc/rockchip/rockchip_iommu.h` | GPL v2 | 参考后自写最小桩 |
| M0-3 | `librknnrt.so` + `rknn_api.h`/`rknn_matmul_api.h` | `github.com/airockchip/rknpu2` → `runtime/RK356X/Linux/librknn_api/`（v2.3.2） | **闭源 blob，仅用户自下载，不入 GPL 仓库** | 仓库外素材目录（脚本变量 `RKNN_ASSET_DIR`） |
| M0-4 | （可选）示例/模型 | `github.com/airockchip/rknn-toolkit2`、`rknn_model_zoo` | 开源示例 | 开发主机 |
| M0-5 | RK3568 原理图（确认 vdd_npu/供电） | Photonicat 板厂 | 内部 | — |

---

## 4. 分阶段里程碑与自检清单

### M0 —— 素材齐全
- **完成标准**：develop-6.6 `drivers/rknpu` 可读入；`librknnrt.so`+头已下到 `RKNN_ASSET_DIR`；`kernel/` 为 6.12.103 完整源码。
- **常见失败点**：分支名/路径错（应为 `develop-6.6` 的 `drivers/rknpu/`）；blob 未下载；编译器/交叉工具链未装。

### M1 —— 驱动编译过
- **完成标准**：`CONFIG_ROCKCHIP_RKNPU` 出现在 `.config`；`rknpu.ko` 干净生成（仅允许 deprecated 告警）。三项适配（gem_prime_mmap、iommu 头、devfreq 桩）已落实。
- **常见失败点**：`rockchip_iommu.h` 符号缺失/原型错；devfreq 未桩化；Kconfig/Makefile hook 未打上。

### M2 —— 镜像级编译出（dts + defconfig）
- **完成标准**：`photonicat.dtb` 含 `npu@fde40000` 与 `RK3568_PD_NPU`；`Image` 能编出；内核能启动不崩（NPU 域电源域解析成功）。
- **常见失败点**：dtc 语法、power-domain 未注册导致 `pm_domain_attach` 失败（需 `CONFIG_ROCKCHIP_PM_DOMAINS=y`）；时钟/复位 ID 拼写错。

### M3 —— rootfs 装好
- **完成标准**：`librknnrt.so` 落位 `/usr/lib` + ldconfig；`rknn_api.h` 在 `/usr/include/rknn`；用户属 `render` 组。
- **常见失败点**：blob 路径/变量未配置；`ldd` 找不到依赖（libc 版本）；脚本把 blob 误 git 进仓库。

### M4 —— 实机跑通
- **完成标准**：`modprobe rknpu` 起；`/dev/dri/renderD*` 出现；`rknn_init` 返回 0，跑通一个示例（分类/检测）输出合理。
- **常见失败点**：驱动 ioctl 与 librknnrt 版本不配套（换 v2.3.2）；非-IOMMU 兼容性问题（观测到再切 IOMMU）；`dmesg` 出现 `rknpu iommu disabled, using non-iommu mode` 仍应可用。

---

## 5. 风险与应急计划

| 风险 | 等级 | 降级/绕开 |
|---|---|---|
| 厂商 `rockchip_iommu_*` 符号缺失导致 IOMMU 模式编不过/跑不稳 | 中 | **首发固定非-IOMMU**（DT 不挂 `iommus`），仅需最小头文件过编译；IOMMU 留扩展。 |
| 非-IOMMU 模式与 librknnrt 兼容性 | 中 | 先用 rknn-toolkit2 v2.3.2 示例实测；若 init 报 IOMMU 必需，再按“附-rockchip_iommu 真实现 + 挂 rknpu_mmu”扩展。 |
| `librknnrt` 与内核驱动 ioctl 版本不配套 | 中 | 统一用 v2.3.2 世代；锁定 `RKNN_ASSET_DIR` 版本并在文档注明。 |
| 移除 `scmi_clk` 后 NPU 时钟频率是否满足 | 低 | 首发用 `cru CLK_NPU` + `assigned-clock-rates=600MHz`；若需 DVFS 再补 `scmi_clk 2`（依赖固件暴露，标记待验证）。 |
| Photonicat 无 `vdd_npu` regulator（不做独立调压） | 低 | 驱动 `devm_regulator_get_optional("rknpu")` 容忍缺失；功能不受影响；如需调压再补 PWM/regulator + 硬件查证。 |
| `drm_prime_sg_to_page_array` deprecated | 低 | 仅告警；后续可换新 API。 |
| develop-6.6 vs 6.12 其它隐藏 API 漂移 | 中 | M1 以实际编译报错为准逐条修；保持补丁/overlay模块化以便回退。 |

**应急回退**：所有改动集中在“补丁（可 `git checkout`/删除 `.rej`）+ overlay（新增目录可整体删除）+ defconfig（回滚该段）+ rootfs（强制开关，blob 缺失即跳过）”，对既有 6.12.103 构建无侵入，可随时整体回退到“无 NPU”状态。
