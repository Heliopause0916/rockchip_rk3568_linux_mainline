# RK3568 Photonicat 6.12.103 硬件 bring-up 问题清单

- 日期：2026-08-11
- 内核：linux-6.12.103（photonicat_defconfig）
- 板型：Photonicat（RK3568，debian trixie rootfs）
- 状态：6.12 升级后首次上板，eth0 正常，其余问题如下

> 说明：本清单记录升级到主线 6.12 后暴露的全部硬件驱动问题，区分内核侧 / rootfs 侧 / 系统侧。每项含现象（dmesg 证据）、根因、影响、处置建议、状态。

## 摘要表

| # | 问题 | 类别 | 严重度 | 状态 |
|---|---|---|---|---|
| 1 | eth1（gmac0/SGMII）无法启动 | 内核 | 高 | 待移植 PCS（见 SGMII 专项） |
| 2 | WiFi（ath10k QCA9377）缺固件 | rootfs | 高 | 待补固件 |
| 3 | PCIe combphy 上电锁失败 | 内核 | 中 | 待确认是否使用 |
| 4 | Bluetooth hci0 帧重组失败 | 内核/固件 | 低 | 待观察 |
| 5 | panfrost 冷却设备注册失败 | 内核 | 低 | 良性 |
| 6 | dw-apb-uart 请求 DMA 失败 | 内核 | 低 | 良性（回退 PIO） |
| 7 | hctosys 读硬件时钟失败（后自恢复） | 内核 | 低 | 良性 |
| 8 | photonicat-pm 缺 power-gpios | 内核/DT | 低 | 非阻塞 |
| 9 | ntpsec 尚未同步 | 系统 | 低 | 待联网 |
| 10 | GPT 分区表告警 | 系统 | 低 | 良性 |

## 详细

### 1. eth1（gmac0 / SGMII）无法启动（高，内核）
- 现象：`rk_gmac-dwmac fe2a0000.ethernet: unsupported interface 4`、`NO interface defined!`、打开时 `eth1: stmmac_hw_setup: DMA engine initialization failed`、`__stmmac_open: Hw setup failed`。ip link 显示 eth1 DOWN。
- 根因：gmac0（fe2a0000）在设备树声明 `phy-mode="sgmii"`（接口 4=SGMII），但**主线上游 6.12 的 dwmac-rk 无 SGMII PCS 驱动**（上游对 RK3568/RK3588 均无线 PCS 支持），`stmmac_mac_select_pcs()` 返回 NULL → SGMII 通路无法建立。
- 影响：第二个千兆口不可用。用户期望后期 eth0 与 eth1 都用（当前仅 eth0 接一根线）。
- 处置：移植 6.1 BSP 的 SGMII/XPCS PCS 支持到 6.12（独立专项，见 `.kilo/plans/1786453731168-rk3568-gmac0-sgmii-restore-plan.md`），需另编内核并上板实测。
- 状态：待移植。

### 2. WiFi（ath10k QCA9377）缺固件（高，rootfs）
- 现象：`ath10k_sdio ... failed to fetch board data for bus=sdio,vendor=0271,device=0701,... from ath10k/QCA9377/hw1.0/board-2.bin`。wlan0 DOWN。
- 根因：rootfs 缺少 ath10k QCA9377 固件文件（`/lib/firmware/ath10k/QCA9377/hw1.0/` 下的 `firmware-5.bin`、`board-2.bin` 等）。
- 影响：无线网卡不可用。
- 处置：在 rootfs 打包中加入 ath10k/QCA9377 固件（firmware-ath10k / 对应 deb 或手动落位），并核验文件路径与版本。
- 状态：待补固件。

### 3. PCIe combphy 上电锁失败（中，内核）
- 现象：`phy-fe8c0000.phy: rockchip_p3phy_rk3568_init: lock failed 0x6890000, check input refclk and power supply`、`phy init failed --> -110`、`rockchip-dw-pcie 3c0800000.pcie: probe with driver ... failed with error -110`。
- 根因：PCIe 3.0 combphy 上电时锁相（PLL lock）超时（-110 ETIMEDOUT），可能为冷启动时序/供电/参考时钟问题；当前未确认板子是否实际使用 PCIe（R8169 已决策不启用）。
- 影响：PCIe 未枚举（若有 PCIe 外设则不可用）。
- 处置：确认硬件是否用 PCIe；若不用则作废；若用则排查上电时序/时钟/供电。
- 状态：待确认。

### 4. Bluetooth hci0 帧重组失败（低，内核/固件）
- 现象：`Bluetooth: hci0: Frame reassembly failed (-84)`（0x 出现于启动早期）。
- 根因：串口/UART 蓝牙（hci_uart_qca QCA9377）早期帧错位，可能为 UART 时序或固件加载时序。
- 影响：蓝牙可能受影响，需实测（若本板不用蓝牙可忽略）。
- 处置：待观察/复测；必要时排查 UART 时钟与 CTS/RTS。
- 状态：待观察。

### 5. panfrost 冷却设备注册失败（低，内核）
- 现象：`panfrost fde60000.gpu: [drm:panfrost_devfreq_init [panfrost]] Failed to register cooling device`。
- 根因：未能注册 GPU 热冷却设备（缺 thermal zone 或 DT cooling 属性）。
- 影响：GPU 仍工作，仅无温控策略，非致命。
- 处置：如需 GPU 温控，在 DT 补 cooling 绑定；否则忽略。
- 状态：良性。

### 6. dw-apb-uart 请求 DMA 失败（低，内核）
- 现象：`dw-apb-uart fe680000.serial: failed to request DMA`、`fe650000.serial: failed to request DMA`。
- 根因：UART DMA（如 pl330）未就绪/无 DMA 通道，回退到 PIO。
- 影响：photonicat-pm（fe680000）与蓝牙（fe650000）串口均回退 PIO 仍正常工作，性能略降，非致命。
- 状态：良性。

### 7. hctosys 读硬件时钟失败后自恢复（低，内核）
- 现象：`photonicat-pm serial1-0: hctosys: unable to read the hardware clock`，随后 0.4s：`pcat-pm: seeded system clock from MCU RTC (sec 1786453019)`。
- 根因：启动早期 hctosys 尝试读 rtc0（photonicat-pm）时驱动尚未就绪的时序竞争，随后成功播种。
- 影响：系统时钟最终已从 MCU RTC 同步，无实际影响。
- 状态：良性。

### 8. photonicat-pm 缺 power-gpios（低，内核/DT）
- 现象：`photonicat-pm serial1-0: Failed to setup power GPIO!`（DT 无 power-gpios；`No GPIO consumer power found`），但 `photonicat power manager initialized OK` 且 Modem power on 成功。
- 根因：pcat-pm 子节点未提供 power GPIO 属性。
- 影响：非阻塞，Modem 供电走正常路径成功；若 v1 需要 power GPIO 可后续在 DT 补充。
- 状态：非阻塞。

### 9. ntpsec 尚未同步（低，系统/rootfs）
- 现象：`ntpd: CLOCK: kernel reports TIME_ERROR: 0x41: Clock Unsynchronized`（21:03）。
- 根因：网络时间尚未收敛（需联网并运行一段）。
- 处置：联网后观察；若长期不同步排查 ntp.conf/网络。
- 状态：待联网。

### 10. GPT 分区表告警（低，系统）
- 现象：`GPT: Use GNU Parted to correct GPT errors.`
- 根因：SD 卡 GPT 分区表存在非致命不一致（仍可启动）。
- 处置：如需可运行 `parted /dev/mmcblkX` 修复；不影响启动。
- 状态：良性。

## 已验收正常项（供对照）
- 6.12.103 启动，PREEMPT，4 核，1.9 GiB RAM，740 模块。
- photonic-pm 内核 serdev 通道：`/dev/pcat-pm-ctl` 存在、`/dev/ttyS4` 消失（v1 互斥符合预期）、pcat-manager kernel(ctl) 模式、Modem power on 成功、PMU FW RA2E1230523000、RTC 回读播种。
- 原生 rng：rng_current=rockchip-rng，`/dev/hwrng` 可读。
- eth0（gmac1 RGMII + YT8521）：1 Gbps Full，Link detected。
- option/usbserial：ttyUSB0-3 调制解调器检测正常；rfkill_gpio_neo 已加载；ath10k_sdio 模块已加载（缺固件具体见 #2）。
