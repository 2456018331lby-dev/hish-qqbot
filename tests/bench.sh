#!/bin/sh
# bench.sh — 性能基线采集（结果直接是 Markdown，方便贴进 docs/testing.md）
#
# 采集内容：
#   1) 机器信息：nproc / free -m / 1·5·15 分钟负载 / uptime
#   2) 四个映射端口（默认 6185,8080,6080,5099）的 curl 响应时间，各 3 次取中位数
#   3) AstrBot 启动耗时：进程启动 → 日志出现 "Running on http"（或日志首行 → 命中行）
#   4) OneBot HTTP 往返延迟：POST /get_login_info，3 次取中位数
#
# 只读脚本，不重启任何服务，所有请求只发往 127.0.0.1。
#
# 用法：
#   sh /root/tests/bench.sh                    # Markdown 打到 stdout
#   sh /root/tests/bench.sh > /tmp/bench.md    # 存文件后再贴进 docs/testing.md
#   PORTS=6185,3000 sh /root/tests/bench.sh    # 自定义端口集合
#   ONEBOT_TOKEN=xxxx sh /root/tests/bench.sh  # 手填 token（不读配置文件）
#
# 依赖：curl、awk、sed（busybox 自带）；python3 可选（解析 token / 时间戳）。

set -u

# ---------------- 可配置项 ----------------
AB_URL="${AB_URL:-http://127.0.0.1:6185}"
SL_PANEL_URL="${SL_PANEL_URL:-http://127.0.0.1:5099}"
ONEBOT_URL="${ONEBOT_URL:-http://127.0.0.1:3000}"
AB_LOG="${AB_LOG:-/root/ab.log}"
ONEBOT_CFG="${ONEBOT_CFG:-/root/ubuntu/root/sl/config/onebot_3982034942.json}"
ONEBOT_TOKEN="${ONEBOT_TOKEN:-}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
CURL_MAX="${CURL_MAX:-5}"           # 每个 curl 的 --max-time（秒）
PORTS="${PORTS:-6185,8080,6080,5099}"
PROC_ASTRBOT="${PROC_ASTRBOT:-main[.]py}"
# ------------------------------------------

if ! command -v curl >/dev/null 2>&1; then
    echo "FATAL: 找不到 curl，bench 依赖 curl 测响应时间" >&2
    exit 2
fi

now_text=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)

port_label() {
    case "$1" in
        6185) printf 'AstrBot WebUI' ;;
        8080) printf '控制台 panel_v3' ;;
        6080) printf 'noVNC' ;;
        5099) printf 'SnowLuma 面板' ;;
        3000) printf 'SnowLuma OneBot HTTP' ;;
        6199) printf 'AstrBot aiocqhttp' ;;
        *)    printf '端口 %s' "$1" ;;
    esac
}

port_url() {
    case "$1" in
        6185) printf '%s/' "$AB_URL" ;;
        5099) printf '%s/' "$SL_PANEL_URL" ;;
        *)    printf 'http://127.0.0.1:%s/' "$1" ;;
    esac
}

sample_ms() {
    # 成功输出整数毫秒；失败返回非 0
    t=$(curl -s -o /dev/null --max-time "$CURL_MAX" -w '%{time_total}' "$1" 2>/dev/null) || return 1
    case "$t" in
        ''|*[!0-9.]*) return 1 ;;
    esac
    awk -v x="$t" 'BEGIN { printf "%d", x * 1000 }'
}

median3() {
    printf '%s\n' "$1" "$2" "$3" | sort -n | sed -n '2p'
}

fmt_dur() {
    awk -v s="$1" 'BEGIN {
        d = int(s / 86400)
        h = int((s % 86400) / 3600)
        m = int((s % 3600) / 60)
        if (d > 0) printf "%d 天 %02d:%02d", d, h, m
        else printf "%02d:%02d", h, m
    }'
}

# ---------------- 机器信息 ----------------
cores=$(nproc 2>/dev/null)
case "${cores:-}" in
    ''|*[!0-9]*) cores=$(awk '/^processor[[:space:]]*:/ { n++ } END { print n + 0 }' /proc/cpuinfo 2>/dev/null) ;;
esac
[ -n "${cores:-}" ] || cores="N/A"

mem=$(free -m 2>/dev/null | awk '/^Mem:/ { printf "total %s MB / used %s MB / free %s MB", $2, $3, $4 }')
[ -n "${mem:-}" ] || mem="N/A（free 不可用）"

load1=$(awk '{ print $1 }' /proc/loadavg 2>/dev/null)
load5=$(awk '{ print $2 }' /proc/loadavg 2>/dev/null)
load15=$(awk '{ print $3 }' /proc/loadavg 2>/dev/null)
[ -n "${load1:-}" ] || load1="N/A"
[ -n "${load5:-}" ] || load5="N/A"
[ -n "${load15:-}" ] || load15="N/A"

up_s=$(awk '{ printf "%d", $1 }' /proc/uptime 2>/dev/null)
case "${up_s:-}" in
    ''|*[!0-9]*) up_text="N/A" ;;
    *) up_text=$(fmt_dur "$up_s") ;;
esac

printf '# 性能基线（bench）\n\n'
printf '采集时间：%s  \n' "$now_text"
printf '采集环境：MatePad 11.5 S / 鸿蒙 7（API 26）/ HiSH 虚机 Alpine 3.22 → chroot Ubuntu 24.04\n\n'

printf '%s\n\n' '## 1. 机器信息'
printf '%s\n' '| 项目 | 值 |'
printf '%s\n' '|---|---|'
printf '| CPU 核数（nproc） | %s |\n' "$cores"
printf '| 内存（free -m） | %s |\n' "$mem"
printf '| 负载 1/5/15 min | %s / %s / %s |\n' "$load1" "$load5" "$load15"
printf '| 运行时长（uptime） | %s |\n\n' "$up_text"

# ---------------- 端口响应时间 ----------------
printf '%s\n\n' '## 2. 端口响应时间（curl %{time_total}，各 3 次取中位数）'
printf '%s\n' '| 端口 | 服务 | 第 1 次 (ms) | 第 2 次 (ms) | 第 3 次 (ms) | 中位数 (ms) |'
printf '%s\n' '|---|---|---|---|---|---|'

for p in $(printf '%s' "$PORTS" | tr ',' ' '); do
    label=$(port_label "$p")
    url=$(port_url "$p")
    s1=$(sample_ms "$url"); [ -n "${s1:-}" ] || s1="-"
    s2=$(sample_ms "$url"); [ -n "${s2:-}" ] || s2="-"
    s3=$(sample_ms "$url"); [ -n "${s3:-}" ] || s3="-"
    if [ "$s1" = "-" ] || [ "$s2" = "-" ] || [ "$s3" = "-" ]; then
        med="-（有采样失败，服务未起或超时）"
    else
        med=$(median3 "$s1" "$s2" "$s3")
    fi
    printf '| %s | %s | %s | %s | %s | %s |\n' "$p" "$label" "$s1" "$s2" "$s3" "$med"
done
printf '\n'

# ---------------- AstrBot 启动耗时 ----------------
log_epoch() {
    # 从一行日志里取 "YYYY-MM-DD HH:MM:SS" 并转 epoch；失败返回非 0
    line="$1"
    ts=$(printf '%s' "$line" | sed -n 's/^\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}[ T][0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\).*/\1/p')
    [ -n "$ts" ] || return 1
    ts=$(printf '%s' "$ts" | tr 'T' ' ')
    epoch=""
    if command -v date >/dev/null 2>&1; then
        epoch=$(date -d "$ts" +%s 2>/dev/null) || epoch=""
    fi
    if [ -z "$epoch" ] && command -v "$PYTHON_BIN" >/dev/null 2>&1; then
        epoch=$("$PYTHON_BIN" -c 'import sys, time; print(int(time.mktime(time.strptime(sys.argv[1], "%Y-%m-%d %H:%M:%S"))))' "$ts" 2>/dev/null) || epoch=""
    fi
    case "$epoch" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s' "$epoch"
}

proc_start_epoch() {
    # /proc/<pid>/stat 第 22 字段是开机后的 tick 数；btime + ticks/HZ 即启动时刻
    pid="$1"
    [ -r "/proc/$pid/stat" ] || return 1
    btime=$(awk '/^btime[[:space:]]/ { print $2; exit }' /proc/stat 2>/dev/null)
    [ -n "$btime" ] || return 1
    st=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{ print $20 }')
    [ -n "$st" ] || return 1
    hz=""
    if command -v getconf >/dev/null 2>&1; then
        hz=$(getconf CLK_TCK 2>/dev/null)
    fi
    case "${hz:-}" in
        ''|*[!0-9]*) hz=100 ;;
    esac
    printf '%s' "$(( btime + st / hz ))"
}

astrbot_pid() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "$PROC_ASTRBOT" 2>/dev/null | head -n 1
        return 0
    fi
    ps -ef 2>/dev/null | grep -E "$PROC_ASTRBOT" | grep -v grep | awk 'NR == 1 { print $2 }'
}

astrbot_startup() {
    # 输出 "秒数|来源" 或 "|说明"
    hit=""
    if [ -r "$AB_LOG" ]; then
        hit=$(grep -a 'Running on http' "$AB_LOG" 2>/dev/null | tail -n 1)
    fi
    hit_ts=""
    [ -n "$hit" ] && hit_ts=$(log_epoch "$hit")
    pid=$(astrbot_pid)
    start_epoch=""
    [ -n "$pid" ] && start_epoch=$(proc_start_epoch "$pid")

    if [ -n "${hit_ts:-}" ] && [ -n "${start_epoch:-}" ]; then
        sec=$((hit_ts - start_epoch))
        if [ "$sec" -ge 0 ] && [ "$sec" -lt 3600 ]; then
            printf '%s|进程启动 → 日志命中' "$sec"
            return 0
        fi
    fi
    if [ -n "${hit_ts:-}" ] && [ -r "$AB_LOG" ]; then
        first=$(sed -n '1p' "$AB_LOG" 2>/dev/null)
        first_ts=$(log_epoch "$first")
        if [ -n "${first_ts:-}" ] && [ "$hit_ts" -ge "$first_ts" ]; then
            printf '%s|日志首行 → 命中行' "$((hit_ts - first_ts))"
            return 0
        fi
    fi
    if [ -n "$hit" ]; then
        printf '|已命中 Running on http，但算不出起点（需在 AstrBot 启动后、日志未被截断时采）'
    else
        printf '|日志中没有 "Running on http"（可能还没启动完，或日志被轮转）'
    fi
}

startup=$(astrbot_startup)
startup_sec=${startup%%|*}
startup_src=${startup#*|}
printf '%s\n\n' '## 3. AstrBot 启动耗时'
printf '%s\n' '| 项目 | 值 | 说明 |'
printf '%s\n' '|---|---|---|'
if [ -n "$startup_sec" ]; then
    printf '| 进程启动 → 监听就绪 | %s 秒 | 来源：%s |\n' "$startup_sec" "$startup_src"
else
    printf '| 进程启动 → 监听就绪 | N/A | %s |\n' "$startup_src"
fi
printf '\n'

# ---------------- OneBot 往返延迟 ----------------
load_onebot_token() {
    [ -n "$ONEBOT_TOKEN" ] && return 0
    [ -r "$ONEBOT_CFG" ] || return 1
    t=""
    if command -v "$PYTHON_BIN" >/dev/null 2>&1; then
        t=$("$PYTHON_BIN" - "$ONEBOT_CFG" 2>/dev/null <<'PY'
import json
import sys


def walk(obj):
    if isinstance(obj, dict):
        for key, val in obj.items():
            if key in ("accessToken", "access_token") and isinstance(val, str):
                return val
            got = walk(val)
            if got is not None:
                return got
    elif isinstance(obj, list):
        for val in obj:
            got = walk(val)
            if got is not None:
                return got
    return None


try:
    with open(sys.argv[1], encoding="utf-8-sig") as handle:
        data = json.load(handle)
except Exception:
    sys.exit(0)

found = walk(data)
if isinstance(found, str):
    print(found)
PY
)
    fi
    if [ -z "$t" ]; then
        t=$(sed -n 's/.*"accessToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ONEBOT_CFG" 2>/dev/null | head -n 1)
    fi
    ONEBOT_TOKEN="$t"
    return 0
}

onebot_api() {
    action="$1"
    body="$2"
    if [ -n "$ONEBOT_TOKEN" ]; then
        curl -s --max-time "$CURL_MAX" \
            -H "Authorization: Bearer $ONEBOT_TOKEN" \
            -H 'Content-Type: application/json' \
            -d "$body" "$ONEBOT_URL/$action?access_token=$ONEBOT_TOKEN" 2>/dev/null
    else
        curl -s --max-time "$CURL_MAX" \
            -H 'Content-Type: application/json' \
            -d "$body" "$ONEBOT_URL/$action" 2>/dev/null
    fi
}

onebot_sample_ms() {
    if [ -n "$ONEBOT_TOKEN" ]; then
        t=$(curl -s -o /dev/null --max-time "$CURL_MAX" -w '%{time_total}' \
            -H "Authorization: Bearer $ONEBOT_TOKEN" \
            -H 'Content-Type: application/json' \
            -d '{}' "$ONEBOT_URL/get_login_info?access_token=$ONEBOT_TOKEN" 2>/dev/null) || return 1
    else
        t=$(curl -s -o /dev/null --max-time "$CURL_MAX" -w '%{time_total}' \
            -H 'Content-Type: application/json' \
            -d '{}' "$ONEBOT_URL/get_login_info" 2>/dev/null) || return 1
    fi
    case "$t" in
        ''|*[!0-9.]*) return 1 ;;
    esac
    awk -v x="$t" 'BEGIN { printf "%d", x * 1000 }'
}

json_int() {
    printf '%s' "$1" | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p' | head -n 1
}

load_onebot_token >/dev/null 2>&1
o1=$(onebot_sample_ms); [ -n "${o1:-}" ] || o1="-"
o2=$(onebot_sample_ms); [ -n "${o2:-}" ] || o2="-"
o3=$(onebot_sample_ms); [ -n "${o3:-}" ] || o3="-"
if [ "$o1" = "-" ] || [ "$o2" = "-" ] || [ "$o3" = "-" ]; then
    omed="-"
else
    omed=$(median3 "$o1" "$o2" "$o3")
fi

oresp=$(onebot_api get_login_info '{}')
orc=$(json_int "$oresp" retcode)
ouid=$(json_int "$oresp" user_id)

printf '%s\n\n' '## 4. OneBot HTTP 往返延迟（POST /get_login_info，3 次取中位数）'
printf '%s\n' '| 接口 | 第 1 次 (ms) | 第 2 次 (ms) | 第 3 次 (ms) | 中位数 (ms) | retcode | QQ 号 |'
printf '%s\n' '|---|---|---|---|---|---|---|'
printf '| POST /get_login_info | %s | %s | %s | %s | %s | %s |\n\n' \
    "$o1" "$o2" "$o3" "$omed" "${orc:-?}" "${ouid:-未登录}"

# ---------------- 判定参考 ----------------
printf '%s\n\n' '## 5. 判定参考（非硬性，按经验值）'
printf '%s\n' '| 指标 | 正常 | 需要关注 |'
printf '%s\n' '|---|---|---|'
printf '%s\n' '| 端口中位响应 | < 100 ms | > 500 ms |'
printf '%s\n' '| OneBot 往返 | < 50 ms | > 200 ms |'
printf '%s\n' '| AstrBot 启动耗时 | 60–240 s | > 360 s |'
printf '%s\n' '| 1 min 负载 | < nproc | > 2×nproc |'
printf '\n'
printf '> 注：表格是 Markdown，可直接粘进 docs/testing.md；\n'
printf '> 每台平板启动完 24h 内采一次，作为该机的性能基线。\n'

exit 0
