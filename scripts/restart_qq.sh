#!/bin/sh
# restart_qq.sh —— 只重启 Linux QQ（Electron 客户端）
#
# 用途：QQ 崩溃 / 掉登录时使用；控制台「重启 QQ」按钮调它。
# 依赖：chroot /root/ubuntu 里的 /opt/QQ/qq（Linux QQ 3.2.32）与 :99 上的 Xvfb（先由 boot.sh 拉起）。
# 启动参数为什么必须带：
#   --no-sandbox                    虚机里没有可用的 user namespace
#   --disable-gpu                   纯软件渲染，QEMU TCG 下没有 GPU
#   --disable-dev-shm-usage         /dev/shm 太小，不关会直接崩
#   --disable-software-rasterizer   进一步压 CPU 占用
# 掉登录后要重新扫码；已扫码的会话存在 QQ 数据目录里，正常重启免扫（实测有效）。
chroot /root/ubuntu /bin/bash -c 'pkill -f "/opt/QQ/qq"' 2>/dev/null
sleep 4
( nohup chroot /root/ubuntu /bin/bash -c 'DISPLAY=:99 /opt/QQ/qq --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-software-rasterizer' >/tmp/qq.out 2>&1 & )
echo "QQ 重启中（自动登录约 20 秒）"
