#!/bin/sh
# restart_snowluma.sh —— 只重启 SnowLuma（QQ 注入端 / OneBot 实现）
#
# 用途：QQ 掉登录、hook 失效、或改了 OneBot WS 配置后用；控制台「重启 SnowLuma」按钮调它。
# 依赖：chroot /root/ubuntu 中 /root/sl 目录及其 launcher.sh（SnowLuma 2.4.2）。
# 要点：进程名特征是 index.mjs（Node 启动器），不是 snowluma；
#       SnowLuma 必须在 QQ 已启动之后才能注入成功，本脚本不会替你拉起 QQ。
pkill -f "index[.]mjs" 2>/dev/null
sleep 3
( nohup chroot /root/ubuntu /bin/bash -c 'cd /root/sl && ./launcher.sh' > /root/sl.log 2>&1 & )
echo "SnowLuma 重启中（约 10 秒）"
