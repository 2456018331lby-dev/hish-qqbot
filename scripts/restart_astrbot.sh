#!/bin/sh
# restart_astrbot.sh —— 只重启 AstrBot（Python 主进程）
#
# 用途：改完 data/cmd_config.json（平台 / 模型 / 唤醒词）后生效；控制台「重启 AstrBot」按钮调它。
# 依赖：/root/src/AstrBot-master（源码）、/root/venv（虚拟环境，内含 AstrBot 全部依赖）。
# 要点：
#   - `python3 -u` 关 stdout 缓冲，否则 /root/ab.log 里看不到实时日志；
#   - `pkill -f "main[.]py"` 里的 `[.]` 是为了不匹配本脚本自身的命令行
#     （直接写 main.py 会让 pkill 把自己也杀掉，返回 rc=143）；
#   - 冷启动 3–4 分钟，期间 6185 打不开是正常的。
pkill -f "main[.]py" 2>/dev/null
sleep 3
cd /root/src/AstrBot-master || exit 1
. /root/venv/bin/activate
( nohup python3 -u main.py > /root/ab.log 2>&1 & )
echo "AstrBot 重启中（约 3 分钟起来）"
