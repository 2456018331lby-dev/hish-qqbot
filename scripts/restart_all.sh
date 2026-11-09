#!/bin/sh
# restart_all.sh —— 一键重启「SnowLuma + AstrBot」两件套
#
# 用途：改完配置 / 换模型后最常用的操作；控制台（panel_v3.py）的「全部重启」按钮调它。
# 顺序有依赖：SnowLuma 是 OneBot 侧，AstrBot 反向 WS 要连到 6199；
#            必须先起 SnowLuma、等 15 秒，再起 AstrBot，否则 AstrBot 首轮连不上。
# 依赖：同目录的 restart_snowluma.sh、restart_astrbot.sh（部署到 /root/ 下同名）。
# 提醒：这个脚本只等 15 秒，AstrBot 冷启动还要 3–4 分钟才真正可用。
echo "=== restart_all $(date) ==="
sh /root/restart_snowluma.sh 2>&1 | tail -3
sleep 15
sh /root/restart_astrbot.sh 2>&1 | tail -3
echo "=== done $(date) ==="
