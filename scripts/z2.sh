#!/bin/sh
# z2.sh —— 虚机侧「命令通道」轮询器（远程运维后门，日常不需要）
#
# 用途：早期没有稳定 SSH 通道时用的旁路。每 4 秒从 PC 的 HTTP 根目录拉 cmd.txt，
#       内容一变化就 sh -c 执行，再把输出 POST 回 PC 的 8081（logsvr.py 接收）。
# 依赖（PC 侧，本仓库不含）：
#   - 在 www/ 目录跑 `py -3.12 -m http.server 80` 提供 cmd.txt
#   - logsvr.py 监听 8081 收结果
# 风险：这是「谁都能写命令」的通道，cmd.txt 被改就等于被拿到 shell。
#       仅限内网自用，用完后启动项里请删掉，别带到公网环境。
# 坑：`pkill -f xxx` 写在 sh -c 里会匹配到自身命令行，把自己杀掉（rc=143）；
#     需要 pkill 时写成独立 .sh 执行。
# 下面这行是当时那台 PC 的内网地址，换成你自己的。
URL=${PC_IP:?export PC_IP=<PC 的局域网 IP>}
URL="http://$URL"
LOG=/root/z2.log
exec >> $LOG 2>&1
echo "=== Z2 start $(date) ==="
mkdir -p /root/rc

# 网络自检
if wget -T 6 -q -O /root/rc/net.txt $URL/cmd.txt; then echo "NET_OK"; else echo "NET_FAIL"; fi > /root/rc/nets.txt
wget -T 10 -q -O /dev/null --post-file=/root/rc/nets.txt $URL:8081/ 2>/dev/null

# 启动 AstrBot（若未运行）
cd /root/src/AstrBot-master || echo "NO_SRC"
. /root/venv/bin/activate
if ! ps | grep -q "[m]ain.py"; then
  nohup python3 main.py > /root/ab.log 2>&1 &
  echo "astrbot launched pid $!"
fi

last=""
while true; do
  if wget -T 8 -q -O /root/rc/cmd.txt $URL/cmd.txt; then
    c=$(cat /root/rc/cmd.txt 2>/dev/null)
    if [ -n "$c" ] && [ "$c" != "$last" ]; then
      last="$c"
      {
        echo "=== CMD $(date '+%H:%M:%S') ==="
        echo "$c"
        echo "--- output ---"
      } > /root/rc/out.txt
      sh -c "$c" >> /root/rc/out.txt 2>&1
      echo "--- done rc=$? ---" >> /root/rc/out.txt
      wget -T 10 -q -O /dev/null --post-file=/root/rc/out.txt $URL:8081/ 2>/dev/null
    fi
  fi
  sleep 4
done
