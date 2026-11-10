#!/bin/sh
# deploy_panel.sh —— 把控制台（panel_v4.py）部署到虚机并自检
#
# 用途：在虚机里一键拉取 panel_v4.py → 存成 /root/panel.py → 杀掉旧进程 → 后台起新的
#       → 用 curl 请求 /api/status 和 /settings 各打一次，打印 HTTP 状态码。
# 依赖：wget、curl、python3；以及一个能访问到脚本的 HTTP 源（下面的 $PC_IP 是那台 PC 的局域网地址，
#       换成你自己的内网 IP，或者改用 scp / HiSH 共享文件夹拷进去）。
# 判定：末尾两行必须是 panel_test=200、settings_test=200，否则看 /root/panel.log。
# 注意：本脚本只同步 panel.py 与 restart_all.sh；改完脚本记得同步其它 restart_*.sh。
cd /root || exit 1
PC_IP=${PC_IP:?export PC_IP=<PC 的局域网 IP>}
wget -q -O panel.py "http://$PC_IP/panel_v4.py" || echo PANEL_DL_FAIL
wget -q -O restart_all.sh "http://$PC_IP/restart_all.sh" && chmod +x restart_all.sh
for p in $(ps -eo pid,args | awk '/[p]anel\.py/{print $1}'); do kill "$p" 2>/dev/null; done
sleep 1
nohup python3 /root/panel.py >/root/panel.log 2>&1 &
sleep 3
echo "panel_test=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/api/status)"
echo "settings_test=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/settings)"
