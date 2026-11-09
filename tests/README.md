# 稳定性自测 & 性能基线脚本（tests/）

这套脚本用于**鸿蒙平板机器人**（MatePad 11.5 S / 鸿蒙 7 + HiSH 虚机）的日常自检。
运行位置是**虚机内部**（HiSH 里的 Alpine 3.22 → chroot Ubuntu 24.04），只访问 `127.0.0.1`，
不依赖平板 IP、不碰 `hdc`、不改任何服务配置，全部是只读探测（`stress_light.sh` 只写自己的
CSV/summary 两个文件）。

| 文件 | 作用 | 是否有副作用 |
|---|---|---|
| `healthcheck.sh` | 一次性健康检查，11 项 PASS/FAIL | 无（只读） |
| `bench.sh` | 性能基线，输出 Markdown 表格 | 无（只读） |
| `e2e_test.sh` | 端到端：发一条 QQ 私聊 + 在线状态 + AstrBot lag 检查 | 会真的发一条「【自检】」消息 |
| `stress_light.sh` | 30 次 × 20 秒轻量稳定性观察，CSV + 恢复时间统计 | 写 `/root/stability.csv`、`/root/stability_summary.txt` |

---

## 0. 准备（一次就行）

把本目录 4 个 `.sh` 拷到虚机里（例如 `/root/tests/`），然后：

```sh
chmod +x /root/tests/*.sh
```

依赖只有 **curl**（必装）+ busybox 自带的 `awk/sed/grep/pgrep/ps/netstat`；
`python3` 是可选的（有它时解析 OneBot token 更稳，没有就自动退回 `sed`）。
虚机里一般已经有：

```sh
which curl python3 pgrep netstat
```

脚本都是 **POSIX sh**（`#!/bin/sh`），可以在 busybox ash / dash 下跑；**不要**用 `bash script.sh`
以外的 shell 特性，也不要改成 `bash` 专用写法（数组、`[[ ]]`、`${var,,}` 都刻意没用）。

四个脚本**各自独立、互不 source**（token 解析、端口探活这些小组件在每个脚本里各有一份，
方便单独拷某一个到虚机里用），所以可以按需只拷需要的文件。

### 可配置项

每个脚本顶部有一段 `# 可配置项` 区块，全部支持环境变量覆盖，**不要在正文里改硬编码**：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `AB_URL` | `http://127.0.0.1:6185` | AstrBot WebUI |
| `SL_PANEL_URL` | `http://127.0.0.1:5099` | SnowLuma 面板 |
| `ONEBOT_URL` | `http://127.0.0.1:3000` | SnowLuma OneBot HTTP |
| `ONEBOT_CFG` | `/root/ubuntu/root/sl/config/onebot_3982034942.json` | 读 `http-default.accessToken` |
| `ONEBOT_TOKEN` | 空 | 非空则直接用，不读配置文件 |
| `AB_LOG` | `/root/ab.log` | AstrBot 日志（bench/e2e 用） |
| `CURL_MAX` | 5（e2e 是 10） | 单个 curl 的 `--max-time` 秒数 |
| `PORTS` | `6185,8080,6080,5099` | healthcheck 要查的监听端口（四端口映射） |
| `LAG_WARN_SEC` | 15 | e2e 里 Event loop lag 的 WARN 阈值 |
| `PYTHON_BIN` | `python3` | 解析 JSON 用；没有会自动降级 |

所有脚本都在**虚机内部**执行，所以 IP 一律 `127.0.0.1`，不要替换成平板/网关地址。

---

## 1. `healthcheck.sh` — 一次性健康检查

```sh
sh /root/tests/healthcheck.sh
```

检查项（共 11 项）：

1. Xvfb 进程（`Xvfb :99`）
2. QQ 进程（`/opt/QQ/qq`）
3. SnowLuma 进程（`index.mjs`）
4. AstrBot 进程（`main.py`）
5–8. 四个端口监听：`6185`、`8080`、`6080`、`5099`
9. AstrBot HTTP 可达（`GET http://127.0.0.1:6185/`，期望 2xx）
10. SnowLuma 面板可达（`GET http://127.0.0.1:5099/`，期望 2xx）
11. QQ 已登录（OneBot `POST /get_login_info`，要求 `retcode=0` 且 `user_id` 非空）

**判断标准**：最后一行 `X/Y passed`；`RESULT: OK` 且退出码 0 表示全通过。
任何一项 FAIL → 退出码 **1**，直接拿 FAIL 行去定位。

### 样例输出（示例，非真机实测）

```text
# healthcheck  2026-11-09 17:40:12  (Linux aarch64)
------------------------------------------------------------
PASS  Xvfb  -- 运行中 pid=4211 (etime=02:13:05)
PASS  QQ  -- 运行中 pid=4350, 4361 (etime=02:12:40)
PASS  SnowLuma  -- 运行中 pid=4502 (etime=02:11:58)
PASS  AstrBot  -- 运行中 pid=4720 (etime=02:04:31)
------------------------------------------------------------
PASS  端口 6185  -- AstrBot WebUI 正在监听
PASS  端口 8080  -- 控制台 panel_v3 正在监听
PASS  端口 6080  -- noVNC 正在监听
PASS  端口 5099  -- SnowLuma 面板 正在监听
------------------------------------------------------------
PASS  AstrBot HTTP  -- GET http://127.0.0.1:6185/ -> 200 (0.0123s)
PASS  SnowLuma 面板  -- GET http://127.0.0.1:5099/ -> 200 (0.0081s)
PASS  QQ 登录  -- user_id=3982034942 nickname=示例昵称（token 已加载）
------------------------------------------------------------
11/11 passed
RESULT: OK
```

常见 FAIL 与处理：

| FAIL 项 | 先看什么 |
|---|---|
| 进程 Xvfb / QQ / SnowLuma / AstrBot | 对应 restart 脚本（VM 已有 `restart_*.sh`）有没有跑；`ps` 里进程名对不对 |
| 端口 6185/8080/6080/5099 | HiSH 端口映射是否掉；VM 内 `netstat -lnt` 看有没有监听 |
| AstrBot HTTP / SnowLuma 面板 | 服务在但没起完（AstrBot 启动约 1–3 分钟），或返回 3xx/5xx，看 `RESULT` 里的实际 code |
| QQ 登录 | `retcode` 不是 0：token 不对（见下）/ 3000 没起；`retcode=0` 但没 `user_id`：QQ 掉线 |

> token 说明：脚本按 `http-default.accessToken` 读取。若你的 SnowLuma 没设 token（`accessToken` 为空），
> 脚本会按**无鉴权**调 OneBot，这是正常的；若手头有 token，可 `ONEBOT_TOKEN=xxx sh healthcheck.sh` 覆盖。
> 如果返回 401/403，优先确认 `ONEBOT_CFG` 路径是否存在、token 是否与 OneBot 配置一致。

---

## 2. `bench.sh` — 性能基线

```sh
sh /root/tests/bench.sh                      # 打印 Markdown 到屏幕
sh /root/tests/bench.sh > /tmp/bench.md      # 存成文件
```

采集内容：

1. **机器信息**：`nproc`、`free -m`、1/5/15 分钟负载（`/proc/loadavg`）、uptime
2. **端口响应时间**：`6185/8080/6080/5099` 各 curl 3 次，报每次 + 中位数（`%{time_total}` 毫秒）
3. **AstrBot 启动耗时**：`main.py` 进程启动时刻 → `/root/ab.log` 里 `Running on http` 命中行的差；
   拿不到进程起点时退化为「日志首行 → 命中行」
4. **OneBot 往返延迟**：`POST /get_login_info` 3 次取中位数，附带 `retcode` 和 QQ 号

**判断标准**（经验值，写进 README 供对比，不是硬门禁）：

| 指标 | 正常 | 需要关注 |
|---|---|---|
| 端口响应中位数 | < 100 ms | > 500 ms |
| OneBot 往返 | < 50 ms | > 200 ms |
| AstrBot 启动耗时 | 60–240 s | > 360 s |
| 1 分钟负载 | < `nproc` | > 2 × `nproc` |

### 样例输出（示例，非真机实测）

```markdown
# 性能基线（bench）

采集时间：2026-11-09 17:42:03
采集环境：MatePad 11.5 S / 鸿蒙 7（API 26）/ HiSH 虚机 Alpine 3.22 → chroot Ubuntu 24.04

## 1. 机器信息

| 项目 | 值 |
|---|---|
| CPU 核数（nproc） | 8 |
| 内存（free -m） | total 3891 MB / used 2140 MB / free 1751 MB |
| 负载 1/5/15 min | 1.24 / 1.10 / 0.98 |
| 运行时长（uptime） | 0 天 03:12 |

## 2. 端口响应时间（curl %{time_total}，各 3 次取中位数）

| 端口 | 服务 | 第 1 次 (ms) | 第 2 次 (ms) | 第 3 次 (ms) | 中位数 (ms) |
|---|---|---|---|---|---|
| 6185 | AstrBot WebUI | 12 | 9 | 11 | 11 |
| 8080 | 控制台 panel_v3 | 4 | 4 | 5 | 4 |
| 6080 | noVNC | 3 | 3 | 3 | 3 |
| 5099 | SnowLuma 面板 | 8 | 7 | 8 | 8 |

## 3. AstrBot 启动耗时

| 项目 | 值 | 说明 |
|---|---|---|
| 进程启动 → 监听就绪 | 138 秒 | 来源：进程启动 → 日志命中 |

## 4. OneBot HTTP 往返延迟（POST /get_login_info，3 次取中位数）

| 接口 | 第 1 次 (ms) | 第 2 次 (ms) | 第 3 次 (ms) | 中位数 (ms) | retcode | QQ 号 |
|---|---|---|---|---|---|---|
| POST /get_login_info | 3 | 4 | 3 | 3 | 0 | 3982034942 |

## 5. 判定参考（非硬性，按经验值）

| 指标 | 正常 | 需要关注 |
|---|---|---|
| 端口中位响应 | < 100 ms | > 500 ms |
| OneBot 往返 | < 50 ms | > 200 ms |
| AstrBot 启动耗时 | 60–240 s | > 360 s |
| 1 min 负载 | < nproc | > 2×nproc |
```

把上面这段（去掉「样例」标题）粘进 `docs/testing.md` 即可。
> 注意：`Running on http` 只在 AstrBot **本次启动**的日志里；如果 `/root/ab.log` 被轮转/截断，
> 启动耗时可能显示 N/A —— 这不是脚本 bug，重启 AstrBot 后立刻采一次就行。

---

## 3. `e2e_test.sh` — 端到端自检

```sh
sh /root/tests/e2e_test.sh                 # 收件人默认 = 机器人自己（从 get_login_info 取 QQ）
sh /root/tests/e2e_test.sh 3982034942      # 指定收件 QQ
```

做三件事：

1. `POST /send_private_msg` 发送 `【自检】`，要求 `retcode=0`（响应无 `retcode` 但有 `status:"ok"` 也算过）
2. `get_status` 在线检查：`online`/`good` 不能是 `false`
3. 读 `/root/ab.log` 尾部 200 行，找 `Event loop lag`；**最大 lag > 15 秒记 WARN**，没记录算 PASS

**判断标准**：

- 退出码 **0** = 没有 FAIL（`RESULT: OK`；若有 WARN 会写「有 N 项 WARN，建议人工确认」）
- 退出码 **1** = 发消息或在线状态 FAIL
- WARN **不算失败**（比如 lag 异常、日志不可读），但要人工看一眼

### 样例输出（示例，非真机实测）

```text
# e2e_test  2026-11-09 17:44:21
INFO  OneBot=http://127.0.0.1:3000  token 已加载
------------------------------------------------------------
INFO  未指定收件人，回退为机器人自身 QQ：3982034942
INFO  收件 QQ：3982034942  消息内容：【自检】
------------------------------------------------------------
PASS  发送私聊消息  -- user_id=3982034942 message_id=1937452810
PASS  OneBot 在线状态  -- online=true good=true
PASS  Event loop lag  -- 最大 0.42s ≤ 阈值 15s（2 条记录）
------------------------------------------------------------
PASS 3 / FAIL 0 / WARN 0  (共 3 项)
RESULT: OK
```

如果收到 WARN：

- `最大 18.30s > 阈值 15s`：虚机被 HiSH 挂起后恢复、或平板上别的大任务在抢 CPU；连续两次出现再当问题查
- `日志不可读`：确认 `AB_LOG` 路径（默认 `/root/ab.log`）

---

## 4. `stress_light.sh` — 轻量稳定性观察

```sh
sh /root/tests/stress_light.sh              # 30 次 × 20 秒（约 10 分钟）
sh /root/tests/stress_light.sh 60 30        # 60 次 × 30 秒（约 30 分钟）
CSV_FILE=/tmp/s.csv ITER=5 INTERVAL=2 sh /root/tests/stress_light.sh   # 快速冒烟
```

每次采样写一行 CSV 到 `/root/stability.csv`（只追加，保留历史）：

```text
ts,qq,snowluma,astrbot,xvfb,load
1762676400,1,1,1,1,1.24
1762676420,1,0,1,1,1.31
```

- `1` = 存活，`0` = 不存活
- `astrbot` = `main.py` 进程 + `6185` 端口都在；`snowluma` = `index.mjs` 进程 + `3000` 端口都在
  （避免「进程活着但服务死了」这种假 OK）
- `load` = `/proc/loadavg` 第一列

跑完（或 Ctrl-C，`trap INT TERM` 会先汇总）后统计本次运行：

- 每个组件失败次数、可用率
- 0 → 1 的**恢复次数**、平均/最大**恢复耗时**（秒）
- 当前状态（末尾仍为 0 会标 `DOWN(unrecovered)`）

统计同时追加到 `/root/stability_summary.txt`。

**判断标准**：

- 退出码 **0** = 本轮所有采样点全部存活
- 退出码 **1** = 出现过任一组件掉线（CSV 里能看到具体时间点）
- 退出码 **130** = 被 Ctrl-C/TERM 中断（汇总仍会写）

### 样例输出（示例，非真机实测）

```text
# stress_light  2026-11-09 17:45:00
采样 30 次 × 20 秒，写入 /root/stability.csv（只追加，不覆盖历史）
------------------------------------------------------------
[1/30] ts=1762676700 qq=1 snowluma=1 astrbot=1 xvfb=1 load=1.24 | 累计失败 qq=0 sl=0 ab=0 xvfb=0
[2/30] ts=1762676720 qq=1 snowluma=0 astrbot=1 xvfb=1 load=1.31 | 累计失败 qq=0 sl=1 ab=0 xvfb=0
...
[30/30] ts=1762677300 qq=1 snowluma=1 astrbot=1 xvfb=1 load=1.18 | 累计失败 qq=0 sl=2 ab=0 xvfb=0

汇总（本次运行 起点=1762676700 采样=30/30 间隔=20s）：
component samples failed      avail  recovery      avg(s)      max(s)  state
       qq      30      0     100.0%         0         0.0           0  UP
 snowluma      30      2      93.3%         1        20.0          20  UP
  astrbot      30      0     100.0%         0         0.0           0  UP
     xvfb      30      0     100.0%         0         0.0           0  UP
```

> 恢复耗时 =「第一次观测到 0」到「第一次重新观测到 1」的墙钟差，精度等于采样间隔（默认 20s）。
> 想要更细就把 `INTERVAL` 调小（会增加采样负担，别低于 5s）。

**结果去哪看**：

```sh
cat /root/stability.csv            # 原始采样
tail -n 40 /root/stability_summary.txt   # 每次运行的汇总
```

---

## 5. 建议的日常组合

| 场景 | 命令 |
|---|---|
| 改完配置/重启后 | `sh /root/tests/healthcheck.sh` |
| 每次重启 AstrBot 后 | `sh /root/tests/bench.sh > /tmp/bench_$(date +%s).md` |
| 长时间挂机前 | `sh /root/tests/stress_light.sh`（后台：`nohup sh /root/tests/stress_light.sh >/tmp/stress.log 2>&1 &`） |
| 怀疑机器人不回消息 | `sh /root/tests/e2e_test.sh` |
| 交付/写文档 | `bench.sh` 输出 + `stability_summary.txt` 贴进 `docs/testing.md` |

## 6. 已知限制

- **只测虚机内部**：平板被 HiSH 挂起时，虚机内 `127.0.0.1` 的自检可能全 PASS，但外部（QQ）已经不可达；
  这种场景要靠 `e2e_test.sh` 发真实消息来发现。
- `netstat` 不可用时端口检查退回读 `/proc/net/tcp{,6}` 的 LISTEN 状态；两条路都没有结果时按「未监听」处理。
- `pgrep` 不可用时退回 `ps -ef | grep`；极端情况下可能把带同样字符串的进程误判为存活（本方案已尽量收窄 pattern）。
- `bench.sh` 的启动耗时依赖 `/root/ab.log` 的 `Running on http` 行；日志被截断/轮转时显示 N/A。
- `e2e_test.sh` 默认给机器人自己发私聊（不打扰别人）；要发给指定 QQ 就传参数。
- 脚本不做任何写配置/重启操作，所有 `curl` 都带 `--max-time`，不会挂死终端。
