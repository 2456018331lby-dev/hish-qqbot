#!/bin/sh
# stress_light.sh — 轻量稳定性观察（30 次 × 20 秒）
#
# 每隔 INTERVAL 秒采一次「关键项」存活状态，追加一行 CSV 到 /root/stability.csv：
#     ts,qq,snowluma,astrbot,xvfb,load
#   * 1 = 存活，0 = 不存活（astrbot/snowluma 还要求对应端口在监听，避免「进程活着但服务死了」）
#   * load = 1 分钟负载（/proc/loadavg 第一列）
#
# 跑完（或被 Ctrl-C 打断）后，按本次运行的采样点统计：
#   * 每个组件的失败次数、可用率
#   * 从 0 恢复为 1 的次数、平均/最大恢复耗时（秒）
# 统计结果同时追加到 /root/stability_summary.txt。
#
# 用法：
#   sh /root/tests/stress_light.sh              # 默认 30 次 × 20 秒（约 10 分钟）
#   sh /root/tests/stress_light.sh 60 30        # 60 次 × 30 秒（约 30 分钟）
#   CSV_FILE=/tmp/s.csv ITER=5 INTERVAL=2 sh /root/tests/stress_light.sh   # 快速冒烟
#
# 只读脚本：只写 CSV 和 summary 两个文件，不重启任何服务。
# 依赖：pgrep/ps（busybox 自带）；端口探活用 netstat 或 /proc/net/tcp。

set -u

# ---------------- 可配置项 ----------------
CSV_FILE="${CSV_FILE:-/root/stability.csv}"
SUMMARY_FILE="${SUMMARY_FILE:-/root/stability_summary.txt}"
ITER="${1:-${ITER:-30}}"
INTERVAL="${2:-${INTERVAL:-20}}"
AB_PORT="${AB_PORT:-6185}"
SL_PORT="${SL_PORT:-3000}"
PROC_XVFB="${PROC_XVFB:-Xvfb :99}"
PROC_QQ="${PROC_QQ:-/opt/QQ/qq}"
PROC_SNOWLUMA="${PROC_SNOWLUMA:-index[.]mjs}"
PROC_ASTRBOT="${PROC_ASTRBOT:-main[.]py}"
# ------------------------------------------

case "$ITER" in
    ''|*[!0-9]*) echo "ITER 必须是正整数：$ITER" >&2; exit 2 ;;
esac
case "$INTERVAL" in
    ''|*[!0-9]*) echo "INTERVAL 必须是整数秒：$INTERVAL" >&2; exit 2 ;;
esac
[ "$ITER" -gt 0 ] || { echo "ITER 必须 > 0" >&2; exit 2; }

# ---------------- 探活原语 ----------------
proc_alive() {
    pattern="$1"
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "$pattern" >/dev/null 2>&1
        return $?
    fi
    ps -ef 2>/dev/null | grep -E "$pattern" | grep -v grep >/dev/null 2>&1
}

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

check_xvfb() {
    if proc_alive "$PROC_XVFB"; then printf 1; else printf 0; fi
}

check_qq() {
    if proc_alive "$PROC_QQ"; then printf 1; else printf 0; fi
}

check_snowluma() {
    if proc_alive "$PROC_SNOWLUMA" && port_listen "$SL_PORT"; then printf 1; else printf 0; fi
}

check_astrbot() {
    if proc_alive "$PROC_ASTRBOT" && port_listen "$AB_PORT"; then printf 1; else printf 0; fi
}

# ---------------- 汇总（本次运行） ----------------
summarize() {
    summary=$(awk -F',' -v start="$START_TS" '
        BEGIN {
            names[2] = "qq"
            names[3] = "snowluma"
            names[4] = "astrbot"
            names[5] = "xvfb"
        }
        NR == 1 { next }
        {
            if ($1 + 0 < start + 0) next
            n++
            for (c = 2; c <= 5; c++) {
                v = $c + 0
                if (v == 0) {
                    fails[c]++
                    if (!down[c]) {
                        down[c] = 1
                        since[c] = $1 + 0
                    }
                } else if (down[c]) {
                    down[c] = 0
                    rec = $1 + 0 - since[c]
                    if (rec < 0) rec = 0
                    recs[c]++
                    total[c] += rec
                    if (rec > max[c]) max[c] = rec
                }
            }
        }
        END {
            printf "%-9s %6s %6s %9s %9s %11s %11s  %s\n", \
                "component", "samples", "failed", "avail", "recovery", "avg(s)", "max(s)", "state"
            for (c = 2; c <= 5; c++) {
                avail = (n > 0) ? (100 * (n - fails[c]) / n) : 0
                avg = (recs[c] > 0) ? total[c] / recs[c] : 0
                state = (down[c] == 1) ? "DOWN(unrecovered)" : "UP"
                printf "%-9s %6d %6d %8.1f%% %9d %11.1f %11d  %s\n", \
                    names[c], n, fails[c], avail, recs[c], avg, max[c], state
            }
        }
    ' "$CSV_FILE" 2>/dev/null)

    printf '\n汇总（本次运行 起点=%s 采样=%s/%s 间隔=%ss）：\n' "$START_TS" "$DONE" "$ITER" "$INTERVAL"
    printf '%s\n' "$summary"

    {
        printf '\n=== %s  start=%s samples=%s interval=%ss csv=%s ===\n' \
            "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$START_TS" "$DONE" "$INTERVAL" "$CSV_FILE"
        printf '%s\n' "$summary"
    } >> "$SUMMARY_FILE" 2>/dev/null || true
}

on_signal() {
    printf '\n收到中断信号，先汇总已采到的数据…\n'
    summarize
    printf 'CSV 已保存在 %s\n' "$CSV_FILE"
    exit 130
}

# ---------------- 主流程 ----------------
if [ ! -s "$CSV_FILE" ]; then
    printf 'ts,qq,snowluma,astrbot,xvfb,load\n' > "$CSV_FILE" 2>/dev/null || {
        echo "FATAL: 无法写 $CSV_FILE" >&2
        exit 2
    }
fi

START_TS=$(date +%s)
DONE=0
qq_fail=0
sl_fail=0
ab_fail=0
xvfb_fail=0

trap 'on_signal' INT TERM

printf '# stress_light  %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
printf '采样 %s 次 × %s 秒，写入 %s（只追加，不覆盖历史）\n' "$ITER" "$INTERVAL" "$CSV_FILE"
printf '%s\n' '------------------------------------------------------------'

i=1
while [ "$i" -le "$ITER" ]; do
    ts=$(date +%s)
    qq=$(check_qq)
    sl=$(check_snowluma)
    ab=$(check_astrbot)
    xv=$(check_xvfb)
    load=$(awk '{ print $1 }' /proc/loadavg 2>/dev/null)
    case "${load:-}" in
        ''|*[!0-9.]*) load=0 ;;
    esac

    printf '%s,%s,%s,%s,%s,%s\n' "$ts" "$qq" "$sl" "$ab" "$xv" "$load" >> "$CSV_FILE"

    DONE=$((DONE + 1))
    [ "$qq" = "1" ] || qq_fail=$((qq_fail + 1))
    [ "$sl" = "1" ] || sl_fail=$((sl_fail + 1))
    [ "$ab" = "1" ] || ab_fail=$((ab_fail + 1))
    [ "$xv" = "1" ] || xvfb_fail=$((xvfb_fail + 1))

    printf '[%s/%s] ts=%s qq=%s snowluma=%s astrbot=%s xvfb=%s load=%s | 累计失败 qq=%s sl=%s ab=%s xvfb=%s\n' \
        "$DONE" "$ITER" "$ts" "$qq" "$sl" "$ab" "$xv" "$load" \
        "$qq_fail" "$sl_fail" "$ab_fail" "$xvfb_fail"

    i=$((i + 1))
    if [ "$i" -le "$ITER" ]; then
        sleep "$INTERVAL"
    fi
done

trap - INT TERM
summarize
printf 'CSV: %s\n汇总: %s\n' "$CSV_FILE" "$SUMMARY_FILE"
if [ "$qq_fail" -gt 0 ] || [ "$sl_fail" -gt 0 ] || [ "$ab_fail" -gt 0 ] || [ "$xvfb_fail" -gt 0 ]; then
    exit 1
fi
exit 0
