# 测试清单

每条都写清三件事：**怎么验**（可直接复制的命令或操作）、**期望输出**（长什么样才算过）、**证据**（截图放到哪）。
命令除特别标注外，都在 HiSH 终端（Alpine 侧）执行；标 `[chroot]` 的在 `chroot /root/ubuntu /bin/bash -lc '...'` 里执行。

状态图例：✅ 已实测通过 ／ ⏳ 待验证 ／ ❌ 已知不通过。

> 共 **28 项**：T01–T20 是功能/环境项（能不能跑），T21–T28 是稳定性与性能验收项（敢不敢长期用，见第 7 节）。
> 截图已就位 3 张（`01-vm-desktop.png`、`02-console.png`、`03-settings.png`，均已脱敏），对应 T06 / T13 / T16 / T25；
> 其余「证据」列的 `⛔ 待补` 照旧，补图时换成图片链接并把状态从 ⏳ 改成 ✅。
> 截图规范见 [screenshots/README.md](screenshots/README.md)。

---

## 0. 环境基线（记录一次，后面所有测试都对照它）

| 项 | 命令 | 本次实测值 |
|---|---|---|
| 设备 | 设置 → 关于本机 | 华为 MatePad 11.5 S |
| 系统 | 同上 | HarmonyOS 7（API 26） |
| 虚机 | HiSH 齿轮 → 模拟器管理 | 4 核 / 4096 MB / Alpine 3.22 / 盘 124 G |
| 内核 | `uname -a` | Linux … aarch64 … |
| 架构 | `uname -m` | `aarch64` |
| chroot | `chroot /root/ubuntu cat /etc/os-release \| head -2` | Ubuntu 24.04.x LTS（arm64） |
| 端口 | `netstat -ltn` | 5099 / 5900 / 6080 / 6185 / 6199 / 8080 |

---

## 1. 基础设施

### T01 虚机资源足够

- **怎么验**：`nproc; free -m | sed -n 2p; df -h /root`
- **期望**：`nproc` = 4；可用内存 ≈ 3900 MB（不是 512）；`/root` 剩余 ≥ 20 G。
- **失败含义**：默认 512 MB / 1 核，后面 `apt` / `pip` 一定跑挂。
- **证据**：⛔ 待补 · 状态：✅

### T02 chroot 可用

- **怎么验**：`chroot /root/ubuntu /bin/bash -lc 'cat /etc/os-release | head -2; uname -m'`
- **期望**：打印 `Ubuntu 24.04.x LTS` 与 `aarch64`，无 `chroot: failed to run command` 报错。
- **失败含义**：ubuntu-base 没解全 / 挂载没做 / arch 不符。
- **证据**：⛔ 待补 · 状态：✅

### T03 apt 源正确（arm64 必须是 ports）

- **怎么验**：`chroot /root/ubuntu /bin/bash -lc 'apt-get update -y 2>&1 | tail -5'`
- **期望**：`Reading package lists... Done`，源地址里是 `ubuntu-ports`，没有 404。
- **证据**：⛔ 待补 · 状态：✅

---

## 2. 图形与 QQ

### T04 Xvfb 假屏可用

- **怎么验**：`pgrep -f 'Xvfb :99'` + `chroot /root/ubuntu /bin/bash -lc 'DISPLAY=:99 xdpyinfo | head -8'`
- **期望**：有 PID；`xdpyinfo` 打印 `dimensions: 1280x800 pixels`、`depth of root window: 24 planes`。
- **证据**：⛔ 待补（可截 `xdpyinfo` 输出）· 状态：✅

### T05 Linux QQ 能启动且不崩

- **怎么验**：`pgrep -f '/opt/QQ/qq'`；崩了看 `tail -50 /tmp/qq.out`
- **期望**：有 PID；`/tmp/qq.out` 里没有 `DevTools` 之外的致命报错（重点排除共享内存/OOM 类错误）。
- **已知失败模式**：少带 `--disable-gpu --disable-dev-shm-usage` 时启动即崩。
- **证据**：⛔ 待补 · 状态：✅

### T06 QQ 已登录（自动登录生效）

- **怎么验**：noVNC 打开 `http://127.0.0.1:6080/vnc.html`，看 QQ 主界面是否已登录（不是二维码页）。
- **期望**：看到 QQ 主面板 + 好友/群列表，无二维码。
- **失败处理**：`sh /root/restart_qq.sh` 后仍出二维码 → 必须手机扫码。
- **证据**：[01-vm-desktop.png](screenshots/01-vm-desktop.png)（QQ 已登录，昵称/群名已打码）· 状态：✅

---

## 3. Hook 与协议

### T07 SnowLuma 进程在跑

- **怎么验**：`pgrep -f index.mjs`；`tail -30 /root/sl.log`
- **期望**：有 PID（Node 启动器进程名是 `index.mjs`，不是 `snowluma`）；日志无端口占用报错。
- **证据**：⛔ 待补 · 状态：✅

### T08 SnowLuma 面板可开（5099）

- **怎么验**：`curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5099`
- **期望**：`200`（或 302）。PC 侧要用 `python tools/hm.py fport 5099` 转发后才能在本机浏览器开。
- **已知问题**：转发隧道死了会报 `Failed to fetch`，重连即可。
- **证据**：⛔ 待补 · 状态：✅

### T09 注入成功（hook 已加载）

- **怎么验**：SnowLuma 面板 →「进程注入」页
- **期望**：QQ 进程状态为「已加载 / 已注入」，`hookAutoLoad` 为 `true`。
- **证据**：⛔ 待补 · 状态：✅

### T10 OneBot 反连已建立（6199）

- **怎么验**：`chroot /root/ubuntu /bin/bash -lc 'ss -tn | grep 6199 || netstat -tn | grep 6199'`
- **期望**：出现一条 `ESTABLISHED`，本地/对端都在 `127.0.0.1` 的 6199 附近。
- **说明**：AstrBot 是服务端、SnowLuma 是客户端；方向搞反会白查很久。
- **证据**：⛔ 待补 · 状态：⏳

---

## 4. AstrBot 与大模型

### T11 AstrBot 后台可开（6185）

- **怎么验**：`curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:6185`（冷启动后等 ≥ 3 分钟再测）
- **期望**：`200`。
- **已知问题**：面板密码登录报错（不影响聊天），状态 ❌ 待修。
- **证据**：⛔ 待补（`04-astrbot.png` 还没拍）· 状态：✅（HTTP 层）/ ❌（登录）

### T12 模型源连通

- **怎么验**：在 AstrBot 后台对配置的 provider 点「测试」，或虚机里直接打 API：
  ```sh
  curl -sS -m 60 -X POST "<你的 base_url>/chat/completions" \
    -H "Authorization: Bearer <你的 key>" -H 'Content-Type: application/json' \
    -d '{"model":"<你的 model>","messages":[{"role":"user","content":"ping"}]}' | head -c 300
  ```
- **期望**：返回含 `choices` 的 JSON（不是 401/超时）。
- **证据**：⛔ 待补（**打码 key 后再截图**）· 状态：✅

### T13 控制台 8080 可用

- **怎么验**：`curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/api/status` 且返回 JSON
- **期望**：`200`；JSON 里四个服务状态可读，模型列表非空。
- **证据**：[02-console.png](screenshots/02-console.png)、[03-settings.png](screenshots/03-settings.png) · 状态：✅

---

## 5. 端到端

### T14 群里 @ 机器人有回复

- **怎么验**：用一个测试群，发 `@机器人 你好`；同时 `tail -f /root/ab.log`。
- **期望**：`ab.log` 里出现收到消息事件 → 调用模型 → `send_group_msg` 的记录；群里 10 秒内出现回复。
- **失败分段定位**：日志里没有事件 = hook/6199 问题；有事件无模型调用 = 唤醒词/规则问题；有调用无回复 = 模型超时或发送失败。
- **证据**：⛔ 待补 → [screenshots/05-group-reply.png](screenshots/README.md) · 状态：⏳ **待验证（这是目前唯一没闭环的一项）**

### T15 重启虚机后全自动恢复

- **怎么验**：HiSH 里重启虚机 → 等 5 分钟 → 不手动干预，依次检查 T05/T06/T07/T09/T10/T11。
- **期望**：`tail -20 /root/boot.log` 有 5 行 `OK` + `BOOT_DONE`；QQ 免扫码自动登录；6199 有连接。
- **证据**：⛔ 待补（`boot.log` 截图）· 状态：✅

---

## 6. 可选/负向检查

| 编号 | 项目 | 怎么验 | 期望 | 状态 |
|---|---|---|---|---|
| T16 | noVNC 桌面可用 | 浏览器开 `http://127.0.0.1:6080/vnc.html` | 看到 Xvfb 桌面（含 QQ 窗口或空白桌面）；证据 [01-vm-desktop.png](screenshots/01-vm-desktop.png) | ✅ |
| T17 | 省 CPU 生效 | 跑 `sh /root/hide_qq.sh` 后 `top -b -n1 \| head -15` | QQ 窗口不可见后 CPU 明显下降 | ✅ |
| T18 | 断电/强杀后自愈 | 虚机里 `pkill -f 'main[.]py'`，再 `sh /root/boot.sh` | AstrBot 被重新拉起，其它进程不重复 | ✅ |
| T19 | 无密钥泄漏 | `git grep -nE 'sk-\|Bearer [A-Za-z0-9]\|passw\|192\.168\.'` | 只出现在文档示例与 `.gitignore` 相关说明里，没有真实凭据 | 每次提交前跑 |
| T20 | 慢不是挂 | AstrBot 重启后立刻开 6185 | 打不开属正常，3–4 分钟后 200 | ✅ |

---

## 7. 稳定性与性能（T21–T28）

这一组是**验收项**，不是功能项：前 20 项回答「能不能跑」，这 8 项回答「敢不敢长期用」。每项都给了量化判据，跑不过就写「未达标 + 实测值」，别写「基本可用」。

### T21 看门狗自愈（崩溃 → 自动拉起）

- **怎么验**：先确认它在跑，再手动制造一次崩溃：
  ```sh
  pgrep -f '[w]atchdog.sh'                       # 期望有 PID
  pkill -f '[m]ain[.]py'                         # 杀 AstrBot（最安全的验证对象）
  sleep 60; tail -5 /root/watchdog.log           # 期望出现「AstrBot 进程不在，拉起」
  cat /root/watchdog.state                       # ab= 字段从空变成新 PID
  ```
  想验 QQ 则 `pkill -f '[q]q --no-sandbox'`：注意 watchdog 起 QQ 后会在 **20 秒后重挂 SnowLuma**（重启后 hook 必失效），`watchdog.log` 里会有「QQ 重启后已重挂 SnowLuma」。
- **期望**：≤ 60 s 内日志出现对应拉起记录；`watchdog.state` 四项都非空；AstrBot 恢复 6185 需再等 5~10 分钟（冷启动，**不是失败**）。
- **失败含义**：watchdog 没起 / `INTERVAL` 被改得太大 / 它的 `pgrep` 匹配串被改坏。
- **证据**：`/root/watchdog.log` 与 `/root/watchdog.state` 截图 · 状态：✅（单项自愈已验；连续时长见 T26）

### T22 quick.sh 幂等（连跑两次不重复拉起）

- **怎么验**：
  ```sh
  sh /root/quick.sh 2>&1 | tail -20
  for p in Xvfb qq index.mjs main.py panel.py watchdog.sh; do pgrep -f "$p" | head -1; done > /tmp/pid1
  sh /root/quick.sh 2>&1 | tail -20
  for p in Xvfb qq index.mjs main.py panel.py watchdog.sh; do pgrep -f "$p" | head -1; done > /tmp/pid2
  diff /tmp/pid1 /tmp/pid2 && echo IDEMPOTENT_OK
  ```
- **期望**：第二次运行**不出现**「X 不可用，清理锁并重启 / QQ 不在，启动 / 看门狗不在，启动」这类拉起行；PID 前后一致（`IDEMPOTENT_OK`）；两次都以 `=== quick.sh done` 结尾，且日志里 `X=OK`、`QQ=OK`、`SnowLuma=OK`、`AstrBot=200`、`watchdog=OK`。
- **说明**：`AstrBot=` 后跟的是 HTTP 状态码，`000` 表示 40 次轮询（约 10 分钟）都没等到 200；`OneBot=NO_TOKEN` 表示没读到 SnowLuma 的 token 文件，链路未验。
- **证据**：`/root/quick.log` 两次对比 · 状态：⏳ 待补实测记录

### T23 optimize.sh 之后冷启动是否变快

- **怎么验**：先记基线（未优化时重启虚机，量到 6185 首个 200 的耗时），再优化并复测同一指标：
  ```sh
  sh /root/optimize.sh 2>&1 | tail -12      # 看 core_rc=0 / plugins_rc=0 / start_qq.sh 已写入
  # 重启虚机后
  grep -n 'BOOT_DONE' /root/boot.log; date
  ```
- **期望**：`compileall` 返回 `core_rc=0` 与 `plugins_rc=0`；`/root/ubuntu/root/start_qq.sh` 存在且含 `--max-old-space-size=384`；冷启动较基线下降（素材预估 **-30~60 s**，**待实测**）。
- **注意**：`optimize.sh` 会原地改 `cmd_config.json`（含 key，已 gitignore），别把它的内容贴出来。
- **证据**：`optimize.sh` 输出 + 前后两次冷启动耗时对照 · 状态：⏳ 待实测（预估值未验证）

### T24 流式代理连通（非流式 → 上游 stream）

- **怎么验**：
  ```sh
  nohup python3 /root/vyceai_proxy.py >/root/vyceai_proxy.log 2>&1 &
  curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8790/v1/models      # 期望 200
  curl -sS -m 120 -X POST http://127.0.0.1:8790/v1/chat/completions \
    -H "Authorization: Bearer <上游 key>" -H 'Content-Type: application/json' \
    -d '{"model":"deepseek-v4.1","messages":[{"role":"user","content":"ping"}]}' | head -c 300
  ```
  然后把 AstrBot provider 的 `api_base` 改成 `http://127.0.0.1:8790/v1`（**不带 stream 参数**），在后台点「测试」。
- **期望**：`/v1/models` 返回 200；POST 返回**非流式**标准 JSON（含 `choices[0].message.content`，而不是 `data:` 开头的 SSE）；AstrBot 后台测试通过。
- **当前状态**：⏳ **阻塞在上游**。`vyceai` 目前全线不可用（chat 全报 `invalid_request` / `service_unavailable`，只有 stream 模式先给空 chunk 再报错），本项**只验到「代理能起、能监听、能透传上游错误」**，完整链路**待上游恢复**。也可用 `UPSTREAM=<任一「只吃 stream」的网关>` 复验翻译逻辑。
- **证据**：`/root/vyceai_proxy.log` + 一次成功返回的 JSON 头 · 状态：⏳ 待上游恢复

### T25 控制台设置页四类操作

- **怎么验**（浏览器开 `http://127.0.0.1:8080/settings`，逐类点一次，每类点完刷新页面确认落盘）：

  | 操作 | 对应接口 | 期望 |
  |---|---|---|
  | 模型开关（ben / vyceai） | `POST /api/model` | 开关状态变化；刷新后保持；AstrBot 侧 provider 启用状态同步 |
  | 插件开关（14 个） | `POST /api/plugin` | 提示「已切换」；约 1.8 s 后列表刷新为反状态 |
  | 人格编辑 | `POST /api/persona` | 保存后重开页面，`system_prompt` 仍是新值 |
  | 唤醒前缀 | `POST /api/wake` | 改完在群里 @ 一次，行为按新前缀变化（与 T14 联动） |

- **期望**：四类都改得动、刷新不丢、不用碰命令行；若提示需重启，点「重启 AstrBot」等它起来即可。
- **证据**：[03-settings.png](screenshots/03-settings.png)（模型开关 `ben` 开 / `vyceai` 关，插件开关列表）· 状态：✅（模型 / 插件 / 人格 / 唤醒前缀四类实测可用；设置页截图为 v2 界面，v3 的 `/quick` 维修页与体检卡待补图）

### T26 连续 2 小时稳定性（无人工干预）

- **怎么验**：
  ```sh
  sh /root/quick.sh                       # 先拉齐
  sh tests/stress_light.sh                # 或人工挂 2 小时，每 15 分钟看一次
  # 每 15 分钟：
  cat /root/watchdog.state; sh tests/healthcheck.sh | tail -5
  grep -c '重启' /root/watchdog.log       # 自愈次数
  ```
- **期望**：2 小时内 `healthcheck.sh` 全绿（或仅短暂变红）；`watchdog.log` 的自愈次数被记录在案；无人工 reboot；`load average` 不长期 ≥ 核数。
- **失败含义**：8 vCPU 下更常见（QQ 原生崩溃）；降到 4 核复测，仍不稳则归入「已知限制」。
- **证据**：`watchdog.log` 两小时连续记录 + `healthcheck.sh` 末次输出 · 状态：⏳ **未跑满 2 小时**（看门狗已部署，只验过单次自愈）

### T27 冷启动 ≤ 5 分钟（到 6185 可访问）

- **怎么验**：从「打开 HiSH → 虚机启动完成」开始计时，每 15 s `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:6185/`，记下首次 200 的时刻；`tests/bench.sh` 会把过程记成一行。
- **期望**：≤ **5 分钟**（验收线）；再往后 ≤ 8 分钟应能收到群回复。
- **当前实测**：8 vCPU + 14 插件下 **6~10 分钟**，**未达标**；早期 4 核记录是 3–4 分钟。结论：**先降核再复测**，别拿 8 核的数字当基准。
- **证据**：`bench.sh` 输出（含时间戳）· 状态：❌ 未达标（8 核）；⏳ 4 核待复测

### T28 单条回复延迟 P50 / P95

- **怎么验**：固定同一模型、同一句话，连发 **≥ 20 条**私聊（`tests/bench.sh` 或 OneBot `send_private_msg`），记录「发出 → 收到」的毫秒差并算 P50/P95：
  ```sh
  sh tests/bench.sh            # 输出每轮耗时，末尾给出 P50/P95
  ```
- **期望**：**P50 ≤ 30 s**、**P95 ≤ 90 s**（验收线）。分两段看：模型返回耗时（上游决定）与发送耗时（QQ/SnowLuma 决定）。
- **当前实测**：单条 **5~60 s**（样本不足，未统计 P50/P95）→ ⏳ 待系统性采样。
- **证据**：`bench.sh` 逐条耗时 + 汇总行 · 状态：⏳ 待采样

---

## 8. 结论记录模板

补完真实截图后，把这一段填好放进 README「当前状态」：

```text
测试日期：YYYY-MM-DD
固件/系统：HarmonyOS 7 (API 26) / HiSH x.y
通过：T01–T09、T11（HTTP 层）、T12–T13、T15–T18、T20–T22、T25（共 xx 项）
待验证：T10（OneBot 反连实测记录）、T14（群 @ 端到端）、T23（优化后冷启动）、T24（待上游恢复）、T26（2 小时稳定性）、T28（P50/P95 采样）
已知不通过：T11 面板密码登录；T27 冷启动 6~10 分钟 > 5 分钟验收线（8 vCPU）
截图：docs/screenshots/01-vm-desktop.png、02-console.png、03-settings.png
```

## 9. 证据截图清单（对应文件）

| 文件 | 内容 | 关联测试 |
|---|---|---|
| `01-vm-desktop.png` | 虚机桌面：Linux QQ 已登录（昵称/群名/好友名已打码） | T06、T09、T16 |
| `02-console.png` | 控制台首页：体检卡 + 四状态灯 + 性能 + 入口 | T13、T25 |
| `03-settings.png` | 控制台设置页：模型开关 + 14 个插件开关 | T13、T25 |
| `04-astrbot.png` | AstrBot 后台首页 | T11 · **⛔ 待补** |
| `05-group-reply.png` | 群里 @ 机器人 → 收到回复 | T14 · **⛔ 待补** |

命名与脱敏要求见 [screenshots/README.md](screenshots/README.md)。
