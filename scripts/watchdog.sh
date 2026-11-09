#!/bin/sh
# watchdog.sh —— 30 秒巡检 + 崩溃自愈（Xvfb / QQ / SnowLuma / AstrBot 四项）
#
# 用途：让 QQ / SnowLuma / Xvfb / AstrBot 在崩溃后自动恢复。
#       TCG 全模拟下 Linux QQ 偶发原生崩溃，人工重启太慢，需要无人值守自愈。
#       巡检间隔由环境变量 INTERVAL 控制，默认 30 秒。
# 依赖：
#   - HiSH 自带 Alpine 的 /bin/sh、pgrep、curl（busybox wget 不算，这里用的是 curl）
#   - /root/ubuntu：Ubuntu 24.04 arm64 chroot，内含 Xvfb / xdpyinfo / Linux QQ
#   - /root/restart_snowluma.sh、/root/restart_astrbot.sh（本仓库 scripts/ 下同名脚本）
# 日志：/root/watchdog.log（每 30 秒一行事件）
# 状态：/root/watchdog.state（最后一次巡检快照：x / qq / sl / ab）
# 用法：nohup sh /root/watchdog.sh >/dev/null 2>&1 &
# 安全提示：
#   - 只在本机回环上判断，不对外开放任何端口，无鉴权面。
#   - 它会 `pkill -9 -f Xvfb`，所以别在同一个 Alpine 里跑第二个需要 X 的服务。
#   - AstrBot 有 20 次（约 10 分钟）宽容期才强杀重启 —— 改这个数字前先读下面的注释，
#     冷启动本来就是 6~10 分钟，杀早了等于永远起不来。
set -u
R=/root/ubuntu
LOG=/root/watchdog.log
INTERVAL=${INTERVAL:-30}

log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"; }

x_ok()  { chroot "$R" /bin/bash -c 'DISPLAY=:99 xdpyinfo >/dev/null 2>&1'; }
qq_pid(){ pgrep -f "[q]q --no-sandbox" | head -1; }
sl_pid(){ pgrep -f "[i]ndex.mjs" | head -1; }
ab_pid(){ pgrep -f "[m]ain.py" | head -1; }
port_up(){ curl -s -o /dev/null --max-time 5 "http://127.0.0.1:$1/" ; }

start_x() {
  log "Xvfb 不在，重启"
  pkill -9 -f "[X]vfb" 2>/dev/null
  rm -f "$R/tmp/.X99-lock" "$R/tmp/.X11-unix/X99" 2>/dev/null
  mkdir -p "$R/tmp/.X11-unix" && chmod 1777 "$R/tmp/.X11-unix"
  chroot "$R" /bin/bash -c 'nohup /usr/bin/Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >/root/xvfb.log 2>&1 &'
  sleep 8
}

start_qq() {
  log "QQ 不在，重启"
  chroot "$R" /bin/bash -c 'cd /root && DISPLAY=:99 nohup /opt/QQ/qq --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-software-rasterizer >/root/qq.log 2>&1 &'
  sleep 30
  # QQ 起来后 SnowLuma 的 hook 会失效，10 秒后重启它以重新注入
  ( sleep 20; sh /root/restart_snowluma.sh >/dev/null 2>&1; log "QQ 重启后已重挂 SnowLuma" ) &
}

start_sl() {
  log "SnowLuma 不在，重启"
  sh /root/restart_snowluma.sh >/dev/null 2>&1
}

log "=== watchdog start (interval=${INTERVAL}s) ==="
fail_ab=0
while true; do
  # 1. X
  if ! x_ok; then start_x; fi
  # 2. QQ
  if [ -z "$(qq_pid)" ]; then start_qq; fi
  # 3. SnowLuma（QQ 在但 SnowLuma 不在时才拉，避免顺序错）
  if [ -z "$(sl_pid)" ] && [ -n "$(qq_pid)" ]; then start_sl; fi
  # 4. AstrBot：端口不通且进程也不在才重启（启动要 6 分钟，别乱杀）
  if [ -z "$(ab_pid)" ]; then
    log "AstrBot 进程不在，拉起"
    sh /root/restart_astrbot.sh >/dev/null 2>&1
    fail_ab=0
  else
    if port_up 6185; then
      fail_ab=0
    else
      # 启动期不杀：AstrBot 冷启动在 TCG 下要 5-10 分钟，14 插件时更久。
      # 只有「6185 连续不通 15 次(约 7.5min) 且 ab.log 已 8 分钟没更新」才判定真卡死。
      idle=$(( $(date +%s) - $(stat -c %Y /root/ab.log 2>/dev/null || echo 0) ))
      fail_ab=$((fail_ab + 1))
      if [ "$fail_ab" -ge 15 ] && [ "$idle" -gt 480 ]; then
        log "AstrBot 卡死（6185 不通 ${fail_ab} 次，ab.log 已 ${idle}s 无更新），重启"
        sh /root/restart_astrbot.sh >/dev/null 2>&1
        fail_ab=0
      fi
    fi
  fi
  {
    echo "ts=$(date '+%H:%M:%S')"
    echo "x=$(x_ok && echo 1 || echo 0)"
    echo "qq=$(qq_pid)"
    echo "sl=$(sl_pid)"
    echo "ab=$(ab_pid)"
  } > /root/watchdog.state
  sleep "$INTERVAL"
done
