#!/bin/sh
# hide_qq.sh —— 开机后把 QQ 窗口从 Xvfb 上 unmap（隐藏），省 CPU
#
# 用途：无 GPU 的纯软件渲染下，QQ 窗口只要可见就持续重绘，实测吃掉 40%+ CPU；
#       unmap 后 QQ 仍在运行、消息照收，只是不再画。
# 依赖：chroot /root/ubuntu 里的 xdotool；窗口标题需精确匹配 ^QQ$。
# 时序：先 sleep 210 秒等 QQ 登录完成，再最多重试 6 次（每次间隔 20 秒）。
# 说明：可选优化，不影响功能；boot.sh 之后手动跑，或在 /root/.profile 里追加一行。
sleep 210
for i in 1 2 3 4 5 6; do
  if pgrep -f "qq --no" >/dev/null 2>&1; then
    chroot /root/ubuntu /bin/bash -c "DISPLAY=:99 xdotool search --name '^QQ\$' windowunmap" 2>/dev/null
    echo "$(date '+%H:%M:%S') hide_qq done"
    exit 0
  fi
  sleep 20
done
echo "$(date '+%H:%M:%S') hide_qq skipped (qq not running)"
