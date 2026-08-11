# TRNG 单一风险专项（rockchip-rng-hardening）

> 本文档为 **TRNG 单一风险**专项，范围仅限"在升级后的内核上补输出熵有效性校验 overlay"。
> **执行时点排在 `kernel-upgrade.md` 的版本升级之后**：升级后大部分隐患被主线吸收，本专项只剩唯一主线未覆盖项。
> 内核整体升级见 `.kilo/plans/kernel-upgrade.md`，两文档性质独立、分开撰写。

## 1. 风险定位（现状 6.1.106 基线）

### 1.1 仓库 overlay 版 `rockchip-rng.c` 的隐患
- 仓库 overlay 驱动 `patches/kernel-overlay/drivers/char/hw_random/rockchip-rng.c`（~310 行）**完全无 reset 处理**（grep reset/reset_control/udelay 零命中）；`quality = 999` 硬编码（L241）。
- 它是基于 6.1 的仓库自制精简 backport，**不是**主线 dcf4fef 的干净 backport。

### 1.2 DT / 驱动不一致
- 配套 802 DTS（`802-arm64-dts-rockchip-add-hardware-random-number-genera.patch`）在 rk3568 节点声明了 `resets = <&cru SRST_TRNG_NS>; reset-names="reset";`，**但驱动不消费** —— DT 声明与驱动行为不一致。

### 1.3 读取路径风险
- `rk_rng_v1/v2_read` 依赖 `readl_poll_timeout` 等 START 位清除；真超时会返错（不喂数据）。
- 但若寄存器 **stuck 为 0**（reset 未释放 / 时钟未跑 / 振荡环失效），poll 条件即时成立 → 读全 0 DOUT、**返回成功**。
- `rk_rng_read_regs` 对输出**无任何全零/恒定校验**。

### 1.4 熵信用放大
- hwrng core 熵信用公式约 `entropy = rc * 8 * quality >> 10`：rc=32B、quality=999 → **约 249 bit** 被 credit。
- core 无条件信任 driver 上报的 quality、**不校验数据内容**（恒定数据会被 mix 入池并计高信用）。

## 2. 上游主线现状（升级后已覆盖项）

- 上游主线 `rockchip-rng.c`（2024-08 dcf4fef 起才存在，落 6.11+）：probe **自始带** reset assert/deassert、时钟使能失败会报错、读超时返回错误；但**同样不校验输出内容**。
- RK3568 TRNG 上游已文档化"无信号调理器、FIPS 测试大量失败"，quality 上游取 **900**；RK3588/RK3576 走独立 TRNGv1（quality=999）。
- 无 rockchip 相关 CVE、无"全零输出"实际 bug 报告、无对应修复提交。

## 3. 升级后仅剩项（唯一主线未覆盖）

升级到维护中 LTS 后，下列项被主线吸收、无需再做：
- ~~阶段二（backport 主线驱动到 6.1 overlay）~~ **完全作废**。
- ~~reset 消费~~（主线 probe 自带 assert/deassert）。
- ~~时钟使能失败检测 / 读超时返回错误~~（主线已处理）。
- ~~quality 900~~（主线取 900，仓库 999 被覆盖）。

**仅剩一项保留：输出熵有效性校验 overlay。**

## 4. 本专项范围（唯一工作项）

- **在升级后的新基线上，为 `rockchip-rng` 补"输出熵有效性校验" overlay**：
  - 对 DOUT 读取结果做**全零 / 恒定模式检测**，检测到则视为 RNG 失效：返回错误、不喂数据、不 credit 熵（避免把恒定数据 mix 入池）。
  - 实现方式待定：可基于主线驱动在 overlay 层增量补丁，或小段驱动内校验逻辑（随实现评估，保持最小改动）。
- 所需 DTS 层（`&rng &rng-okay`、`resets` 声明）在升级后仍保留即可，无需额外 DTS 改动。

## 5. 触发校验失败的预期行为

- 检测到全零/恒定输出 → 返回错误、不喂数据、不 credit 熵。
- 结合内核 `crypto rng`/`rng-tools` 运行期探测，把失效暴露为可观测错误而非静默 credit。

## 6. 执行前置条件

1. 完成 `kernel-upgrade.md` 的版本升级并核验新基线干净（无 `.rej`/`.orig` 残留）。
2. 在新基线上确认 `CONFIG_HW_RANDOM=y`、`CONFIG_HW_RANDOM_ROCKCHIP=y` 等 defconfig 条目随升级保持。

## 7. 不属于本文档范围

- 内核整体版本升级的核对清单/回退保障：见 `.kilo/plans/kernel-upgrade.md`。
- 用户态 `pcat-manager` 内核集成文档：见 `.kilo/plans/pcat-manager-kernel-integration-plan.md`（已闭环，不改动）。
