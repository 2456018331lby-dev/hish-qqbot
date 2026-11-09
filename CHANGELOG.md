# 更新日志

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号用 [语义化版本](https://semver.org/lang/zh-CN/)。

---

## [0.2.0] - 2026-11-09

「从能跑变成敢用」的一版：加入**崩溃自愈、一键修复、性能优化、流式模型代理、PC 侧编排**，并把「慢」的原因量化写进文档。
代码仍只有胶水脚本与文档，不包含任何被 hook / 被调用项目的源码。

### 新增

**看门狗与运维脚本**（虚机内 `/root/` 运行）
- `scripts/watchdog.sh` — 30 秒一轮巡检 **Xvfb / Linux QQ / SnowLuma / AstrBot**，崩了自动拉起；QQ 重启后 20 秒重挂 SnowLuma（重启必丢 hook）；AstrBot 有「6185 连续 20 次不通（约 10 分钟）才重启」的宽容期，避免把冷启动中的进程杀掉。状态写 `/root/watchdog.state`，事件写 `/root/watchdog.log`。
- `scripts/quick.sh` — 「一次过修复」：挂载 → 清 X 锁 → Xvfb → QQ → SnowLuma → AstrBot → 控制台 → vyceai 代理 → 看门狗 → OneBot 链路，共 8 个阶段自检，最后打印 `X=OK / QQ=OK / SnowLuma=OK / AstrBot=<code> / panel=<code> / watchdog=OK` 与负载/内存/nproc 体检快照。幂等，可反复跑。
- `scripts/optimize.sh` — 性能优化，幂等：① 预编译 AstrBot 与插件 `.pyc`；② 生成统一的 `/root/ubuntu/root/start_qq.sh`（收敛启动参数 + `--js-flags=--max-old-space-size=384` 限制 JS 堆）；③ 收敛 `provider_settings`（图生文默认 provider、关联网搜索）；④ 能设则设 `tcp_congestion_control=bbr` / `vm.swappiness=10`。

**模型适配**
- `scripts/vyceai_proxy.py` — 把 AstrBot 的**非流式**请求翻译成上游唯一接受的**流式**请求：监听 `127.0.0.1:8790` → 强制 `stream=true` 转发 → 把 SSE 增量拼回标准 `chat.completion` JSON。解决「中转站只吃 stream，直连必报 `invalid_request`」这一类问题。只能 bind 本机，上游基址/端口/超时可用 `UPSTREAM` / `PORT` / `TIMEOUT` 覆盖。

**控制台**
- `scripts/panel_v3.py`（**替代** `scripts/panel_v2.py`，部署名仍是 `/root/panel.py`，端口仍是 8080）— 在 v2 的「状态灯 / 模型开关 / 插件开关 / 人格编辑 / 唤醒前缀 / 一键重启」之上新增：首页**体检卡**（一句话给出 `全能聊 / 部分可用 / 未就绪`）、`/api/perf` 性能快照（核数/负载/内存/运行时长）、`/api/logs?name=ab|boot|sl|watchdog|quick` 看日志尾部、`/api/repair` 一键后台跑 `quick.sh`、`/quick` 维修页。已删除 `scripts/panel_v2.py`（历史仍可从 0.1.0 版本取回）。

**PC 侧工具**
- `tools/pc_bootstrap.py` — PC 侧一键编排：拉起 PC 三个服务（80 静态文件 / 8081 日志接收 / 8789 模型网关转发）→ 查 hdc 连接 → 通过 z2 通道下发 `quick.sh`（通道死了退化为 hdc 敲终端）→ 截图取证（平板屏 + VM 桌面）→ 打印体检报告。**只跑在 PC，不参与机器人运行，不含任何平板业务数据**；设备序列号/平板 IP/PC IP 一律走环境变量（`HDC_BIN` / `HDC_DEV` / `TABLET_IP` / `PC_IP` / `WWW_DIR`），仓库不写死个人环境。

**文档**
- `README.md` — 新增「**性能与稳定性**」（TCG 无 KVM 的天花板、8 个变慢原因与实测数字、看门狗自愈表、冷启动耗时对照、**「一次只开一个网页」操作纪律**）、「**模型对接的两种姿势**」（直连 OpenAI 兼容网关 vs 经 `vyceai_proxy.py` 走只接受流式的网关，含 `api_base` 指向哪里、怎么选）、「**截图**」小节（3 张脱敏真机截图；其中 02/03 是 **v2 控制台界面**，v3 的体检卡/性能/维修页截图待重拍，已在正文标注）；目录树补齐 5 个新文件与 `tests/`；已知限制补 4 条（8 vCPU 下 Electron QQ 易崩、中转站可能只支持 stream、PC 仅作工具链、2 小时稳定性未跑满）。
- `docs/architecture.md` — 组件图新增 `watchdog`（巡检自愈）与 `model-proxy`（模型适配）两个方框及连线；分层端口表补 8790；新增「**2.3 数据流：AstrBot → 代理 → 上游**」时序图与三条易错点；组件清单补 6 行。
- `docs/flow.md` — 新增「**故障自愈流程**」（mermaid 判定图 + 触发条件→动作→日志位置表 + watchdog 管不到的四件事）与「**平板重启后的 15 分钟恢复清单**」（7 步表 + 3 件需要人做的事）。
- `docs/testing.md` — 新增 **T21–T28**：看门狗自愈、`quick.sh` 幂等、`optimize` 后冷启动耗时、流式代理连通、控制台设置页四类操作、连续 2 小时稳定性、冷启动 ≤5 分钟、单条回复延迟 P50/P95；证据清单改为真实截图文件名。

### 变更

- `scripts/panel_v2.py` → `scripts/panel_v3.py`（新增性能快照 / 日志查看 / 一键修复 / 维修页 / 体检卡）；`scripts/install.sh`、`scripts/boot.sh`、`scripts/restart_all.sh`、`scripts/deploy_panel.sh` 的引用同步改名。
- `tools/pc_bootstrap.py`：相对早期草稿把写死的 hdc 路径、设备序列号、平板/PC 内网 IP 改为环境变量（默认值留占位符 `192.168.x.x`），符合 T19 的「无真实凭据/内网地址」检查。
- `watchdog.sh`、`quick.sh`、`optimize.sh`、`vyceai_proxy.py`、`tools/pc_bootstrap.py` 统一补了文件头注释：**用途 / 依赖 / 日志路径 / 安全提示**；`panel_v3.py` 保留其自带头注释。
- `LICENSE`（MIT）与 `.gitignore` 未改动；README 中「上游 AstrBot 为 AGPL-3.0」的义务声明保留。

### 已知问题

- **8 vCPU 下 Linux QQ 会原生崩溃**（Electron 进程级 `Bugly` native 崩溃栈），SnowLuma 偶发 `process enumeration timed out`。**建议把虚机 CPU 调回 4（或 6）核**：4 核是「连跑几小时不崩」的配置，8 核只是跑分好看。看门狗 30 s 巡检能自愈，但一次恢复要几分钟，期间群里无响应。
- **`vyceai` 中转站目前全线不可用**：`/v1/chat/completions` 对 `deepseek-v4.1` 非流式一律 `invalid_request`，流式先给空 chunk 再报错，整站间歇 `service_unavailable`。因此 `vyceai_proxy.py` 目前只验到「能起、能监听、能透传上游错误」，**完整链路待上游恢复**（T24）。当前实跑模型是 **PC 网关 `ben/deepseek-v4.1-flash`**（`fwd8789.py` 8789 → `127.0.0.1:8788`），**仍依赖 PC 开机**；要让平板真正独立，需要一个能从平板直连的 key。
- **QQ 掉登录必须重新扫码**：机器人无头，只能开 `http://127.0.0.1:6080/vnc.html` 把二维码显示出来扫；watchdog 只判「进程在」，二维码页也算在，所以它不会也不该帮你扫码。
- **冷启动未达 5 分钟验收线**：8 vCPU + 14 插件下实测 6~10 分钟（早期 4 核记录 3–4 分钟）。`optimize.sh` 的 pyc 预编译预估省 30~60 s，**待实测**（T23）；先降核再复测（T27）。
- **连续 2 小时稳定性未跑满**：看门狗已部署、单次自愈已验，但 T26 的两小时连续记录还没有。
- **控制台面板密码登录报错**（AstrBot 6185 后台，不影响聊天），沿用 0.1.0 的问题。
- **安全边界依旧很薄**：8080 无鉴权、x11vnc `-nopw`、`z2.sh` 等于免密 shell 通道、`vyceai_proxy.py` 透传 Authorization；只适合内网自用，公网必须加鉴权反代并关掉 `z2.sh` 自启。

### 未验证 / 待补

- T23（optimize 后冷启动收益）、T24（流式代理完整链路，等上游）、T26（2 小时稳定性）、T27（4 核复测）、T28（P50/P95 采样）。
- 4 核 / 6 核配置下的冷启动与稳定性复测数据。
- `logsvr.py`（PC 8081 日志接收）与 `fwd8789.py`（PC 8789 模型网关转发）两个 PC 侧小工具尚未随仓库发布。
- 除 MatePad 11.5 S / HarmonyOS 7（API 26）以外的机型仍待验证。

---

## [0.1.0] - 2026-11-09

首个公开版本：把「鸿蒙平板上跑 QQ 机器人」这套已经跑通的部署整理成可开源发布的工程。
代码逻辑与线上部署一致，只是补齐了文件头注释、去掉了写死的凭据、补了文档。

### 新增

**文档**
- `README.md` — 一句话定位、mermaid 架构图、能力清单、快速开始、四个入口端口表、已知限制、目录说明、许可证选择理由。
- `docs/architecture.md` — 分层组件图、收消息/回消息时序图、启动时序图，以及「为什么鸿蒙上必须用 QEMU 虚机」的完整因果链（安卓 APK/ptrace → 卓易通 syscall 白名单 → PRoot 失效 → 换层）与「虚机里为什么用 chroot 不用 PRoot」的取舍。
- `docs/flow.md` — 七步部署流程（对应教学文档阶段 0–7）、启动时间轴（gantt）、13 条「症状 → 原因 → 命令」故障排查表、日常操作卡、可选远程通道附录。
- `docs/testing.md` — 20 项测试清单，每项写清怎么验、期望输出、失败含义与证据占位。
- `docs/screenshots/README.md` — 8 张待补截图的规范（文件名、关键要素、拍摄方法、脱敏清单）。

**脚本**（部署到虚机 `/root/` 下运行，均补了文件头注释：用途 / 依赖 / 坑）
- `scripts/boot.sh` — 6 阶段启动器：挂载 → Xvfb → QQ → AstrBot → SnowLuma → x11vnc/noVNC → 控制台 + 远程通道，幂等。
- `scripts/restart_all.sh` / `restart_astrbot.sh` / `restart_snowluma.sh` / `restart_qq.sh` — 分级重启，说明了 SnowLuma→AstrBot 的顺序依赖与 `pkill -f "main[.]py"` 的原因。
- `scripts/panel_v2.py` — 8080 控制台与设置页（服务状态、模型/插件开关、人格、唤醒词、一键重启）。
- `scripts/deploy_panel.sh` — 拉取控制台并自检（末尾打印两个 HTTP 状态码）。
- `scripts/patch_cfg.py` — 把 AstrBot platform 改成 `aiocqhttp` + `ws_reverse_port 6199`。
- `scripts/only_deepseek.py` — 模型列表收敛到单个可用模型，改前自动备份。
- `scripts/use_pc_gw.py` — 模型源切到 PC 上的 OpenAI 兼容网关（可选方案）。
- `scripts/hide_qq.sh` — 把 QQ 窗口 unmap，省掉软件渲染下 40%+ 的 CPU。
- `scripts/z2.sh` — 远程命令通道（运维后门，默认不建议开）。
- `scripts/install.sh` — 从零部署引导骨架，阶段 0–7 可按序号单跑，需要人判断的地方一律停下给指引。
- `tools/hm.py` — PC 侧 hdc 控制脚本（截屏/点击/输入/控件树/装应用/端口转发），用于「用电脑接管平板」。

**工程文件**
- `LICENSE` — MIT，附选择理由（仓库只含胶水代码，不含被 hook/被调用的第三方源码；AstrBot 仍受其上游 AGPL-3.0 约束）。
- `.gitignore` — 忽略 AstrBot 配置与备份（含 key）、各类日志、运行时产物、Python 缓存、大件安装包。
- `CHANGELOG.md` — 本文件。

### 变更（相对原始部署脚本）

- `panel_v2.py`：把写死的 AstrBot 后台账号密码改成 `AB_USER` / `AB_PASS` 环境变量，默认回落到 AstrBot 默认的 `astrbot` / `astrbot`，仓库内不再包含任何真实凭据。
- `install.sh`：新增，把原本散落在终端历史里的部署动作固化成可重跑的骨架。
- 所有脚本：新增文件头注释（用途、依赖、日志位置、踩过的坑），行为未改。

### 已知问题

- 面板密码登录报错（不影响聊天），待修。
- 「群里 @ → 自动回复」端到端仅各段单独验证过，缺一条真实群消息的实测记录（`docs/testing.md` T14）。
- 平板上直接打开 SnowLuma 面板（5099）需要额外端口映射，目前是可选项。
- 无 OpenRC / systemd，自启依赖 `/root/.profile`；虚机切后台可能被鸿蒙挂起。
- 控制台 8080 无鉴权、x11vnc `-nopw`、`z2.sh` 等于免密 shell 通道 —— 仅限内网自用。

### 未验证 / 待补

- HiSH 具体版本号（组件表里留空待补）。
- Linux QQ 安装包的下游版本与下载地址（实测 3.2.32）。
- 除 MatePad 11.5 S / HarmonyOS 7（API 26）以外的机型能否起 QEMU 虚机。
