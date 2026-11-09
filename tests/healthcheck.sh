#!/bin/sh
# healthcheck.sh — 鸿蒙平板机器人「一次性健康检查」
#
# 运行位置：Alpine 3.22（HiSH 虚机内）的 /root 侧，脚本只读、不改任何东西。
# 设计约束：
#   * 纯 POSIX sh（busybox ash 可跑）：不用 bash 数组 / [[ ]] / ${var,,}
#   * 所有请求只发往 127.0.0.1，不碰平板、不碰 192.168.x.x
#   * 每项输出 "PASS|FAIL  名称  -- 细节"，最后汇总 "X/Y passed"；
#     有 FAIL 时退出码为 1（脚本只读，可反复跑）
#
# 用法：
#   sh /root/tests/healthcheck.sh
#   PORTS=6185,8080 sh /root/tests/healthcheck.sh       # 只查部分端口
#   ONEBOT_TOKEN=xxxx sh /root/tests/healthcheck.sh     # 手填 token，不读配置文件
#   CURL_MAX=3 sh /root/tests/healthcheck.sh            # 网络慢时放宽超时
#
# 依赖：curl（必需）；python3（可选，用来稳妥地解析 OneBot token）；
#       pgrep / ps / netstat（busybox 自带，缺了会自动降级）。

set -u

# ---------------- 可配置项（集中在这里，别散落到下面） ----------------
AB_URL="${AB_URL:-http://127.0.0.1:6185}"
SL_PANEL_URL="${SL_PANEL_URL:-http://127.0.0.1:5099}"
ONEBOT_URL="${ONEBOT_URL:-http://127.0.0.1:3000}"
ONEBOT_CFG="${ONEBOT_CFG:-/root/ubuntu/root/sl/config/onebot_3982034942.json}"
ONEBOT_TOKEN="${ONEBOT_TOKEN:-}"      # 非空则直接用，不再读配置文件
PYTHON_BIN="${PYTHON_BIN:-python3}"
CURL_MAX="${CURL_MAX:-5}"             # 每个 curl 的 --max-time（秒）
PORTS="${PORTS:-6185,8080,6080,5099}" # 需要监听的四端口（HiSH 映射表）
PROC_XVFB="${PROC_XVFB:-Xvfb :99}"
PROC_QQ="${PROC_QQ:-/opt/QQ/qq}"
PROC_SNOWLUMA="${PROC_SNOWLUMA:-index[.]mjs}"
PROC_ASTRBOT="${PROC_ASTRBOT:-main[.]py}"
# ----------------------------------------------------------------------

PASS_N=0
FAIL_N=0

say_pass() {
    PASS_N=$((PASS_N + 1))
    printf 'PASS  %s  -- %s\n' "$1" "$2"
}

say_fail() {
    FAIL_N=$((FAIL_N + 1))
    printf 'FAIL  %s  -- %s\n' "$1" "$2"
}

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

# ---------------- 进程检查 ----------------
proc_pids() {
    pattern="$1"
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "$pattern" 2>/dev/null | head -n 3 | tr '\n' ' ' | sed 's/[[:space:]]*$//'
        return 0
    fi
    # 没有 pgrep 时退化成 ps + grep（busybox 一定带 ps）
    ps -ef 2>/dev/null | grep -E "$pattern" | grep -v grep | awk '{print $2}' \
        | head -n 3 | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

proc_etime() {
    pid="$1"
    if command -v ps >/dev/null 2>&1; then
        e=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' \n')
        case "$e" in
            ''|*[!0-9:-]*) return 0 ;;   # 空/表头/格式异常都当没有
        esac
        printf '%s' "$e"
    fi
}

check_proc() {
    name="$1"
    pattern="$2"
    pids=$(proc_pids "$pattern")
    if [ -n "$pids" ]; then
        pid=$(printf '%s' "$pids" | awk '{print $1}')
        et=$(proc_etime "$pid")
        if [ -n "$et" ]; then
            say_pass "$name" "运行中 pid=$pids (etime=$et)"
        else
            say_pass "$name" "运行中 pid=$pids"
        fi
    else
        say_fail "$name" "未找到进程 (pgrep -f '$pattern')"
    fi
}

# ---------------- 端口监听检查 ----------------
# 先试 netstat -lnt；不行就读 /proc/net/tcp{,6} 的 LISTEN(0A) 状态。
port_listen() {
    port="$1"
    if command -v netstat >/dev/null 2>&1; then
        if netstat -lnt 2>/dev/null | awk -v p=":$port" 'NR > 1 && $4 ~ (p "$") { f = 1 } END { exit(f ? 0 : 1) }'; then
            return 0
        fi
    fi
    hex=$(printf '%04X' "$port" 2>/dev/null)
    [ -n "$hex" ] || return 1
    for f in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$f" ] || continue
        if awk -v hp="$hex" 'NR > 1 { n = split($2, a, ":"); if (toupper(a[n]) == toupper(hp) && $4 == "0A") { f = 1 } } END { exit(f ? 0 : 1) }' "$f" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

check_port() {
    port="$1"
    label=$(port_label "$port")
    if port_listen "$port"; then
        say_pass "端口 $port" "$label 正在监听"
    else
        say_fail "端口 $port" "$label 未监听"
    fi
}

# ---------------- HTTP 检查 ----------------
http_probe() {
    url="$1"
    out=$(curl -s -o /dev/null --max-time "$CURL_MAX" -w '%{http_code} %{time_total}' "$url" 2>/dev/null)
    printf '%s' "$out"
}

check_http() {
    name="$1"
    url="$2"
    res=$(http_probe "$url")
    code=${res%% *}
    t=${res##* }
    case "$code" in
        2[0-9][0-9])
            say_pass "$name" "GET $url -> $code (${t}s)"
            ;;
        ''|000)
            say_fail "$name" "GET $url 无响应（curl 失败/超时 ${CURL_MAX}s）"
            ;;
        *)
            say_fail "$name" "GET $url -> $code（期望 2xx）"
            ;;
    esac
}

# ---------------- OneBot / QQ 登录检查 ----------------
load_onebot_token() {
    # 返回 0 = 可以继续（有 token，或配置里 token 为空 -> 按无鉴权调用）
    # 返回 1 = 配置文件都读不到（仍会按无鉴权调用，由调用方决定怎么提示）
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

json_int() {
    printf '%s' "$1" | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p' | head -n 1
}

json_str() {
    printf '%s' "$1" | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

json_bool() {
    v=$(printf '%s' "$1" | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*\(true\).*/\1/p' | head -n 1)
    [ -n "$v" ] || v=$(printf '%s' "$1" | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*\(false\).*/\1/p' | head -n 1)
    printf '%s' "$v"
}

check_qq_login() {
    token_note="未配置 token，按无鉴权调用"
    if load_onebot_token; then
        if [ -n "$ONEBOT_TOKEN" ]; then
            token_note="token 已加载"
        else
            token_note="配置里 accessToken 为空，按无鉴权调用"
        fi
    else
        token_note="读不到 $ONEBOT_CFG 且未设置 ONEBOT_TOKEN，按无鉴权调用"
    fi

    resp=$(onebot_api get_login_info '{}')
    if [ -z "$resp" ]; then
        say_fail "QQ 登录" "OneBot HTTP $ONEBOT_URL/get_login_info 无响应（SnowLuma/3000 未起？）"
        return 0
    fi

    rc=$(json_int "$resp" retcode)
    uid=$(json_int "$resp" user_id)
    nick=$(json_str "$resp" nickname)

    if [ "$rc" = "0" ] && [ -n "$uid" ]; then
        say_pass "QQ 登录" "user_id=$uid nickname=${nick:-未返回}（$token_note）"
        return 0
    fi

    status_resp=$(onebot_api get_status '{}')
    online=$(json_bool "$status_resp" online)
    if [ "$online" = "true" ] || { [ "$rc" = "0" ] && [ -z "$uid" ]; }; then
        say_fail "QQ 登录" "OneBot 在线但 QQ 未登录（retcode=${rc:-?}, online=${online:-未知}, $token_note）"
    else
        snippet=$(printf '%s' "$resp" | cut -c1-100)
        say_fail "QQ 登录" "get_login_info 失败（retcode=${rc:-?}, $token_note）：$snippet"
    fi
}

# ---------------- 主流程 ----------------
if ! command -v curl >/dev/null 2>&1; then
    echo "FATAL: 找不到 curl，healthcheck 依赖 curl 探测 HTTP/OneBot" >&2
    exit 2
fi

printf '# healthcheck  %s  (%s %s)\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "$(uname -s 2>/dev/null)" \
    "$(uname -m 2>/dev/null)"
printf '%s\n' '------------------------------------------------------------'

check_proc "Xvfb"     "$PROC_XVFB"
check_proc "QQ"       "$PROC_QQ"
check_proc "SnowLuma" "$PROC_SNOWLUMA"
check_proc "AstrBot"  "$PROC_ASTRBOT"

printf '%s\n' '------------------------------------------------------------'

for p in $(printf '%s' "$PORTS" | tr ',' ' '); do
    check_port "$p"
done

printf '%s\n' '------------------------------------------------------------'

check_http "AstrBot HTTP"  "$AB_URL/"
check_http "SnowLuma 面板" "$SL_PANEL_URL/"
check_qq_login

printf '%s\n' '------------------------------------------------------------'
total=$((PASS_N + FAIL_N))
printf '%s/%s passed\n' "$PASS_N" "$total"
if [ "$FAIL_N" -gt 0 ]; then
    printf 'RESULT: FAIL（%s 项失败）\n' "$FAIL_N"
    exit 1
fi
printf 'RESULT: OK\n'
exit 0
