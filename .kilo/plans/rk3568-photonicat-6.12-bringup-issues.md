# RK3568 Photonicat 6.12.103 硬件 bring-up 问题清单

- 日期：2026-08-11
- 内核：linux-6.12.103（photonicat_defconfig）
- 板型：Photonicat（RK3568，debian trixie rootfs）
- 状态：6.12.103 升级 bring-up，eth0 与 eth1（gmac0/SGMII）均已恢复且满速，其余问题如下

> 说明：本清单记录升级到主线 6.12 后暴露的全部硬件驱动问题，区分内核侧 / rootfs 侧 / 系统侧。每项含现象（dmesg 证据）、根因、影响、处置建议、状态。

## 摘要表

| # | 问题 | 类别 | 严重度 | 状态 |
|---|---|---|---|---|
| 1 | eth1（gmac0/SGMII）无法启动 | 内核 | 高 | ✅ 已解决（2026-08-11，补丁 116–121 上板验证） |
| 2 | WiFi（ath10k QCA9377） | rootfs | 高 | 已验收正常（2026-08-11 上板实测） |
| 3 | PCIe combphy 上电锁失败 | 内核 | 中 | 待确认是否使用 |
| 4 | Bluetooth hci0 帧重组失败 | 内核/固件 | 低 | 待观察 |
| 5 | panfrost 冷却设备注册失败 | 内核 | 低 | 良性 |
| 6 | dw-apb-uart 请求 DMA 失败 | 内核 | 低 | 良性（回退 PIO） |
| 7 | hctosys 读硬件时钟失败（后自恢复） | 内核 | 低 | 良性 |
| 8 | photonicat-pm 缺 power-gpios | 内核/DT | 低 | 非阻塞 |
| 9 | ntpsec 尚未同步 | 系统 | 低 | 待联网 |
| 10 | GPT 分区表告警 | 系统 | 低 | 良性 |

## 详细

### 1. eth1（gmac0 / SGMII）无法启动（高，内核）✅ 已解决
- 现象（修复前）：`rk_gmac-dwmac fe2a0000.ethernet: unsupported interface 4`、`NO interface defined!`、打开时 `eth1: stmmac_hw_setup: DMA engine initialization failed`、`__stmmac_open: Hw setup failed`，ip link 显示 eth1 DOWN。
- 根因：gmac0（fe2a0000）在 DT 声明 `phy-mode="sgmii"`（接口 4=SGMII），但主线 6.12 的 dwmac-rk 无 SGMII PCS 驱动，`stmmac_mac_select_pcs()` 返回 NULL → SGMII 通路无法建立。
- 解决：移植上游 RK3568 XPCS v2 系列（patchwork series 1138639）为 `patches/kernel/116..121`：
  - 116 pcs-xpcs-rk 驱动（新 pcs-xpcs-rk.c + CONFIG_PCS_XPCS_ROCKCHIP）
  - 117 SGMII ANRESTART（BMCR_ANRESTART）
  - 118 dwmac-rk SGMII 支持（select PCS_XPCS_ROCKCHIP）
  - 119 combphy2 SGMII mac-sel
  - 120 rk3568.dtsi xpcs 节点
  - 121 **stmmac PCS 生命周期修复（关键）**：6.12 `stmmac_pcs_setup()` 调用 `priv->plat->pcs_init()`（rk_pcs_init 已把 XPCS 写入 `priv->hw->xpcs`）后仍执行 `priv->hw->xpcs = xpcs;`，而局部 `xpcs` 在 pcs_init 分支为 NULL，把平台 attach 的 XPCS 覆盖成 NULL → `rk_select_pcs` 返回 NULL → phylink 从不挂 PCS → `xpcs_config_aneg_c37_sgmii`（SGMII in-band AN）从不执行。修复：走 pcs_init 分支后就地 return。
  - overlay（photonicat.dts / ex1.dts）：gmac0 加 `pcs-handle=<&xpcs_mii0>` + `managed="in-band-status"`；serdes phys（combphy2）移到 `&xpcs`（`phy-names="serdes"`）避免双消费者；`&xpcs_mii0 status=okay`；`&combphy2 rockchip,sgmii-mac-sel=<0>`。
- 验收（2026-08-11 上板实测）：`Link detected: yes`、`Speed: 1000Mb/s`、`Duplex: Full`、dmesg `eth1: Link is Up - 1Gbps/Full`；iperf3 eth1 双向 ~940 Mbit/s，与 eth0（RGMII）同档满速；eth0 与 eth1 同网段可同时在线。
- 参考：YT8521 的 RGMII/SGMII 模式由硬件 strap 决定，驱动（motorcomm.c）读取不切换；6.12 mainline motorcomm 已完整支持 YT8521 SGMII，无需额外补丁。
- 状态：已解决。

### 2. WiFi（ath10k QCA9377）（高，rootfs）✅ 已解决
- 现象（旧）：`ath10k_sdio ... failed to fetch board data for bus=sdio,vendor=0271,device=0701,... from ath10k/QCA9377/hw1.0/board-2.bin`，曾误判为缺固件。
- 根因澄清：rootfs 已通过 `firmware-atheros` 包（non-free-firmware 源）正确供给固件，`/lib/firmware/ath10k/QCA9377/hw1.0/` 下 `firmware-5.bin`、`board-2.bin`、`board.bin` 等均齐全。`failed to fetch board data from board-2.bin` 是 QCA9377 SDIO 的已知良性信息：board-2.bin 无匹配该 SDIO 变体的条目，驱动自动回退到片上 OTP 校准（dmesg `cal otp`），不影响功能。
- 验收（2026-08-11 上板实测）：驱动完整初始化（`firmware ver WLAN.TF.1.1.1-00061-QCATFSWPZ-1`、`htt-ver 3.32 wmi-op 4 htt-op 3 cal otp max-sta 32`）；`wlan0` 注册成功且 MAC 合法；`nmcli dev wifi list` 可扫描 2.4G/5G 大量 AP（GL-AXT1800-Steven-5G 信号 94%）。
- 处置：无需补固件。另留意板上第二块 PCIe WiFi 为 wcn6855（ath11k_pci，wlan1）；`cfg80211: regulatory.db malformed` 为内核与 crda 版本不匹配的合规信息缺失，不阻塞连接，若遇受限信道再单独处理。
- 状态：已验收正常。

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
- eth1（gmac0 SGMII + YT8521 + combphy2）：1 Gbps Full，Link detected，iperf3 ~940 Mbit/s；eth1 与 eth0 同网段可同时在线。
- option/usbserial：ttyUSB0-3 调制解调器检测正常；rfkill_gpio_neo 已加载；ath10k_sdio 模块已加载（缺固件具体见 #2）。
