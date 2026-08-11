# Photonicat v1 看门狗修复与内核化（photonicat-pm）技术规划文档

> 项目：rockchip_rk3568_linux_mainline
> 路线：主线内核 6.1.106 + debootstrap 自建 Debian（rootfs 已升级到 trixie / Debian 13）
> 目标机器：Photonicat 一代（RK3568）
> 状态：**最终闭环（2026-08-11）——Phase 0/1/2 + 三项开放项（板温 / feed_interval / 时间对齐）全部实机解决，本文档作为落地记录留存，不再处于规划期**

---

## 目录

1. [背景与目标](#一背景与目标)
2. [现状盘点（已确认事实）](#二现状盘点已确认事实)
3. [两条路线对比与决策建议](#三两条路线对比与决策建议)
4. [实施计划（Phase 0 / 1 / 2）](#四实施计划phase-0--1--2)
5. [风险与决策点清单](#五风险与决策点清单)
6. [参考材料清单](#六参考材料清单)

---

## 一、背景与目标

### 1.1 问题来龙去脉：MCU 看门狗 60 秒重启 / 120 秒断电

烧录自建镜像后，Photonicat 一代出现周期性"黑屏重启 + 断电"：

- **60 秒黑屏重启**（电源灯亮）：板载 MCU 软件看门狗默认开启、超时 60 秒。
- **120 秒断电**（电源灯灭）：超过看门狗窗口后硬件断电保护。

根因链路：

1. MCU 看门狗靠"**1 秒内收到主机数据**"维持；
2. 喂狗者本应是用户态 **pcat-manager**，每 1 秒经 `/dev/ttyS4`（115200，UART 帧 `0xA5 + CRC16 + 0x5A`，心跳命令 `0x1`）发送心跳；
3. 用户态 pcat-manager 原为**闭源二进制**，链接 `libgpiod.so.2`；
4. 自建 rootfs 已升级到 **trixie（Debian 13）**，trixie 只提供 `libgpiod.so.3`；
5. 二进制因缺 `.so.2` **启动即失败** → 心跳线程从未运行 → 看门狗无人喂 → 周期性重启/断电。

### 1.2 本会话已完成的重编译修复（userland 路线）

为恢复喂狗，已对 pcat-manager v1 源码做了一次**用户态最小修复**：

- 来源：`photonicat/rockchip_rk3568_pcat_manager` 分支 `v1`，commit `6f16e4a`；
- 改动：`src/modem-manager.c` 移植到 **libgpiod v2 API**（新增 3 个 helper、`gpiochipN → /dev/gpiochipN` 归一化、保留软件层 active-low 语义）并交叉编译（链接 `libgpiod.so.3`）；
- 产物：替换了 `rootfs/overlay-debian|ubuntu/usr/local/bin/pcat-manager`；
- 移植改动已推送到 fork：`github.com/Heliopause0916/rockchip_rk3568_pcat_manager`，分支 `libgpiod-v2-port-for-trixie`，commit `b21e18c`；
- **用户正在板上验证此重编译版能否先解决看门狗问题。**

### 1.3 目标

| 目标 | 说明 | 优先级 |
|------|------|--------|
| **短期（眼前）** | 验证重编译后的 v1 用户态 pcat-manager 能否独立解决看门狗问题 | 高 |
| **中期（可选/后续）** | 走**内核化**路线：内核 serdev 驱动 photonicat-pm 接管 UART/心跳/看门狗/电源状态，用户态退化为经 `/dev/pcat-pm-ctl` 下发配置 | 中 |
| **长期（可选）** | modem 通道迁移（libgpiod → 内核 DTS rfkill-gpio + ModemManager），完全与 v2 架构同构 | 低 |

> 明确结论：**路线 A（用户态重编译验证）与路线 B（内核化）不是二选一，而是先后关系。** 眼前必须先做 A 的验证；B 是更正规的后续演进。

---

## 二、现状盘点（已确认事实）

> 本节全部来自本项目的深入源码调查，均已核实；个别标注 `[待验证]`。

### 2.1 用户态 pcat-manager（v1，分支 `v1`）功能清单

**串口 PMU 通道（`pmu-manager.c`，经 `/dev/ttyS4`）**

| 编号 | 功能 | 命令 | 触发方式 |
|------|------|------|----------|
| 1 | 心跳喂狗 | `0x1` | 每 1 秒周期 |
| 2 | 看门狗超时设置 | `0x13` | 事件驱动，非周期：init 一次 `{60,60,5}`、reboot 前 60、SIGUSR1 禁 0 |
| 3 | 电量/状态采集 | `0x7` | 周期/查询 |
| 4 | RTC 时间同步 | `0x9` | 双向、**事件驱动**：首次 MCU→host `settimeofday`；此后 host→MCU 当相差 >60s；**不依赖 hwclock/ntp，会绕过 rootfs 的 ntpsec** |
| 5 | 关机/重启 | `0xF` | 事件 |
| 6 | 自动关机策略 | — | 按电压阈值 |
| 7 | 开机原因查询 | `0x1B` | 事件 |
| 8 | 电压→% 换算 | — | conf 电池表 |
| 9 | 写 `/run/state/.../Battery` 与 `/dev/fake_battery` | — | 供显示 |
| 10 | 定时开机 | `0xB` | 事件 |
| 11 | 充电自动开机 | `0x15` | 事件 |
| 12 | 电压阈值下发 | `0x17` | 事件 |
| 13 | 网络状态 LED | `0x19` | 事件 |
| 14 | 固件/硬件版本读 | `0x5 / 0x3` | 事件 |

**modem GPIO 通道（`modem-manager.c`，经 libgpiod）**

- 控制：modem 电源 `power` / 射频 `rfkill` / 复位 `reset`。
- **上电时机**：`STATE_NONE` 分支启动即无条件 `power_init`（modem 存不存在都先上电）；**下电仅进程退出/关机**。
- 外部触发：rfkill 可经 `/tmp/pcat-manager.sock`（controller，**无鉴权 Unix socket**）命令 `modem-rfkill-mode-set`；power/reset 无外部通道。
- modem 为常驻线程（约每 1 秒轮询；5G 失败每 5s 自动复位）。

**启动参数与裁剪性（重要约束）**

- 只有 `-D/--daemon` 与 `--distro`（跳过 OpenWRT 网络检测）。**无 `--no-xxx` 开关**。
- 配置文件（conf）只有参数设定（`SerialDevice`/`SerialBaud`/`Battery*Table`/`AutoShutdownVoltage*` 等），**无功能开关**。
- `main()` **无条件**调 `pcat_pmu_manager_init()`（无条件 `open /dev/ttyS4` + 挂 1 秒心跳 + 看门狗 5s + 电压阈值等），随后进 `g_main_loop_run` 常驻。
- **因此"只做配置下发 + modem"无法靠参数/conf 裁剪，必须改源码。**

### 2.2 内核侧 photonicat-pm 模块（`mods/photonicat-pm.c`，分支 `v1`）

- 是内核 **serdev 驱动**（`compatible = "photonicat-pm"`）。
- 能力：自读串口、自喂心跳（hrtimer 每 1s 发 `0x1`）、init 时发看门狗 `0x13`、注册 `power_supply`（battery/charger）、RTC（`devm_rtc`）、hwmon 温度、`sys_off`（关机/重启）、misc 设备 `/dev/pcat-pm-ctl`。
- **`/dev/pcat-pm-ctl` 目前 read/write 是空桩 `return 0`，未实现写路径（关键硬约束）。**
- 需要 DTS 在 uart 下加 `compatible = "photonicat-pm"` 的 serdev 子节点。
- 可作 out-of-tree 模块或内建。

**对 6.1.106 的编译核验结果**：

- 唯一编译错误：`pcat_pm_uart_serdev_receive_buf()` 返回类型应为 `int`（6.1 的 `serdev_device_ops.receive_buf` 是 `int (*)(...)`），源码写成 `size_t`；改 1 行 `size_t → int` 后 **out-of-tree 编译成功、40 个符号全部解析、生成 `photonicat-pm.ko`**。
- 所需 config（`CONFIG_SERIAL_DEV_BUS=y`、`POWER_SUPPLY=y`、`HWMON=y`、`RTC_CLASS=y`）**本仓库已开启**。
- 无需其它 API 移植。
- **注意：双通道互斥**——内核 serdev 一旦绑定 uart，用户态就 `open` 不到 `/dev/ttyS4`。

### 2.3 v2（Photonicat 二代，RK3576）官方架构（对标）

- 用户态 pcat-manager 的 `master` 分支对应 **v2**（README 明确 "for photonicat v1 use v1 branch"）；v2 内核仓库 `rockchip_rk3576_linux_mainline` 以补丁带 photonicat-pm 驱动。
- **v2 分层**：
  - 内核 `photonicat-pm` serdev 驱动**独占 UART**，内建心跳/看门狗/RTC/电量充电/power_supply/温度风扇/hwmon/thermal/关机重启/sys_off；
  - 注册 misc 节点 `/dev/pcat-pm-ctl` 做**白名单过滤转发**：内核自行管理的命令（`HEARTBEAT`/`STATUS_REPORT`/`DATE_TIME_SYNC`/`HOST_REQUEST_SHUTDOWN`/`WATCHDOG_TIMEOUT_SET`/`FAN_SET`）被吞掉；仅 `default` 分支的厂商命令被 serdev 原样转发到 MCU——定时开机 `0xB`/充电自动开机 `0x15`/电压阈值 `0x17`/网络 LED `0x19`/开机事件 `0x1B`/`STATUS_LED_BEEPER_V2 0x9B`/`POWER_ON_MODE_V2 0xA1`/充电阈值 `0xA5 0xA7`/FW 版本 `0x5`；
  - 反向也过滤：内核自消耗的帧不回传。
  - 看门狗超时 `0x13` **由内核自己发**。
- **v2 用户态 pcat-manager**（仍常驻，仍只有 `--distro/--daemon` 参数，无 `--no-xxx`）：
  - 不再 open `/dev/ttyS4`，**改 open `/dev/pcat-pm-ctl` 下发厂商私有配置**；
  - 从 `sysfs/power_supply/hwmon` 读遥测；
  - 仍做关机策略决策（定时开关机/自动关机/电压阈值切换）→ 触发 `poweroff`（由内核 `sys_off` 转 `HOST_REQUEST_SHUTDOWN`）；
  - modem **完全不用 libgpiod**，改用内核 DTS `rfkill-gpio`（`rfkill-usb-wwan`）+ `gpio-hog` 固定电平 + ModemManager + `rfkill block/unblock wwan` + quectel-cm/fm350-mm.py；
  - 仍提供 `/tmp/pcat-manager.sock` 服务。
- **v2 的 service 依然存在且常驻**：`ExecStart=--distro`、`Type=simple`、`Restart=always`、`WantedBy=multi-user.target`（**不是 oneshot**）。
- **v2 仓库 `mods/photonicat-pm.c` 是完整可外置编译驱动**，通过 **`pm-version` 属性区分 v1/v2 电池属性表**，即**同一份驱动可跑 v1**。

### 2.4 对本项目迁移 v1 的关键结论

1. **v1 当前 photonicat-pm 是空桩**（`/dev/pcat-pm-ctl` 未实现写路径）——这是**最大硬约束**：需把完整版驱动（v2 的 `mods/photonicat-pm.c` 或 v1 的现成模块）并入/装到 v1 内核，并**补齐 ctl 写路径语义**。
2. **迁移方向与 v2 完全同构**：内核接管串口/心跳/电源状态 + pcat-manager 保留但经 `/dev/pcat-pm-ctl` 下发配置（需先补 ctl）+ modem 可迁 DTS rfkill-gpio + ModemManager（非必须，也可保留 v1 用户态 libgpiod 控制，但那样与 v2 不完全一致）。
3. **纯"加 `--no-xxx` 开关裁剪"并非官方路线**。官方路线是"能内核接管的就内生化，剩下的常驻"。
4. 用户态若与内核**共用同一 uart，必须停用旧 v1 用户态心跳**（否则抢串口）。
5. **何时该走内核路线**：先等用户在板上确认"重编译后的 v1 pcat-manager（用户态）能否独立解决看门狗问题"。若用户态方案已足够，内核化可作为"更正规/更省发行版依赖"的后续优化；若用户态不可行，则内核化是必需。

### 2.4.1 用户进行电源自定义配置的关键途径（接口清单）

> **导语**：本仓库走主线内核 + 自建 Debian 路线，**不构建 OpenWrt 专用的 pcat-manager-web**（其强绑定 `uci/ubus/opkg/LuCI/board.json` 等，无法直接跑在自建 Debian 上）。但它与 pcat-manager 之间的 `/tmp/pcat-manager.sock` 命令协议**本身与发行版无关**，可在 Debian 上直接对接复用。

"用户进行电源自定义配置"的两种落地形态：

| 形态 | 底层通道 | 配置入口 | 说明 |
|------|----------|----------|------|
| ① v1 现状（路线 A） | pcat-manager 直接 `open /dev/ttyS4` | conf 文件 + socket 命令触发 | 当前板上正在验证的形态 |
| ② 内核化后（Phase 2，与 v2 同构） | pcat-manager 改经 `/dev/pcat-pm-ctl` 下发 | socket 命令协议**不变**，仍为外部触发入口 | 也可用纯 Flask 前端只对接 socket，不引入 OpenWrt 依赖 |

> ⚠️ **途径① 已失效（双通道互斥）**：内核 `photonicat-pm` 驱动经 serdev 绑定 uart4 后，将**独占**该端口（`devm_serdev_device_open`），用户态 pcat-manager **不能再 open `/dev/ttyS4`**。内核化落地后，途径① 不再可用，用户态与内核的唯一交互通道改为 `/dev/pcat-pm-ctl`（见下面途径③）。

**途径① —— 配置文件（v1 现状，最直接，⚠️ 内核化后失效）**

| 配置项 | 文件 / 字段 | 生效方式 |
|--------|-------------|----------|
| 定时开机 / 充电自动开机 | `/etc/pcat-manager-userdata.conf`：`[Schedule] EnableBitsN/DateN/TimeN/DOWBitsN/ActionN`；`[General] ChargerOnAutoStart` | 重启 pcat-manager 服务后 init 自动下发（定时开机 `0xB`、充电自动开机 `0x15`） |
| 电压 / 电量阈值 | `/etc/pcat-manager.conf`：`[PowerManager]` 的 `StartupVoltage` 等（LED 高中低、启动/充电/关机/快充电压、电池满阈） | 重启服务生效（`0x17`）；另有运行时按 modem 功耗等级动态重下发 `AutoShutdownVoltage*` |
| 网络状态 LED | `0x19` | 运行时按路由模式变化**自动发**（非启动下发） |

> 注：systemd 服务只负责拉起 daemon，**不承载设置操作**（`pcat-manager.service`，`ExecStart=pcat-manager --distro`）。

**途径② —— `/tmp/pcat-manager.sock`（Unix socket，发行版无关，推荐对接）**

- 通道：AF_UNIX `SOCK_STREAM`，地址 `/tmp/pcat-manager.sock`，命令为 **JSON + `'\0'` 结尾**。
- 与电源自定义配置相关的命令（来自 v1 `controller.c`）与含义：

| 命令 | 功能 | 说明 |
|------|------|------|
| `schedule-power-event-set/get` | 读写定时开关机事件列表 | `action` 0=关机、1=开机；`enable-bits/dow-bits` 描述年月日时分星期；**写后即时触发 `0xB` 下发**并持久化回 userdata |
| `charger-on-auto-start-set/get` | 充电自动开机 / 车载模式 | `state` + `timeout` 延时分钟；**写后即时触发 `0x15` 下发** |
| `power-on-mode-get/set` | 开机模式 | 0=手动、1=自动开机、2=直连电源/忽略电量。*注：该命令形式参考 v2/pcat-manager-web，v1 controller 是否已提供需标注 `[待验证]`* |
| `charge-threshold-get/set` | 充电上限阈值 | 如 80–100。*同上，`[待验证]`* |
| `pmu-io-get/set` | 状态 LED / 蜂鸣器 | `status-led-v2` / `beeper` |
| `pmu-status`（只读） | 电池/充电电压、电量、板温 | — |
| `pmu-fw-version-get`（只读） | 固件版本 | — |

> 说明：此 socket 上还有 `modem-*`、`network-route-mode-get` 等**非 PMU 命令**，一并走同一通道。

**途径③ —— `/dev/pcat-pm-ctl`（仅内核化 Phase 1/2 后可用）**

- v1 当前为**占位空桩**（`read/write` `return 0`），Phase 1.5 需补齐**白名单转发**：用户态写入的厂商命令（`0xB/0x15/0x17/0x19/0x1B/0x5`）经 serdev 转发到 MCU，内核自消耗命令（心跳/状态/时间同步/看门狗超时）被吞。
- 内核化后**完整链路**：

```
用户（脚本 / 纯Flask前端 / 手调socket）
   → /tmp/pcat-manager.sock
   → pcat-manager 常驻守护进程
   → write /dev/pcat-pm-ctl
   → 内核 photonicat-pm 驱动（白名单过滤）
   → UART/serdev
   → MCU
```

**看门狗 `0x13` 帧参数语义**（由内核驱动在 init 时自己下发）：

- 参数三元组语义为 `{timeout_boot, force_poweroff_timeout, feed_interval}`，本项目的规划语义为 `{60, 60, 5}`。
- 其中 `force_poweroff_timeout` 由 DTS 中 `pcat-pm` 子节点的 `force-poweroff-timeout` 属性提供（**默认 60**）；`timeout_boot` / `feed_interval` 为驱动内规划常量（60 / 5）。

**⚠️ 原子落地（deploy safety）建议**：

- **纯内核侧单独落地不安全**：内核 serdev 驱动与用户态 pcat-manager 会**同时写 uart4**，双协议栈抢线会造成帧损坏 / 看门狗复位。内核驱动、用户态切换到 `/dev/pcat-pm-ctl`、停用其 ttyS4 采集路径（即 Phase 2），**必须在同一个镜像内原子落地**，不可只先上内核侧。
- **落地顺序与依赖**：确认目标 rootfs 上运行了 `depmod`（生成 `modules.alias` / `modules.dep`）以支持 serdev OF-modalias 自动加载；确认 `modprobe photonicat-pm` 能加载、`/dev/pcat-pm-ctl` 出现、驱动已喂狗后，**再停用用户态 ttyS4 路径**，避免喂狗空窗。
- **关键停用点**：`rootfs/rootfs-debian-custom/etc/pcat-manager.conf:13` 的 `SerialDevice=/dev/ttyS4` 是 Phase 2 必须停用的关键配置。

**一句话总结**

> 在自建 Debian 上，用户实现自定义电源配置的两个可落地入口：① **改 conf 文件 + 重启服务**（v1 现状，**内核 serdev 绑定 uart4 后即失效**）；② **向 `/tmp/pcat-manager.sock` 发送 JSON 命令**（发行版无关、推荐，且是 Web/脚本前端统一对接点）。内核化后底层改为经 `/dev/pcat-pm-ctl`，**socket 命令协议保持兼容**、作为外部触发入口不变。

---

## 三、两条路线对比与决策建议

### 路线 A：保持用户态 pcat-manager（libgpiod v2 移植，已做）

| 维度 | 说明 |
|------|------|
| 现状 | 已完成的 libgpiod v2 移植（commit `b21e18c`），产物已在 rootfs overlay；正在板上验证 |
| 目标 | **立即验证看门狗修复**（Phase 0），先解决 60s/120s 重启断电 |
| ✅ 优点 | 改动小、已基本完成；不碰内核/DTS；串口心跳、RTC 双向同步、modem GPIO 全部维持 v1 原语义；风险面小 |
| ❌ 缺点 | 仍依赖用户态常驻 daemon + libgpiod v2 运行时；trixie 主机侧依旧有 `.so` 运行时耦合（但已解决）；UART 由用户态独占，未享受内核 serdev 的能力（电池/温度/sys_off 等内建）；长期仍受"用户态崩溃即失喂狗"风险 |
| 触发/阻塞 | **无阻塞**，是当前唯一应执行的验证 |

### 路线 B：内核化（photonicat-pm 完整模块接入 v1 + 用户态经 ctl 下发配置）

| 维度 | 说明 |
|------|------|
| 目标 | 与 v2 官方架构同构：内核内建心跳/看门狗/RTC/电源/温度/关机；用户态退化为配置下发 + 遥测读取 |
| ✅ 优点 | 喂狗、看门狗、电源状态不再依赖用户态进程存活（更稳）；内建 RTC/power_supply/hwmon/sys_off；与 v2 架构一致，便于后续复用 v2 的驱动与演进；可逐步摆脱 libgpiod 依赖 |
| ❌ 缺点 | 改动显著：需合入完整驱动（v1 当前是空桩）、DTS 加 serdev 节点、补 `/dev/pcat-pm-ctl` 写路径、停用旧用户态心跳；**双通道互斥**需严格验证；UART 独占后无法再让用户态直接访问；开发/调试成本高 |
| 阻塞 | 依赖 Phase 0 结果；依赖"空桩 ctl 补写"的实现复杂度评估（见风险节） |

### 决策建议

- **眼前**：执行 **路线 A（Phase 0）**，在板上验证重编译 v1 pcat-manager 能独立喂狗 ⇒ 判定标准见 4.1。
- **后续**：无论 A 是否成功，内核化（Phase 1/2）都是**更正规的方向**。若 A 成功，B 可作为优化（收益：抗用户态崩溃、内建电源/温度/RTC）；若 A 失败（用户态在 trixie 上仍不可行），则 **B 是必需路径**，立即启动。

> **触发内核化（进入 Phase 1）的具体条件**：
> 1. 用户在板上确认 A 结果（成功/失败）已给出；
> 2. 有明确意愿投入 DTS + 内核补丁 + ctl 写路径的开发；
> 3. 接受串口由内核独占、用户态经 ctl 交互的新形态。

> **结论（2026-08-10）**：路线 B（内核化）已实施并上板验证通过，本仓库已转为主线的内核 photonicat-pm + 用户态经 `/dev/pcat-pm-ctl` 下发配置的形态；原「暂不执行」状态作废。

---

## 四、实施计划（Phase 0 / 1 / 2）

> 每步均含：**产出 / 命令 / 验收标准 / 风险 / 是否阻塞决策点**。

### Phase 0：板上验证重编译后的 v1 pcat-manager 是否修复看门狗

**目标**：确认路线 A 是否成立——重编译版能否独立喂狗、消除 60s/120s 重启断电。

| 项 | 内容 |
|----|------|
| 前置 | 板上已烧录含重编译 pcat-manager（libgpiod v3 链接）的 rootfs |
| 产出 | 板上喂狗是否正常的判定结论 |
| 命令（示例） | ① `systemctl status pcat-manager`（确认 daemon 常驻、未崩溃）；② `ldd /usr/local/bin/pcat-manager`（确认链接到 `libgpiod.so.3`、无缺库）；③ 观察串口收发：`strace -f -e trace=read,write -p $(pidof pcat-manager)` 或抓 `/dev/ttyS4` 心跳帧（每 1s 一个 `0xA5...0x5A`，命令 `0x1`）；④ 观察板子是否仍在 60s 后黑屏重启、120s 断电；⑤ 看门狗设置帧：init 时 `0x13 {60,60,5}` 已下发 |
| 验收标准 | ① daemon 稳定运行数小时无崩溃；② 无缺 `.so` 依赖错误；③ 串口每 1s 可见心跳帧；④ **60s 不再重启、120s 不再断电**（连续运行 >20 分钟观察）；⑤ 无 `libgpiod.so.2` 相关报错 |
| 风险 | trixie 环境下仍有其他缺库/运行期问题；libgpiod v2→v3 在板上运行期语义（active-low 处理）与预期不一致 `[待验证]`；modem 上电逻辑（`power_init` 无条件上电）在新环境下的副作用 `[待验证]` |
| 阻塞决策点 | **是。** 本 Phase 结果直接决定是否进入 Phase 1（内核化）：A 成功 → B 可选优化；A 失败 → B 必需 |

---

### Phase 1（可选，路线 B 第一步）：内核 photonicat-pm 接入 v1

**目标**：让内核 serdev 驱动接管 /dev/ttyS4 + 心跳 + 看门狗 + 电源状态；为用户态退化为 ctl 下发铺路。

> **✅ 已完成（见实测结论节）**：Phase 1 各部分（驱动合入 / DTS serdev 节点 / 停用旧心跳 / 装 .ko / ctl 写路径）均已实施并上板验证通过，验收标准见「五.五、实测结论」。

| 步骤 | 任务 | 产出 | 命令/方式 | 验收标准 | 风险 |
|------|------|------|-----------|----------|------|
| 1.1 | **合入完整驱动源码**：以 v1 `mods/photonicat-pm.c` 为基础，参照 v2 `mods/photonicat-pm.c` 补齐能力（尤其 `/dev/pcat-pm-ctl` 写路径）；修正 `receive_buf` 返回类型 `size_t → int` | 可独立编译的 `photonicat-pm.ko` 源码（本仓库 kernel 侧或 out-of-tree 构建目录） | 6.1.106 O=build 溢出构建；或 out-of-tree `KERNELDIR=build make` | 编译通过、40 符号全解析、生成 `.ko`；无 `.rej/.orig` 残留（见风险） | 补写路径复杂度高（见 5）；v1 空桩与 v2 完整版差异需逐项核对 |
| 1.2 | **DTS 加 serdev 子节点**：在 uart4 下加 `compatible = "photonicat-pm"`、`pm-version = <1>` 的子节点 | 更新后的本仓库 DTS（内建时）或 overlay | 编辑 DTS 后重编译 dtb | 设备树在 uart4 下出现 `photonicat-pm` 子节点；`/sys/bus/serial/devices` 出现绑定；`photonicat-pm.ko` 成功 probe | DTS 节点结构/reg 与 6.1 serdev 适配 `[待验证]` |
| 1.3 | **停用旧 v1 用户态心跳**：因双通道互斥，用户态不能再 open `/dev/ttyS4` | 修改后的用户态逻辑或撤下旧心跳路径（source 层） | 改源码去除 `pcat_pmu_manager_init()` 的串口心跳/看门狗路径，或由 service 侧配合 | 重启后 `/dev/ttyS4` 被内核占用，用户态无 `open` 失败告警/不抢串口；**无双通道并发写** | 停用不当会导致双方都发帧 → 协议错乱；需保序 |
| 1.4 | **编译安装 `.ko`**（可内建或 module） | 装机可见的 `photonicat-pm.ko`，开机自动加载 | `modprobe photonicat-pm`；开机模块列表/内建 | 开机后串口由内核独占、心跳每 1s 自发、`0x13 {60,60,5}` init 已发、`power_supply`/`hwmon`/RTC 节点出现；看门狗不再重启/断电 | 驱动 auto-probe 时序；与用户态残留进程竞争 `[待验证]` |
| 1.5 | **补齐 `/dev/pcat-pm-ctl` 写路径语义**（参考 v2 白名单转发）：用户态写入 → 属内核管理的命令被吞、属厂商命令原样转发到 MCU；反向过滤 | ctl 具备可用读写语义 | 实现 ctl `.write`/`.read` 白名单转发；参照 v2 `mods/photonicat-pm.c` | 用户态可经 ctl 下发 `0xB/0x15/0x17/0x19/0x1B/0x5` 等厂商命令并被内核转发到 MCU；内核自消耗命令（心跳/状态/时间同步/看门狗）写人不响应 | 白名单映射表需与 v1 MCU 固件命令集精确对齐 `[待验证]` |

> **阻塞决策点**：Phase 1 完成后，用户态仍以旧形态常驻、且不能直接访问串口，因此**必须与 Phase 2 的用户态改造联调**；Phase 1 单点完成只能验证"内核能否独立维持看门狗与电源状态"。

---

### Phase 2（可选，路线 B 第二步）：用户态 pcat-manager 切换 + modem 迁移 + service 形态

**目标**：与 v2 完全同构——用户态经 `/dev/pcat-pm-ctl` 下发配置、从 sysfs/power_supply/hwmon 读遥测；modem 可选迁内核；service 形态定型。

> **✅ 已完成（见实测结论节）**：Phase 2 各部分（用户态经 ctl 下发 / 遥测读取 / service 形态）均已实施并上板验证通过，验收标准见「五.五、实测结论」；仅 modem 迁移（2.2）与 v2 不完全同构，见「遗留开放项」。

| 步骤 | 任务 | 产出 | 命令/方式 | 验收标准 | 风险 |
|------|------|------|-----------|----------|------|
| 2.1 | **用户态改为经 ctl 下发**：移走 open `/dev/ttyS4` 的心跳/看门狗/采集路径，改为 open `/dev/pcat-pm-ctl` 下发厂商配置；从 `sysfs`/`power_supply`/`hwmon` 读遥测；保留关机策略决策（定时/自动关机/电压阈值）并触发 `poweroff`（经内核 `sys_off` 转 `HOST_REQUEST_SHUTDOWN`） | 改造后的 pcat-manager 源码 + 重编译产物 | 源码级改造（参照 v2 用户态）；交叉编译 | 启动后不开 `/dev/ttyS4`；`/dev/pcat-pm-ctl` 有正常下发；`/sys/class/power_supply`、`/sys/class/hwmon` 读到正确遥测；关机行为正确 | 用户态大量重构，需逐功能核对（尤其 RTC 双向同步、关机策略判定）`[待验证]` |
| 2.2 | **modem 迁移（可选）**：libgpiod → 内核 DTS `rfkill-gpio`（`rfkill-usb-wwan`）+ `gpio-hog` 固定电平 + ModemManager + `rfkill block/unblock wwan` | DTS modem 节点 + ModemManager 配置；用户态 modem 路径移除 | DTS + ModemManager 配置；移除 `modem-manager.c` 的 libgpiod 路径 | `rfkill wwan` block/unblock 生效；ModemManager 能枚举 wwan；无需 libgpiod | **可选**：不迁移也可保留 v1 用户态 libgpiod（但与 v2 不完全一致）；modem 供电时序（`power_init` 无条件上电）处理 `[待验证]` |
| 2.3 | **service 形态定型**：`Type=simple`、`Restart=always`、`WantedBy=multi-user.target`（常驻，参考 v2；**不是 oneshot**） | 更新后的 unit | 编辑 service 文件 | 系统启动时 pcat-manager 常驻；崩溃自动重启；`--distro` 参数正常 | service 与内核 serdev 的依赖序（需在串口驱动就绪后启动）`[待验证]` |
| 2.4 | **回归与清点**：删除不再使用的旧路径（如旧的串口心跳代码、libgpiod 依赖若已迁移）；核对无 `.rej/.orig` 残留 | 干净的最终状态 | 走完整构建 + 烧录 + 长时间运行 | 无 `.rej`；长时间无看门狗重启/断电；RTC/电池/温度显示正确；开机过程无报错 | 回归遗漏导致意外依赖 |

> **最终验收**：与 v2 架构同构的内核+用户态组合在 v1 板上稳定运行；看门狗、电源、RTC、温度、关机重启全部正常；无可观测的无喂狗重启/断电。

---

## 五、风险与决策点清单

| # | 风险/决策点 | 说明 | 决策/缓解 |
|---|-------------|------|-----------|
| 1 | **内核态与用户态共抢 UART 的互斥** | serdev 一旦绑定 uart，用户态 open 不到 `/dev/ttyS4`；若用户态仍尝试 open 会失败/冲突 | Phase 1.3 必须停用旧用户态心跳路径；严格保序迁移 |
| 2 | **ntpsec 与 RTC 同步冲突** | v1 用户态 RTC 同步事件驱动、绕过 ntpsec；内核化后 RTC 由内核 `devm_rtc` 管，与 rootfs ntpsec 可能互相覆盖 | 明确 RTC 同步责任边界（内核 or ntpsec or 用户态）；避免双向打架 |
| 3 | **空桩 ctl 补写的复杂度** | v1 当前 `/dev/pcat-pm-ctl` 为 `return 0` 空桩；补写白名单转发需与 v1 MCU 命令集/帧格式精确对齐 | 参照 v2 `mods/photonicat-pm.c` 的白名单实现；先确认 v1 MCU 固件命令集 `[待验证]` |
| 4 | **是否保留 libgpiod 依赖** | 路线 A 保留（已解决）→ 用 libgpiod v3；路线 B 若 modem 不迁移仍保留 libgpiod | 由 Phase 2.2 modem 迁移决策决定；如迁内核则可完全移除 |
| 5 | **service 是常驻还是 oneshot** | v2 是常驻（`Type=simple` + `Restart=always` + `WantedBy=multi-user.target`）；v1 若仅做"配置下发"也不建议 oneshot | 跟随 v2 定为常驻；注意需在串口/serdev 驱动就绪后才启动（依赖序） |
| 6 | **内核用户态版本差异** | v1 用户态源码、v2 用户态源码、驱动三者需版本匹配；v1 分支 vs master 分支语义不同 | 严格锁定分支/commit（v1 → 分支 `v1`，v2 → `master`） |
| 7 | **modem 迁移是否必须** | 迁内核 rfkill-gpio + ModemManager 是"与 v2 完全一致"所需；不迁移则保留 v1 libgpiod | 标记为可选；取决于"与 v2 完全同构"是否为硬要求 |
| 8 | **补丁应用静默失败** | 本项目历史教训：构建补丁应用失败会落入 `.rej` 被静默跳过，导致残缺产物烧上板 | 每次重编译后核验 `kernel/` 下无 `.rej/.orig` 残留（对应既有 corrections 记忆） |
| 9 | **libgpiod v2→v3 运行期语义** | 已移植到 v2 API 并链接 .so.3，但板上运行期的 active-low/line 请求语义需实机验证 | Phase 0 实机重点观察 modem GPIO 行为 `[待验证]` |

**主要风险实机闭环总结**：以下关键风险已在实机逐项闭环——① 双通道互斥已验证达成（内核 serdev 绑定 uart4 后 `/dev/ttyS4` 不再存在，用户态经 `/dev/pcat-pm-ctl` 正常下发）；② `0xF`/reboot 语义已澄清（`0xF` 仅属 poweroff，reboot 不发 `0xF`）；③ ctl 白名单转发已验证有效（FW 版本回读成功）；④ RTC 与 ntpsec 已确认无冲突（RTC 经 ntpsec 同步成功）。其余开放项（modem 迁移等）见下方「遗留开放项」。

---

## 五.五、实测结论（2026-08-10 实机验证通过）

> Phase 0/1/2 已在实机（RK3568，内核 6.1.106）上板验证通过，以下为关键实测结果。

**验证通过清单**

| 验证项 | 实测结果 |
|--------|----------|
| 模块加载 / serdev modalias 自动 probe | ✅ 模块开机自动加载，photonicat-pm serdev 自动绑定 uart4 并 probe 成功 |
| `/dev/pcat-pm-ctl` 存在且被用户态占用 | ✅ ctl 设备存在并成功打开；同时注册为 rtc0 |
| `/dev/ttyS4` 不存在（双通道互斥） | ✅ 板上已无 `/dev/ttyS4`，内核 serdev 独占 UART，双通道互斥达成 |
| ctl 白名单转发 + ACK 回读 | ✅ 白名单转发有效，PMU FW 版本回读成功（`RA2E1230523000`） |
| 喂狗不死机 | ✅ 连续喂狗 >20min 无 60s/120s 复位（uptime 1684s） |
| 电池校准值实测 | ✅ MIN 3450000 / MAX 4200000 / capacity 96 / voltage_now 4156000 / Charging |
| charger 在线 | ✅ charger 在线（5.02V） |
| RTC 经 ntpsec 同步 | ✅ RTC 经 ntpsec 同步成功 |
| poweroff 正常断电 | ✅ poweroff 正常断电（电源灯/网卡灯灭） |
| reboot 正常复位 | ✅ reboot 正常复位（网络中断后恢复） |

**关键语义说明（重要修正）**

> `0xF HOST_REQUEST_SHUTDOWN` **仅属 poweroff**。reboot 时内核重启处理器（`SYS_OFF_MODE_RESTART`）**不发 `0xF`**，仅发 `0x13`(interval=0) 禁看门狗 + 停 worker + 靠 SoC 自身复位——若 reboot 也发 `0xF` 会变成关机而无法重启，因此当前对 poweroff/reboot 的差异处理是正确设计，无需改动。

**遗留开放项（非阻塞）**

| # | 项 | 状态 / 说明 |
|---|----|-------------|
| ① | 板温/风扇读 0 | ~~判定为 MCU 未上报有效温度字节（data[17]=100），非内核 bug~~ → **已解决（2026-08-11）**：根因=内核温度守卫 `>=20` 过严 + 换算 `-100` 错位，实机 `len=18` / `data[17]=66~70`；改为守卫 `>=18` + 换算 `-40` 后 `pcat_pm_hwmon_temp_mb` 实测 37°C。详见「五.六」 |
| ② | `feed_interval` 实现值=10 | ~~是否改回 5 待上层拍板~~ → **已解决（2026-08-11）**：对齐官方用户态 v1（`watchdog_timeout_set(5)`），宏 10→5，uptime 正常无复位。详见「五.六」 |
| ③ | modem 仍用 libgpiod | 未迁移 DTS `rfkill-gpio`，与 v2 不完全同构，属范围外、非阻塞 |

---

## 五.六、开放项收尾结论（2026-08-11）

> 2026-08-11 针对前一日遗留的 3 项开放项（板温 / feed_interval / 时间对齐）做了定向排查与修复，全部实机验证通过并收尾。

| # | 开放项 | 根因排查 | 修复 | 实机验证 |
|---|--------|----------|------|----------|
| ① | 板温 / 风扇读 0 | 内核驱动温度守卫 `data_len>=20` 过严、且温度换算错误用二代 `-100` 偏移；实机抓帧为 `len=18`（一代完整帧，payload 到 data[17]），温度字节 `data[17]=66~70`，换算应为一代 `-40`（66-40=26°C 合理） | 温度守卫 `>=20`→`>=18`；换算 `-100`→`-40` | `pcat_pm_hwmon_temp_mb` 实测 **37000（37°C）**，不再为 0 |
| ② | `feed_interval` 实现值=10 | 规划注释写 `{60,60,5}`，内核宏实现为 10；官方用户态 v1 (`pmu-manager.c` L1659 `watchdog_timeout_set(5)`) 即走 5 | `PCAT_PM_WATCHDOG_DEFAULT_INTERVAL` 10→5 | uptime 持续运行无 60s/120s 复位 |
| ③ | 时间对齐（开机时钟卡在陈旧值 `2026-04-14`, 靠 ntpsec 事后约 1 分钟拨正） | `RTC_HCTOSYS`（约 7.8s）早于 MCU 首个 `0x7` 状态帧（约 8.7s），`read_time` 因 `status_report_received` 尚未置位返回 `-ENODATA`，hctosys 播种失败 → 每次开机时钟陈旧 | **方案 B**：`pcat_pm_status_report_parse` 收首帧、缓存 MCU RTC 字段后，若系统时钟落后 MCU RTC >300s 则 `do_settimeofday64()` 一次性播种（`clock_seeded` 只播一次、绝不倒退、不与 ntpsec 冲突）；新增 `struct pcat_pm_data::bool clock_seeded` 及 `<linux/time.h>/<linux/time64.h>/<linux/timekeeping.h>` include | dmesg 见 `pcat-pm: seeded system clock from MCU RTC (sec 1786417339)`（开机约 9s 即播种）；ntpsec 后续仅 `time stepped by 0.43s`（不再有 119 天大步进），服务 Active since 即正确时间，彻底消除开机陈旧窗口 |

**结论**：3 项开放项全部关闭，photonicat-pm 内核集成工作正式告一段落。当前内核改动累积：宏 feed_interval=5、read_time 有效性门禁、温度守卫 18 + `-40` 偏移、首帧 `do_settimeofday64()` 播种。

---

## 六、参考材料清单

**仓库 / 分支 / commit**

| 对象 | 位置 |
|------|------|
| pcat-manager 官方仓库 | `photonicat/rockchip_rk3568_pcat_manager` |
| v1 分支（本机用户态基准） | 分支 `v1`，commit `6f16e4a` |
| libgpiod v2 移植 fork | `github.com/Heliopause0916/rockchip_rk3568_pcat_manager`，分支 `libgpiod-v2-port-for-trixie`，commit `b21e18c` |
| 本改动具体文件 | `pcat-manager/src/modem-manager.c`（libgpiod v2 API 移植） |
| v2 架构参考 | pcat-manager `master` 分支；内核仓库 `rockchip_rk3576_linux_mainline`（补丁带 photonicat-pm 驱动） |
| v1/v2 内核驱动 | `mods/photonicat-pm.c`（v1 为空桩版；v2 为完整可外置编译版） |

**本地文件路径（本项目）**

| 文件 | 说明 |
|------|------|
| `kernel/` | 主线内核 6.1.106 源码（O=build 溢出构建） |
| `mods/photonicat-pm.c` | v1 内核 serdev 驱动（空桩版） |
| `rootfs/overlay-debian/usr/local/bin/pcat-manager` | 已替换的重编译用户态产物 |
| `rootfs/overlay-ubuntu/usr/local/bin/pcat-manager` | 同上（ubuntu overlay） |
| `rootfs/mk-rootfs-debian.sh` | rootfs 构建脚本（DEB_DISTRO=trixie） |
| `kernel/patches/` | 内核补丁目录（注意 `.rej` 残留核验） |
| `.kilo/` | 项目命令/agent/配置目录 |

**既有记忆/约定（本项目已确认）**

- libgpiod：trixie 无 `libgpiod.so.2`，用 `libgpiod.so.3`；`libgpiod2→libgpiod3` 包名变更。
- 补丁机制：应用失败会落入 `.rej` 被静默跳过，重编译后必须核验 `kernel/` 无 `.rej/.orig` 残留。
- RTC：rootfs 用 ntpsec；v1 用户态 RTC 同步绕过 ntpsec。

---

## 附：路线决策速览

```
[眼前] 路线 A（用户态 libgpiod v2 移植 —— 已做）
   └─> Phase 0：板上验证喂狗修复
          │
          ├─ 成功 → 内核化作为"更正规/抗崩溃/省依赖"的后续优化（可选实施）
          │
          └─ 失败 → 内核化是必需（立即进入 Phase 1）
[后续] 路线 B（内核 photonicat-pm 完整接入 v1）
   ├─ Phase 1：合入驱动 + DTS serdev 节点 + 停用旧心跳 + 装 .ko + 补 ctl 写路径
   └─ Phase 2：用户态经 ctl 下发 + 遥测读 sysfs/power_supply/hwmon + modem 可选迁移 + service 常驻定型
```

---

*文档状态：最终闭环（2026-08-11）。Phase 0/1/2 全部实施并上板实证通过；遗留开放项 ① 板温、② feed_interval、③ 时间对齐均已实机解决（见「五.六」）。本规划作为落地记录留存，不再处于规划期。*
