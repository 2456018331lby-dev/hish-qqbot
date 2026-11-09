#!/bin/sh
# e2e_test.sh — 端到端自检
#
# 做三件事（全部在虚机内部、只访问 127.0.0.1）：
#   1) 用 OneBot HTTP POST /send_private_msg 给指定 QQ 发一条「【自检】」，要求 retcode=0
#   2) GET/POST /get_status 验证 OneBot 在线（online/good）
#   3) 读 AstrBot 日志 /root/ab.log 尾部，确认没有 Event loop lag 异常（>15s 记 WARN）
#
# 用法：
#   sh /root/tests/e2e_test.sh                 # 收件人默认 = 机器人自己（从 get_login_info 取）
#   sh /root/tests/e2e_test.sh 3982034942      # 指定收件 QQ
#   TARGET_QQ=123456 sh /root/tests/e2e_test.sh
#   MSG_TEXT='【自检】ping' sh /root/tests/e2e_test.sh
#   LAG_WARN_SEC=20 sh /root/tests/e2e_test.sh
#
# 退出码：0 = 无 FAIL（WARN 不算失败）；1 = 有 FAIL；2 = 参数/环境错误。
#
# 依赖：curl（必需）、python3（可选）、awk/sed（busybox 自带）。

set -u

# ---------------- 可配置项 ----------------
TARGET_QQ="${TARGET_QQ:-}"
MSG_TEXT="${MSG_TEXT:-【自检】}"
ONEBOT_URL="${ONEBOT_URL:-http://127.0.0.1:3000}"
ONEBOT_CFG="${ONEBOT_CFG:-/root/ubuntu/root/sl/config/onebot_3982034942.json}"
ONEBOT_TOKEN="${ONEBOT_TOKEN:-}"
AB_LOG="${AB_LOG:-/root/ab.log}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
CURL_MAX="${CURL_MAX:-10}"            # 发消息/查状态允许慢一点
LAG_WARN_SEC="${LAG_WARN_SEC:-15}"    # Event loop lag 超过这个秒数记 WARN
LAG_TAIL_LINES="${LAG_TAIL_LINES:-200}"
# ------------------------------------------

if [ -n "${1:-}" ]; then
    TARGET_QQ="$1"
fi

PASS_N=0
FAIL_N=0
WARN_N=0

say_pass() {
    PASS_N=$((PASS_N + 1))
    printf 'PASS  %s  -- %s\n' "$1" "$2"
}

say_fail() {
    FAIL_N=$((FAIL_N + 1))
    printf 'FAIL  %s  -- %s\n' "$1" "$2"
}

say_warn() {
    WARN_N=$((WARN_N + 1))
    printf 'WARN  %s  -- %s\n' "$1" "$2"
}

if ! command -v curl >/dev/null 2>&1; then
    echo "FATAL: 找不到 curl，e2e_test 依赖 curl 调 OneBot HTTP" >&2
    exit 2
fi

# ---------------- OneBot 基础 ----------------
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

token_note="未加载 token，按无鉴权调用"
if load_onebot_token; then
    if [ -n "$ONEBOT_TOKEN" ]; then
        token_note="token 已加载"
    else
        token_note="accessToken 为空，按无鉴权调用"
    fi
fi

printf '# e2e_test  %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
printf 'INFO  OneBot=%s  %s\n' "$ONEBOT_URL" "$token_note"
printf '%s\n' '------------------------------------------------------------'

# ---------------- 1. 确定收件人 ----------------
if [ -z "$TARGET_QQ" ]; then
    login_resp=$(onebot_api get_login_info '{}')
    if [ -z "$login_resp" ]; then
        say_fail "确定收件人" "未指定 TARGET_QQ，且 OneBot $ONEBOT_URL 无响应，无法回退用机器人自身 QQ"
        printf '%s\n' '------------------------------------------------------------'
        printf 'PASS 0 / FAIL %s / WARN %s  (共 %s 项)\n' "$FAIL_N" "$WARN_N" "$FAIL_N"
        exit 1
    fi
    TARGET_QQ=$(json_int "$login_resp" user_id)
    if [ -n "$TARGET_QQ" ]; then
        printf 'INFO  未指定收件人，回退为机器人自身 QQ：%s\n' "$TARGET_QQ"
    else
        say_fail "确定收件人" "未指定 TARGET_QQ，且 /get_login_info 没有返回 user_id（QQ 可能未登录）"
        printf '%s\n' '------------------------------------------------------------'
        printf 'PASS 0 / FAIL %s / WARN %s  (共 %s 项)\n' "$FAIL_N" "$WARN_N" "$FAIL_N"
        exit 1
    fi
fi

case "$TARGET_QQ" in
    ''|*[!0-9]*)
        say_fail "确定收件人" "TARGET_QQ 必须是纯数字 QQ 号，当前值：$TARGET_QQ"
        printf '%s\n' '------------------------------------------------------------'
        printf 'PASS 0 / FAIL %s / WARN %s  (共 %s 项)\n' "$FAIL_N" "$WARN_N" "$FAIL_N"
        exit 1
        ;;
esac

printf 'INFO  收件 QQ：%s  消息内容：%s\n' "$TARGET_QQ" "$MSG_TEXT"
printf '%s\n' '------------------------------------------------------------'

# ---------------- 2. 发私聊消息 ----------------
body=$(printf '{"user_id":%s,"message":"%s"}' "$TARGET_QQ" "$MSG_TEXT")
resp=$(onebot_api send_private_msg "$body")
rc=$(json_int "$resp" retcode)
mid=$(json_int "$resp" message_id)

if [ -z "$resp" ]; then
    say_fail "发送私聊消息" "POST $ONEBOT_URL/send_private_msg 无响应（SnowLuma/3000 未起？）"
elif [ "$rc" = "0" ]; then
    if [ -n "$mid" ]; then
        say_pass "发送私聊消息" "user_id=$TARGET_QQ message_id=$mid"
    else
        say_pass "发送私聊消息" "user_id=$TARGET_QQ retcode=0（响应未带 message_id）"
    fi
elif [ -z "$rc" ] && printf '%s' "$resp" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
    say_pass "发送私聊消息" "user_id=$TARGET_QQ status=ok（响应未带 retcode）"
else
    snippet=$(printf '%s' "$resp" | cut -c1-140)
    say_fail "发送私聊消息" "user_id=$TARGET_QQ retcode=${rc:-?}：$snippet"
fi

# ---------------- 3. 在线状态 ----------------
status_resp=$(onebot_api get_status '{}')
src=$(json_int "$status_resp" retcode)
online=$(json_bool "$status_resp" online)
good=$(json_bool "$status_resp" good)

if [ -z "$status_resp" ]; then
    say_fail "OneBot 在线状态" "GET $ONEBOT_URL/get_status 无响应"
elif [ "${src:-}" != "0" ]; then
    snippet=$(printf '%s' "$status_resp" | cut -c1-140)
    say_fail "OneBot 在线状态" "retcode=${src:-?}：$snippet"
elif [ "$online" = "false" ] || [ "$good" = "false" ]; then
    say_fail "OneBot 在线状态" "online=${online:-未返回} good=${good:-未返回}"
else
    say_pass "OneBot 在线状态" "online=${online:-未返回} good=${good:-未返回}"
fi

# ---------------- 4. Event loop lag ----------------
if [ ! -r "$AB_LOG" ]; then
    say_warn "Event loop lag" "$AB_LOG 不存在或不可读，跳过"
else
    stats=$(tail -n "$LAG_TAIL_LINES" "$AB_LOG" 2>/dev/null | awk -v warn="$LAG_WARN_SEC" '
        {
            low = tolower($0)
            if (index(low, "event loop lag") == 0) next
            n++
            p = index(low, "lag")
            rest = substr($0, p + 3)
            if (match(rest, /[0-9]+(\.[0-9]+)?/)) {
                v = substr(rest, RSTART, RLENGTH) + 0
                if (v > maxv) maxv = v
                if (v > warn) bad++
                found = 1
            }
        }
        END {
            if (found) printf "%d %.2f %d", n, maxv, bad
            else printf "%d - 0", n
        }
    ')

    lag_n=$(printf '%s' "$stats" | awk '{ print $1 }')
    lag_max=$(printf '%s' "$stats" | awk '{ print $2 }')
    lag_bad=$(printf '%s' "$stats" | awk '{ print $3 }')

    if [ "${lag_n:-0}" -eq 0 ] 2>/dev/null; then
        say_pass "Event loop lag" "尾部 $LAG_TAIL_LINES 行没有 Event loop lag 记录"
    elif [ "$lag_max" = "-" ]; then
        say_warn "Event loop lag" "命中 lag 关键字但解析不出数值（${lag_n} 条），请人工看一眼 $AB_LOG"
    elif [ "${lag_bad:-0}" -gt 0 ] 2>/dev/null; then
        say_warn "Event loop lag" "最大 ${lag_max}s > 阈值 ${LAG_WARN_SEC}s（${lag_n} 条记录，超阈值 ${lag_bad} 条）"
    else
        say_pass "Event loop lag" "最大 ${lag_max}s ≤ 阈值 ${LAG_WARN_SEC}s（${lag_n} 条记录）"
    fi
fi

# ---------------- 汇总 ----------------
printf '%s\n' '------------------------------------------------------------'
total=$((PASS_N + FAIL_N + WARN_N))
printf 'PASS %s / FAIL %s / WARN %s  (共 %s 项)\n' "$PASS_N" "$FAIL_N" "$WARN_N" "$total"
if [ "$FAIL_N" -gt 0 ]; then
    printf 'RESULT: FAIL\n'
    exit 1
fi
if [ "$WARN_N" -gt 0 ]; then
    printf 'RESULT: OK（有 %s 项 WARN，建议人工确认）\n' "$WARN_N"
    exit 0
fi
printf 'RESULT: OK\n'
exit 0
