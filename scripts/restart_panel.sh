#!/bin/sh
# 拉取最新 panel_v3 → 重启控制台 → 自检
cd /root || exit 1
[ -n "$PC_IP" ] && wget -q -O /root/panel.py.new "http://$PC_IP/panel_v4.py" && mv -f /root/panel.py.new /root/panel.py
for p in $(ps -eo pid,args | awk '/[p]anel\.py/{print $1}'); do kill -9 "$p" 2>/dev/null; done
sleep 2
python3 -u /root/panel.py > /root/panel.log 2>&1 &
sleep 6
echo "proc=$(ps -eo pid,args | awk '/[p]anel\.py/{print $1}' | head -1)"
echo "port=$(netstat -ltn 2>/dev/null | grep -c ':8080')"
curl -s -o /dev/null -w 'status=%{http_code}\n' --max-time 15 http://127.0.0.1:8080/api/status
curl -s -o /dev/null -w 'perf=%{http_code}\n' --max-time 15 http://127.0.0.1:8080/api/perf
