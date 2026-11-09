#!/bin/sh
# quick.sh —— 平板回来后的「一次过」修复脚本（在 VM 里跑，幂等）
#
# 用途：把 Xvfb / QQ / SnowLuma / AstrBot / 控制台 / vyceai 代理 / 看门狗 全部拉齐，
#       最后打印一份体检结果（8 个阶段自检 + 负载/内存/nproc）。
#       它不是「装」脚本，是「修」脚本：已经好的东西一律跳过，可以反复跑。
# 依赖：
#   - HiSH 自带 Alpine：/bin/sh、busybox mount/mountpoint、wget、curl、pgrep、seq
#   - /root/ubuntu：Ubuntu 24.04 arm64 chroot（内含 Xvfb / Linux QQ）
#   - /root/restart_snowluma.sh、/root/restart_astrbot.sh、/root/panel.py、/root/watchdog.sh
#   - 可选 /root/vyceai_proxy.py（存在才拉起，端口 8790）
# 日志：/root/quick.log（stdout 同时 tee 进去）；子进程日志沿用
#       /root/xvfb.log、/root/qq.log、/root/ab.log、/root/panel.log、/root/vyceai_proxy.log
# 用法（VM 终端一行）：
#   wget -q -O /root/quick.sh http://<PC_IP>/quick.sh && sh /root/quick.sh
#   或者已有 z2 通道时：PC 侧改 cmd.txt 内容即可。
# 安全提示：
#   - 会 `pkill -9 -f Xvfb` 并删 X 锁，属于破坏性动作；只在对平板自己的 VM 上用。
#   - 第 7 步会读取 SnowLuma 的 OneBot 配置取 accessToken 打本地 3000 端口，
#     只走 127.0.0.1，不要把这行改到外网地址上。
set -u
R=/root/ubuntu
LOG=/root/quick.log
: > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }

PC_IP=${PC_IP:-}
[ -n "$PC_IP" ] || say "WARN: 未设置 PC_IP，跳过需要从 PC 拉文件的步骤（export PC_IP=...）"

say "=== quick.sh $(date '+%F %T') ==="

# ---------- 0. 目录/挂载自检 ----------
[ -d "$R/root" ] || { say "FATAL: $R 不存在，Ubuntu chroot 丢失"; exit 1; }
for d in proc dev sys; do
  mountpoint -q "$R/$d" || mount --bind "/$d" "$R/$d" 2>/dev/null || say "WARN: 挂 $d 失败"
done

# ---------- 0.5 登录自启 hook 自愈（把 .profile 指向 quick.sh，而不是一次性 boot.sh）----------
# PROFILE_HOOK_V2
if ! grep -q "PROFILE_HOOK_V2" /root/.profile 2>/dev/null; then
  say "写入 /root/.profile 自启钩子"
  { echo "#!/bin/sh"
    echo "# PROFILE_HOOK_V2 —— 登录 shell 自动拉起机器人全套（幂等）"
    echo 'if [ -z "$BOTSTACK_STARTED" ]; then export BOTSTACK_STARTED=1; nohup sh /root/quick.sh >/root/boot.log 2>&1 & fi'
  } > /root/.profile && chmod 644 /root/.profile
fi

# 控制台登录用的后台密码（不在仓库里存；需要时由部署者通过 AB_PASS 传入一次）
if [ -n "${AB_PASS:-}" ]; then
  printf '%s' "$AB_PASS" > /root/.abpass && chmod 600 /root/.abpass && say "已写入 /root/.abpass"
fi

# ---------- 1. 清 X 残留并拉起 Xvfb ----------
if ! chroot "$R" /bin/bash -c 'DISPLAY=:99 xdpyinfo >/dev/null 2>&1'; then
  say "X 不可用，清理锁并重启"
  pkill -9 -f "[X]vfb" 2>/dev/null
  rm -f "$R/tmp/.X99-lock" "$R/tmp/.X11-unix/X99" /tmp/.X99-lock 2>/dev/null
  mkdir -p "$R/tmp/.X11-unix" && chmod 1777 "$R/tmp/.X11-unix"
  chroot "$R" /bin/bash -c 'nohup /usr/bin/Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >/root/xvfb.log 2>&1 &'
  sleep 8
fi
if chroot "$R" /bin/bash -c 'DISPLAY=:99 xdpyinfo >/dev/null 2>&1'; then
  say "X=OK"
else
  say "X=FAIL（看 $R/root/xvfb.log）"
fi

# ---------- 2. QQ ----------
if [ -z "$(pgrep -f '[q]q --no-sandbox' | head -1)" ]; then
  say "QQ 不在，启动"
  if [ -x "$R/root/start_qq.sh" ]; then
    chroot "$R" /bin/bash -c 'cd /root && DISPLAY=:99 nohup sh /root/start_qq.sh >/root/qq.log 2>&1 &'
  else
    chroot "$R" /bin/bash -c 'cd /root && DISPLAY=:99 nohup /opt/QQ/qq --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-software-rasterizer >/root/qq.log 2>&1 &'
  fi
  sleep 35
fi
# ---------- 3. SnowLuma ----------
if [ -z "$(pgrep -f '[i]ndex.mjs' | head -1)" ]; then
  say "SnowLuma 不在，启动"
  sh /root/restart_snowluma.sh >/dev/null 2>&1
  sleep 25
fi
[ -n "$(pgrep -f '[i]ndex.mjs' | head -1)" ] && say "SnowLuma=OK" || say "SnowLuma=FAIL"

# ---------- 4. AstrBot ----------
if [ -z "$(pgrep -f '[m]ain.py' | head -1)" ]; then
  say "AstrBot 不在，启动"
  sh /root/restart_astrbot.sh >/dev/null 2>&1
fi
ab=""
for i in $(seq 1 40); do
  ab=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:6185/ 2>/dev/null)
  [ "$ab" = "200" ] && break
  sleep 15
done
say "AstrBot=$ab"

# ---------- 5. 控制台 / 代理 ----------
[ -f /root/.abpass ] || say "WARN: 没有 /root/.abpass —— 控制台登录 AstrBot 会失败；执行：printf '%s' '你的AstrBot后台密码' > /root/.abpass && chmod 600 /root/.abpass"
if [ -n "$PC_IP" ]; then
  wget -q -O /root/panel.py.new "http://$PC_IP/panel_v3.py" 2>/dev/null \
    && { cmp -s /root/panel.py.new /root/panel.py || { cp -f /root/panel.py.new /root/panel.py; say "控制台已更新到 v3"; }; }
  rm -f /root/panel.py.new
fi
if [ -z "$(pgrep -f '[p]anel.py' | head -1)" ]; then
  say "控制台不在，启动"
  nohup python3 /root/panel.py >/root/panel.log 2>&1 &
  sleep 3
fi
curl -s -o /dev/null -w 'panel=%{http_code}\n' --max-time 6 http://127.0.0.1:8080/api/status | tee -a "$LOG"

if [ -z "$(pgrep -f '[v]yceai_proxy.py' | head -1)" ] && [ -f /root/vyceai_proxy.py ]; then
  nohup python3 /root/vyceai_proxy.py >/root/vyceai_proxy.log 2>&1 &
  say "vyceai 代理已拉起（端口 8790）"
fi

# ---------- 6. 看门狗 ----------
if [ -z "$(pgrep -f '[w]atchdog.sh' | head -1)" ]; then
  say "看门狗不在，启动"
  nohup sh /root/watchdog.sh >/dev/null 2>&1 &
  sleep 2
fi
pgrep -f '[w]atchdog.sh' >/dev/null 2>&1 && say "watchdog=OK" || say "watchdog=FAIL"

# ---------- 7. OneBot 链路 ----------
TOK=$(python3 - <<'PY' 2>/dev/null
import json
try:
    c=json.load(open('/root/ubuntu/root/sl/config/onebot_3982034942.json',encoding='utf-8'))
    print((c.get('networks') or {}).get('httpServers',[{}])[0].get('accessToken',''))
except Exception:
    print('')
PY
)
if [ -n "$TOK" ]; then
  say "OneBot=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer $TOK" http://127.0.0.1:3000/get_login_info)"
else
  say "OneBot=NO_TOKEN"
fi
say "适配器连接次数=$(grep -c 适配器已连接 /root/ab.log 2>/dev/null)"

# ---------- 8. 体检快照 ----------
say "--- 负载/内存 ---"
uptime | tee -a "$LOG"
free -m | sed -n '2p' | tee -a "$LOG"
say "panel_settings=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://127.0.0.1:8080/settings)"
say "panel_quick=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://127.0.0.1:8080/quick)"
say "nproc=$(nproc)"
say "=== quick.sh done $(date '+%T') ==="
