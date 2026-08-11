# RK3568 Photonicat gmac0 SGMII（eth1）在主线上游 6.12.103 上恢复支持——可行性调研 + 实施计划

> 纯调研/规划文档。范围：主线上游 6.12.103 对内 RK3568 gmac0（fe2a0000）SGMII（eth1）的支持现状、根因、可选方案与推荐路线。
> 本任务仅做只读调研，不涉及任何文件修改/编译/写操作。

---

## A. 现状结论（主线上游 6.12 对 RK3568 gmac0 SGMII 的支持程度）

**结论：上游主线对 RK3568 gmac0 SGMII **完全不支持**——既不是"配置缺失"也不是"半支持"，而是驱动层根本没有可用的 SGMII PCS 路径。**

核心证据（均在本仓库 6.12.103 源码内已核验）：

1. **dwmac-rk.c（Rockchip 平台粘合层）无任何 SGMII 挂钩**：
   - `rk3568_ops` 只定义 `set_to_rgmii` / `set_to_rmii`（`kernel/.../dwmac-rk.c:1107-1118`），无 `set_to_sgmii`、无 `pcs`/`xpcs` 字段。
   - `rk_gmac_check_ops()`（:1873-1892）只接受 RGMII(含 ID/RXID/TXID) 与 RMII；SGMII 落入 `default` 分支打印 `"unsupported interface %d"`（4=SGMII）。
   - `rk_gmac_powerup()`（:1894-1946）的接口 `switch` 同样只处理 RGMII/RMII，SGMII 落入 `default` 打印 `"NO interface defined!"`。
   - 也就是说 dwmac-rk 遇到 SGMII 时**既不配置 MAC 侧接口，也不接 PCS**，仅打两条日志后继续（`check_ops` 返回 0，`powerup` 返回 0）。
   - 连 RK3588（同在 compatible 列表）的 `rk3588_ops` 也只有 RGMII/RMII，无 SGMII——**上游从未给任何 Rockchip SoC 做过 SGMII**。

2. **pcs-xpcs.c 存在，但对 RK3568 不适用**：
   - `kernel/drivers/net/pcs/pcs-xpcs.c` 是 **Synopsys DesignWare XPCS**（`DW_XPCS_SGMII` 等枚举 :143），用于带独立 DW XPCS IP 的 10G/多千兆平台（dwmac-intel、dwmac-tegra mgbe）。
   - RK3568 的 SGMII PCS 是**集成在 Combphy2 内的 Rockchip 专属 SGMII PCS**，不是 DW XPCS，无 `DW_XPCS_ID`。
   - stmmac 核心 `stmmac_pcs_setup()`（`stmmac_mdio.c:498-531`）只通过 `pcs-handle`→`xpcs_create_fwnode()` 或 MDIO `pcs_mask` 创建 **DW XPCS**；对非 XPCS 节点会 `dev_err_probe("No xPCS found")` 而失败。因此不能把 `pcs-handle` 指向 combphy/RK-SGMII 节点来"白嫖"核心 XPCS 机制。

3. **Combphy2 只负责 PHY（模拟/管道）侧，不提供 MAC 侧 phylink PCS**：
   - `phy-rockchip-naneng-combphy.c` 对 `PHY_TYPE_SGMII` 仅做 `pipe_xpcs_phy_ready` / `sgmii_mode_set` 等 GRF 位配置（:466-471），把 Combphy 切成 SGMII 模式；**它没有注册任何 `struct phylink_pcs`**，是标准的 PHY provider（`devm_phy_get`），驱动不了 MAC↔PCS 之间的 SGMII 数据通路/带内自协商。

4. **phylink 在 SGMII 模式下硬性需要 PCS**：
   - `phylink.c` 的 SGMII 路径依赖 `pl->pcs` 或 `mac_ops->mac_select_pcs()`（:663-685、:1129-1163）。stmmac 的 `stmmac_mac_select_pcs()`（`stmmac_main.c:954-967`）在 `plat->select_pcs` 未设置时返回 NULL。
   - 6.12.103 里 `dwmac-rk.c` 未设置 `plat->select_pcs`，也未被 `stmmac_pcs_setup` 创建 XPCS → **SGMII 无 PCS → 该接口无法建立数据链路**。

5. **主线上游最新 master 依然如此**（web 取证）：`drivers/net/pcs/Makefile` 只有 pcs-lynx / pcs-mtk-lynxi / pcs-rzn1-miic / pcs-xpcs，无 Rockchip SGMII PCS；master 的 `dwmac-rk.c` 即便已重构（`set_speed`/`get_interfaces`/新 probe），仍未出现任何 SGMII/PCS 代码。

6. **Kconfig/defconfig**：`STMMAC_ETH` 通过 `select PCS_XPCS` 自动使能 PCS_XPCS（`:7`）；photonicat_defconfig 已 `CONFIG_STMMAC_ETH=y` + `CONFIG_PHY_ROCKCHIP_NANENG_COMBO_PHY=y`（:519、:1070），这些**对 SGMII 起不到作用**（PCS_XPCS 是 DW XPCS，与 RK-SGMII 无关）。

7. **DTS 现状**：板级 photonicat.dts 给 gmac0 配置了 `phy-mode="sgmii"`、`phys=<&combphy2 PHY_TYPE_SGMII>`、`phy-handle=<&sgmii_phy>`、`assigned-clock-parents=<&gmac0_xpcsclk>`（125MHz 固定时钟），**但没有 `pcs-handle`，也没有 `xpcs` 节点**（升级时已删除）。`rk3568.dtsi` 的 gmac0 节点仅含通用属性，无 phy-mode/phys/pcs。

**一句话**：要让 eth1 SGMII 起来，缺的是一个"能把 Combphy 内 Rockchip SGMII PCS 接到 stmmac phylink 上的驱动"。这个驱动主线从未写过，需要用户侧移植/新写。

---

## B. 根因分析（eth1 起不来的直接原因链）

复现日志：`unsupported interface 4`（4=SGMII）、`NO interface defined!`、open 时 `stmmac_hw_setup: DMA engine initialization failed`。

1. **DTS 声明了 SGMII 但无 PCS**：
   - `phy-mode="sgmii"` → `plat->phy_interface = PHY_INTERFACE_MODE_SGMII(4)`。
   - 缺少 `pcs-handle`（也没有能被 `stmmac_pcs_setup` 识别的 XPCS 节点）→ 核心无法给该 MAC 创建 PCS。

2. **dwmac-rk 粘合层显式拒绝/忽略 SGMII**：
   - `rk_gmac_powerup()` → `rk_gmac_check_ops()` 遇 SGMII 落入 `default` → 打印 `"unsupported interface %d"`，返回 0（不报错，但什么都没配）。
   - 随后 `switch(phy_iface)` 的 `default` → 打印 `"NO interface defined!"`（MAC 侧 RGMII/RMII 接口选择、时钟分频等全部不做）。
   - `check_ops`/`powerup` 均返回 0 → probe 不失败、netdev eth1 被创建，但 MAC 接口从未进入可用态。

3. **phylink 无 PCS、无数据通路 → open 失败**：
   - eth1 以 SGMII 打开时，`stmmac_mac_select_pcs()` 返回 NULL（`plat->select_pcs` 未设、无 xpcs）。
   - SGMII 需要 PCS 完成 GMII↔SGMII 转换与带内自协商；此时 Combphy 虽被 `phys` 切成 SGMII 物理模式，但 MAC 侧没有任何驱动去驱动该 PCS，链路无法建立。
   - 最终 `stmmac_open()`→`stmmac_hw_setup()`→`stmmac_init_dma_engine()` 因链路/时钟未就绪返回失败并打印 `"DMA engine initialization failed"`。
   - （注：`DMA engine initialization failed` 的确切触发需上板 `dmesg` 进一步确认——它是"无可用 SGMII 通路"的**次级症状**；主因是 SGMII PCS 缺失。此处对次级症状标记为推断。）

4. **时钟侧**：`assigned-clock-parents=<&gmac0_xpcsclk>`（125MHz）已接好，`SCLK_GMAC0_RX_TX` 有来源，**时钟不是主因**（DTS 时钟配置保留自 6.1，基本可用）。

**根因归纳**：`DTS 声明 SGMII（需 PCS）+ 主线无 RK-SGMII PCS 驱动 + dwmac-rk 无 SGMII 分支` 三者叠加，导致 SGMII 接口既无 PCS 也无 MAC 侧初始化，最终无法 open。

---

## C. 可选方案

### 方案 1：DTS `pcs-handle` + 使能 `PCS_XPCS`（最小接入）

- **思路**：若主线具备现成 XPCS 能力，通过 DTS 加 `pcs-handle` 指向一个 XPCS 节点即可恢复。
- **可行性：✗ 不可行**。理由：`stmmac_pcs_setup()` 的 `pcs-handle` 分支调用 `xpcs_create_fwnode()`，只会按 **Synopsys DW XPCS** 的 compatible/regs 创建；RK3568 无该 IP。硬加 `pcs-handle` 会直接 `dev_err_probe("No xPCS found")` 导致 **probe 失败**（eth1/甚至整机网络异常，风险更大）。`PCS_XPCS` 已随 `STMMAC_ETH` select 使能，但对本方无效。
- **改动点**：无（DTS 加 pcs-handle 属错误思路）。工作量 ~0，风险高，不做。

### 方案 2：移植旧 6.1 BSP 的 PCS/XPCS 支持（推荐，真正的实现路径）

- **思路**：把旧 6.1 BSP 里"给 gmac0 提供 SGMII PCS"的整套机制搬进 6.12。改造为符合 6.12 的 phylink/stmmac API。
- **改动点清单**：
  1. **（前置，必做）取回 6.1 BSP 源码**：当前工作区 `archives/` 只有 `linux-6.12.103.tar.xz`，**6.1 源码已不在仓库**。需从用户既有 6.1 构建树/SDK/存档取回：
     - `drivers/net/ethernet/stmicro/stmmac/dwmac-rk.c` 的 SGMII 部分（`set_to_sgmii`、phy-grf/接口选择、时钟、`plat` 回调与 PCS 挂钩）；
     - 那个被删除的 `xpcs` 节点的绑定/驱动（compatible、寄存器基址、时钟、GRF 位），以及它如何注册成 phylink PCS。
     - **这是本方案最大不确定性**：若 6.1 源码无法取得，则需按 RK3568 TRM 从头实现 RK-SGMII PCS 驱动（工作量显著增大）。
  2. **dwmac-rk.c**：
     - 在 `rk_gmac_check_ops()`/`rk_gmac_powerup()` 增加 `PHY_INTERFACE_MODE_SGMII/QSGMII` 分支（校验通过、接口选择、GRF 写、时钟）。
     - 在 `rk_get_interfaces()` 使能 SGMII 位（6.12 用 `get_interfaces` 回调）。
     - 注册一个 `struct phylink_pcs`（RK-SGMII PCS，含 `pcs_config/pcs_link_up/pcs_validate`），并提供给 stmmac：设置 `plat->select_pcs`（参照 dwmac-intel 的 `select_pcs` 返回 `&xpcs->pcs` 模式）或走 `stmmac_pcs_setup` 的 `pcs-handle` 路径（但后者会被当成 DW XPCS，故更推荐 `plat->select_pcs` 或自定义 PCS 挂接）。
  3. **PCS 驱动**：新增/移植 RK-SGMII PCS 驱动（操作 Combphy 内 PCS 寄存器：带内自协商、链路状态、速率）。6.1 若已有（`xpcs` 节点驱动），移植到 6.12；否则新写（`drivers/net/pcs/pcs-rk-sgmii.c` + Makefile/Kconfig）。
  4. **DTS**：恢复被删除的 `xpcs`/PCS 节点（在 photonicat.dts / 其 dtsi），并在 `&gmac0` 加 `pcs-handle = <&xpcs>`（或按 6.1 绑定方式）；保留现有 `phys=<&combphy2 PHY_TYPE_SGMII>`。
  5. **defconfig**：无需新增关键项（PCS 随 STMMAC；若新写 PCS 需加对应 Kconfig 并确认 `CONFIG_...SGMII_PCS=y`，或以 `select` 方式随 DWMAC_ROCKCHIP 自动启用）。
- **涉及文件**：`kernel/drivers/net/ethernet/stmicro/stmmac/dwmac-rk.c`、`kernel/drivers/net/pcs/pcs-rk-sgmii.c`（新）、`kernel/drivers/net/pcs/{Makefile,Kconfig}`、`kernel/arch/arm64/boot/dts/rockchip/*photonicat*.dts(.dtsi)`、`kernel/drivers/net/ethernet/stmicro/stmmac/{stmmac_platform.c 或 stmmac_main.c}`（按需接线）、defconfig（按需）。
- **预计工作量**：大（属完整内核功能移植/新写，跨 phylink/PHY/stmmac/DTS四个层面；含 6.1 源码回收与 6.12 API 适配、编译、上板联调、吞吐/速率验证）。
- **风险**：
  - 6.1 源码不可得/与 6.12 差异大 → 需从 TRM 重建 PCS 驱动，风险最高；
  - phylink/stmmac API 与 6.12 不匹配导致编译/行为偏差；
  - Combphy2 同时服务 USB3/PCIe/SATA，SGMII 模式互斥需确认不影响其它接口；
  - 需另编内核（必然）。

### 方案 3：兜底折中

- **思路 A（放弃/降级）**：eth1 的 SGMII 直接放弃，只保留 eth0（gmac1 RGMII）作为唯一有线网口；在文档/固件中说明 eth1 暂不可用，待后续内核或补丁支持。改动最小。
- **思路 B（保留 phy-mode 但禁用）**：把 photonicat.dts 的 `&gmac0` 改为 `status="disabled"` 或去掉 `phy-mode="sgmii"`，避免启动期报错与开销；等真正移植完成再启用。
- **预计工作量**：极小（仅 DTS/文档）。风险低。作为至少先让系统干净空跑、避免误判为失效的临时措施。

> 客观评估：方案 1 不可行且有害；方案 3 是低成本的暂态保底；**方案 2 是唯一能让 eth1 真正工作的路径**，但成本/风险显著，须先解决"6.1 源码是否可取得"这一前置问题。

---

## D. 推荐路线 + 分步实施清单

**推荐：先做方案 3(思路 B) 暂态兜底（立即、低风险），再并行推进方案 2 的可行性前置核验；确认 6.1 PCS 源码可取得后，再正式实施方案 2。**

> 阶段一/二（TRNG 专项、pcat-manager 内核集成）与会话记忆中的既有决策表明：SGMII 这块是"内核升级"专项下的一个收尾缺口，与其它专项相互独立，可与它们的验证并行推进，互不为前置。

### Step 0（前置决策，阻塞性）
- [ ] 确认是否能取回 6.1 BSP 的 SGMII/XPCS 源码（旧构建树、归档 git、Rockchip SDK tag）。
  - 若可 → 走完整方案 2。
  - 若不可 → 评估是否值得按 RK3568 TRM 从零实现 RK-SGMII PCS（工作量、风险大，建议慎重/或先维持方案 3）。
- **核对点**：拿到 6.1 的 `dwmac-rk.c` SGMII 片段 + `xpcs` 节点绑定 + PCS 驱动源码。
- 验证命令（只读）：在取回的源码上 `grep -n "sgmii\|xpcs\|phylink_pcs\|select_pcs" drivers/net/.../dwmac-rk.c drivers/net/pcs/ arch/arm64/boot/dts/rockchip/rk3568-photonicat*.dts`

### Step 1（暂态兜底，立即做，不改内核）
- [ ] 在 `patches/kernel-overlay/.../rk3568-photonicat.dts(.dtsi)` 把 `&gmac0` 暂时 `status="disabled"`（或注释 `phy-mode="sgmii"`），消除启动报错与无效网络口；eth0 不受影响。
- 核对点：编译 overlay 后 dts 无报错；上板 `ip -br link` 只见 eth0。
- 验证：`./build-base.sh`（用户手动执行）→ 板端 `ip -br addr`。

### Step 2（移植准备：梳理 6.12 接线点，只读核验）
- [ ] 确认 6.12 中 stmmac 的 PCS 挂接方式，决定走 `plat->select_pcs`（推荐，类似 dwmac-intel `:456-460` 返回 `&priv->hw->xpcs->pcs`）还是自定义 PCS。
- [ ] 确认 Combphy2 PHY_TYPE_SGMII 与 `phys` 已正常工作（板端 `ethtool -S` / combphy dmesg）。
- **核对点/命令（只读）**：
  - `grep -n "select_pcs\|hp-\|stmmac_mac_select_pcs" kernel/drivers/net/ethernet/stmicro/stmmac/stmmac_main.c`
  - `grep -n "pcs" kernel/drivers/net/ethernet/stmicro/stmmac/{stmmac_platform.h,stmmac.h}`（`plat->select_pcs` 字段）
  - `grep -rn "PHY_TYPE_SGMII\|pipe_xpcs_phy_ready" kernel/drivers/phy/rockchip/phy-rockchip-naneng-combphy.c`

### Step 3（移植实现：dwmac-rk + PCS 驱动 + DTS）
- [ ] dwmac-rk.c：加 `PHY_INTERFACE_MODE_SGMII` 到 check_ops/powerup/get_interfaces；实现 SGMII 的 GRF/接口/时钟配置；实现 RK-SGMII `struct phylink_pcs` 并设 `plat->select_pcs`。
- [ ] 移植/新建 `pcs-rk-sgmii.c`（+ Kconfig/Makefile，建议 `select` 随 DWMAC_ROCKCHIP）。
- [ ] DTS：恢复 `xpcs`/PCS 节点，`&gmac0` 加对应 `pcs-handle`（或按 6.1 绑定），保留 `phys`/时钟。
- **核对点（只读）**：
  - `grep -n "select_pcs\|PHY_INTERFACE_MODE_SGMII\|phylink_pcs" kernel/drivers/net/ethernet/stmicro/stmmac/dwmac-rk.c`
  - `git diff`（在实现分支上查改动是否收敛、无牵连）
  - DTS `dtc`/`make ... dtbs`（用户手动编译）
- 工作量集中在此步；需另编内核。

### Step 4（编译与模块核验，用户手动执行编译）
- [ ] 全量 `make O=build`（用户手动）：Image + modules 无错误；确认无新增 `.rej`/`.orig` 残留。
- [ ] 确认 `pcs-rk-sgmii`/SGMII 相关符号编入（`grep` 编出的 .mod/.ko，或 `lsmod`）。

### Step 5（上板联调与验证，用户手动）
- [ ] 上板后 `ip link set eth1 up`；`dmesg | grep -i -E "sgmii|pcs|fe2a0000|eth1"`。
- [ ] `ethtool eth1` 看 speed/duplex/link；`ethtool -S eth1` 看收发包；`ping` 对端。
- [ ] 回归：确认 Combphy2 原 SATA/USB3/PCIe 功能未受 SGMII 模式互斥影响；eth0（gmac1 RGMII）保持正常。
- **核对点**：不再出现 `unsupported interface 4` / `NO interface defined!` / `DMA engine initialization failed`；`ip link` 显示 eth1 LOWER_UP 且能通。

### 是否可并行
- 可。方案 3 兜底与其它专项（TRNG、pcat-manager）互不依赖，可并行。
- 方案 2 的 Step 0/2 为只读调研，也可随时并行；但 Step 3/4/5（写代码+编译+上板）占带宽，建议与其它专项错峰。

---

## E. 关键证据（文件路径 + 关键行/片段）

**A. dwmac-rk.c 无 SGMII（6.12.103）**
- `kernel/drivers/net/ethernet/stmicro/stmmac/dwmac-rk.c`
  - `rk3568_ops`（:1107-1118）仅 `set_to_rgmii/rk3568_set_to_rgmii`、`set_to_rmii`，无 sgmii。
  - `rk3588_ops`（:1409-1416）也仅 RGMII/RMII。
  - `rk_gmac_check_ops()`（:1873-1892）：`default: dev_err(..., "unsupported interface %d", bsp_priv->phy_iface);`（返回 0）。
  - `rk_gmac_powerup()`（:1894-1946）：`default: dev_err(dev, "NO interface defined!\n");`。
  - `rk_gmac_dwmac_match[]`（:2073-2089）含 `rockchip,rk3568-gmac/.data=&rk3568_ops`。

**B. stmmac 核心 XPCS 仅认 DW XPCS**
- `kernel/drivers/net/ethernet/stmicro/stmmac/stmmac_mdio.c` `stmmac_pcs_setup()`（:498-531）：`pcs-handle` → `xpcs_create_fwnode(pcsnode, mode)`，失败 `dev_err_probe(..., "No xPCS found\n")`。
- `kernel/drivers/net/ethernet/stmicro/stmmac/stmmac_main.c` `stmmac_mac_select_pcs()`（:954-967）：`if (priv->plat->select_pcs) {...} return NULL;`。
- `kernel/drivers/net/ethernet/stmicro/stmmac/Kconfig` `STMMAC_ETH ... select PCS_XPCS`（:4-7）。

**C. pcs-xpcs.c 是 Synopsys DW XPCS**
- `kernel/drivers/net/pcs/pcs-xpcs.c`：`DW_XPCS_SGMII`（:143）、`synopsys_xpcs_compat`（:1260+）、`dw_xpcs_compat` id 判定（:1333+）。

**D. Combphy2 只做 PHY 模式，不注册 phylink PCS**
- `kernel/drivers/phy/rockchip/phy-rockchip-naneng-combphy.c`
  - `case PHY_TYPE_SGMII:rockchip_combphy_param_write(...,&cfg->pipe_xpcs_phy_ready,true); ...sgmii_mode_set,true;`（:466-471）。
  - 全文无 `phylink_pcs` / `struct phylink_pcs`。

**E. DTS 现状**
- `kernel/arch/arm64/boot/dts/rockchip/rk3568.dtsi`：gmac0 节点（:169-214）仅通用属性，无 phy-mode/phys/pcs-handle。
- `patches/kernel-overlay/arch/arm64/boot/dts/rockchip/rk3568-photonicat.dts`（= 同根 in-tree `kernel/.../rk3568-photonicat.dts`）
  - `&gmac0 { ... phys=<&combphy2 PHY_TYPE_SGMII>; phy-mode="sgmii"; phy-handle=<&sgmii_phy>; assigned-clock-parents=<&gmac0_xpcsclk>; ... }`（:313-329）。
  - `gmac0_xpcsclk` 固定 125MHz 时钟节点（:41-46）。
  - **无 `pcs-handle`、无 `xpcs` 节点**。
  - `&gmac1`（:331-351）为 RGMII（eth0）。

**F. defconfig**
- `patches/kernel-overlay/arch/arm64/configs/photonicat_defconfig`：`CONFIG_STMMAC_ETH=y`（:519）、`CONFIG_PHY_ROCKCHIP_NANENG_COMBO_PHY=y`（:1070）。

**G. 上游最新 master 依然不支持**（web 取证，非本仓库）
- `drivers/net/pcs/Makefile`：仅 `pcs-xpcs / pcs-lynx / pcs-mtk-lynxi / pcs-rzn1-miic`（无 Rockchip）。
- `drivers/net/ethernet/stmicro/stmmac/dwmac-rk.c`（master）：重构后仍只有 RGMII/RMII，无 SGMII/PCS。

**H. 运行时日志对应**
- `unsupported interface 4` ↔ `rk_gmac_check_ops()` default（SGMII=4）。
- `NO interface defined!` ↔ `rk_gmac_powerup()` default。
- `DMA engine initialization failed` ↔ `stmmac_main.c`（:3393-3397）`stmmac_init_dma_engine()` 失败（次级症状）。

**标注为推断/无法在当前仓库确证的部分**：
- 旧 6.1 BSP 的 SGMII/XPCS 具体实现（`set_to_sgmii` 的 GRF 位、被删 `xpcs` 节点的 compatible/regs/绑定、它注册 phylink PCS 的细节）——**6.1 源码不在本工作区**，本文按 Rockchip BSP 通用做法推断其构成，需 Step 0 从外部取回后核实。
- `DMA engine initialization failed` 的精确触发条件需上板 `dmesg` 确认（推断为"无 SGMII 通路导致链路/时钟未就绪"的次级症状）。

---

## 2026-08-11 方案调研结论（两个可行路线）

> **以下为更新结论。以前述章节为准的冲突处，以后者（本章节）为准。** 2026-08-11 对归档 worktree 与上游社区做了进一步调研，确认了两条可行实现路线（本节内容压倒并细化前述方案 2 中"6.1 源码不可得"的不确定性——6.1 BSP 内联 XPCS 实现已从归档 worktree 确认完整保留）。

### 路线甲：6.1 BSP 内联 XPCS（已从归档 worktree 确认实现）
- 来源：`/home/steven/src/rockchip_rk3568_linux_mainline-archived-kernel-6.1/patches/kernel/`（该 worktree 未检出 kernel 源码，但补丁完整保留实现）。
- 关键补丁：
  - `112-arm64-dts-rockchip-rk3568-Add-xpcs-support.patch`：rk3568.dtsi 加 `pclk_xpcs` 时钟；rk356x.dtsi 加 `xpcs: syscon@fda00000`（compatible "rockchip,rk3568-xpcs","syscon"，reg 0xfda00000 0x200000，默认 disabled）。
  - `113-ethernet-stmicro-stmmac-Add-SGMII-QSGMII-support.patch`：dwmac-rk.c 内联全部 XPCS/SGMII 逻辑（+217/-11）：新增 `set_to_sgmii`/`set_to_qsgmii` ops、`struct regmap *xpcs` 字段、`pclk_xpcs` 时钟、`xpcs_setup()` 配置 Clause-37 AN（VR_MII_AN_CTRL、SR_MII_BASE(0x1F0000)/SR_MII1_BASE(0x1A0000)）、`rk3568_set_to_sgmii` 写 GRF GMII_MODE + xpcs_setup、`syscon_regmap_lookup_by_phandle(...,"rockchip,xpcs")`。
  - `011–018 net/phy Motorcomm*`：yt8521/yt8531 SGMII 模式支持。
- 机制：gmac0 `phy-mode="sgmii"` + `phys=<&combphy2 PHY_TYPE_SGMII>`（NANENG combphy2，`CONFIG_PHY_ROCKCHIP_NANENG_COMBO_PHY=y`）+ `rockchip,xpcs=<&xpcs>` + `phy-handle=<&sgmii_phy>`（Motorcomm，`CONFIG_MOTORCOMM_PHY=y`）；运行期内联 XPCS 直操 APB 寄存器。
- 代价：整套内联 XPCS 是厂商代码，非主线风格，移植维护负担大、上不了主线。作为寄存器机制参考（蓝本）。

### 路线乙：上游 Coia Prant「net-next: add basic support for RK3568 XPCS」v2 系列（推荐）
- 状态：上游评审中（lore/patchwork），RFC 2026-07-14、v2 2026-08-01，10 补丁；**专为 Ariaboard Photonicat 开发**，作者在 Photonicat + Motorcomm YT8521 + Armbian trixie + 6.18 内核实测通过（拿 IP/SSH/ping）。
- 链接：
  - 封面信：https://lore.kernel.org/linux-rockchip/?q=s%3A%22net-next%3A+add+basic+support+for+RK3568+XPCS%22
  - RFC patchwork：https://patchwork.kernel.org/project/linux-rockchip/list/?series=1127656&state=*&archive=both
  - 先决补丁（已合入 stable 6.6.148/6.12.101）：`net: pcs: xpcs: fix SGMII state reading`，6.12 基线可回取。
  - 历史遗漏尝试（2022 amadeus `stmmac: Add SGMII/QSGMII support for RK3568`）未合入：https://lore.kernel.org/all/20221129072714.22880-2-amadeus@jmu.edu.cn/
- 机制：新增 `drivers/net/pcs/pcs-xpcs-rk.c`（约 538 行）+ `include/linux/pcs/pcs-xpcs-rk.h`——在 XPCS APB3 寄存器块（syscon@fda00000）上虚拟出 MDIO 总线并做地址重映射，把 PCS 配置交给**通用 `drivers/net/pcs/pcs-xpcs.c` 核心**（phylink_pcs_ops）。stmmac 核心新增 `pcs_init/pcs_exit` 回调（改 stmmac_mdio.c/dwmac-intel.c）。naneng-combphy 新增 `rockchip,sgmii-mac-sel` 属性选 MAC 路径（默认=1→GMAC1，Photonicat 需 GMAC0）。SGMII 用 in-band 模式、禁用通用 stmmac `set_clk_tx_rate`（MAC 时钟固定 125MHz）。DTS：SerDes/时序挂 XPCS 节点，板级 gmac0 `phy-mode="sgmii"`+`pcs-handle`+`phy-handle`。
- 优点：标准 pcs-handle 方案，不用移植 BSP 那套内联 XPCS；已被同板实测；不偏离主线。
- 代价/风险：系列仅 v2 未合入、接口可能再变；面向较新 master（~v7.2），6.12 回移需手动解决 API 演进（stmmac 核心、pcs-xpcs、pcs-xpcs-plat 若 6.12 没有需先并入）。

### 推荐路线
- **短期（当前 6.12 阶段，需尽快用双网口）**：回移路线乙 v2 系列到 6.12，重点回归 in-band 125MHz 时钟配置；以 BSP 路线甲为寄存器机制对照。估算 1000+ 行增量（stmmac+pcs-xpcs+combphy+dwmac-rk+DTS）。
- **不急于上双网口**：等该系列合入主线后整体升级内核（与阶段三内核升级方向一致），代价最低。
- **兜底**：在此期间使 `&gmac0` 置 disabled 或去除 SGMII，保证系统干净、避免误判。

### 下一步具体动作
1. 从 lore 下载 v2 整套 mbox 审阅（重点补丁 01/06/07/08/09）。
2. 与 6.12 树比对 API 差异：stmmac_mdio.c 的 XPCS 创建点、pcs-xpcs.c 接口、确认 6.12 是否有 Serge Semin 的 `net: pcs: xpcs: add xpcs-plat` 基础。
3. 落地文件：`drivers/net/pcs/pcs-xpcs-rk.c`（07）、`dwmac-rk.c` SGMII 接插（08）、`rk3568-photonicat.dts`（09）。
4. BSP 寄存器对照：rockchip-linux/kernel `develop-6.1` 分支 dwmac-rk.c + phy-rockchip-naneng-combphy.c。
