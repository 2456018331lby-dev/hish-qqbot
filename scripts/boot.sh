#!/bin/sh
# boot.sh —— HiSH Alpine 侧一键启动机器人全套（6 个阶段）
#
# 用途：由 /root/.profile 在登录时后台调用，实现「开虚机即自动跑起来」；
#       也可手动 `sh /root/boot.sh` 救火。幂等：已在跑的进程不会被重复拉起。
# 顺序：挂 proc/dev/sys → Xvfb :99 → Linux QQ → AstrBot → SnowLuma
#       → x11vnc + noVNC → 控制台 + 远程通道 → 打印状态
# 依赖：
#   - HiSH 自带 Alpine 3.22 的 /bin/sh、pgrep、netstat（netstat 来自 busybox-extras）
#   - /root/ubuntu：Ubuntu 24.04 arm64 chroot，内含 Xvfb / Linux QQ / SnowLuma / x11vnc / websockify
#   - /root/src/AstrBot-master + /root/venv：AstrBot 源码与虚拟环境
#   - /root/panel.py（本仓库 scripts/panel_v3.py）、/root/z2.sh、/root/novnc
# 日志：/root/boot.log（调用方重定向）、/tmp/xvfb.log、/tmp/qq.out、/root/ab.log、
#       /root/sl.log、/root/x11vnc.log、/root/ws.log、/root/panel.log
# 注意：x11vnc 用 -nopw 且只供本机 websockify 连接；把 5900/6080 暴露到公网前必须自己加鉴权。
R=/root/ubuntu

mount -t proc proc $R/proc 2>/dev/null
mount --bind /dev $R/dev 2>/dev/null
mount --bind /sys $R/sys 2>/dev/null

echo "[1/6] Xvfb"
if ! pgrep -f "Xvfb :99" >/dev/null; then
  ( nohup chroot $R /bin/bash -c 'Xvfb :99 -screen 0 1280x800x24 -nolisten tcp' >/tmp/xvfb.log 2>&1 & )
fi
sleep 4

echo "[2/6] QQ"
if ! pgrep -f "/opt/QQ/qq" >/dev/null; then
  ( nohup chroot $R /bin/bash -c 'DISPLAY=:99 /opt/QQ/qq --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-software-rasterizer' >/tmp/qq.out 2>&1 & )
fi
sleep 10

echo "[3/6] AstrBot"
if ! pgrep -f "main[.]py" >/dev/null; then
  ( cd /root/src/AstrBot-master && . /root/venv/bin/activate && nohup python3 -u main.py > /root/ab.log 2>&1 & )
fi

echo "[4/6] SnowLuma"
if ! chroot $R /bin/bash -c 'pgrep -f index.mjs' >/dev/null; then
  ( nohup chroot $R /bin/bash -c 'cd /root/sl && ./launcher.sh' > /root/sl.log 2>&1 & )
fi
sleep 6

echo "[5/6] 远程桌面 (x11vnc + noVNC)"
if ! chroot $R /bin/bash -c 'pgrep -f "x11vnc -display"' >/dev/null; then
  ( nohup chroot $R /bin/bash -c 'x11vnc -display :99 -forever -shared -nopw -rfbport 5900' > /root/x11vnc.log 2>&1 & )
fi
sleep 3
if ! chroot $R /bin/bash -c 'pgrep -f websockify' >/dev/null; then
  ( nohup chroot $R /bin/bash -c 'websockify --web /root/novnc 6080 127.0.0.1:5900' > /root/ws.log 2>&1 & )
fi

echo "[6/6] 控制台 + 远程通道"
if ! pgrep -f "panel[.]py" >/dev/null; then
  ( nohup python3 -u /root/panel.py > /root/panel.log 2>&1 & )
fi
if ! pgrep -f "z2[.]sh" >/dev/null; then
  ( nohup sh /root/z2.sh >/dev/null 2>&1 & )
fi
sleep 4

echo "--- 状态 ---"
pgrep -f "Xvfb :99" >/dev/null && echo "Xvfb: OK" || echo "Xvfb: FAIL"
pgrep -f "/opt/QQ/qq" >/dev/null && echo "QQ: OK" || echo "QQ: FAIL"
pgrep -f "main[.]py" >/dev/null && echo "AstrBot: OK" || echo "AstrBot: FAIL"
chroot $R /bin/bash -c 'pgrep -f index.mjs' >/dev/null && echo "SnowLuma: OK" || echo "SnowLuma: FAIL"
pgrep -f "panel[.]py" >/dev/null && echo "控制台: OK" || echo "控制台: FAIL"
netstat -ltn 2>/dev/null | grep -E "5099|5900|6080|6185|6199|8080"
echo "BOOT_DONE"
