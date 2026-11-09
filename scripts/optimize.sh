#!/bin/sh
# optimize.sh —— 降低启动耗时与运行负载（幂等，可反复跑）
#
# 用途：做三件事
#   1) 预编译 AstrBot + 插件的 .pyc，冷启动少解析几十秒
#   2) 给 QQ/Electron 关掉用不上的后台特性，减少 CPU 抖动（写 /root/ubuntu/root/start_qq.sh）
#   3) 收敛 provider_settings（图生文默认 provider、关联网搜索）+ 内核网络参数（能设则设）
# 依赖：
#   - /root/venv/bin/python（AstrBot 的独立 venv，compileall 用它保证与运行版本一致）
#   - /root/src/AstrBot-master（源码 + data/cmd_config.json + data/plugins）
#   - system python3（busybox 侧 Alpine python3，只用来改 JSON）
# 日志：/root/quick.log 之类不写；本脚本输出到 stdout，建议
#       `sh /root/optimize.sh >> /root/optimize.log 2>&1`
# 安全提示：
#   - 会原地改写 /root/src/AstrBot-master/data/cmd_config.json（该文件含 provider 配置与 key，
#     已在 .gitignore 里排除，不要把它的内容贴进 issue 或文档）。
#   - 写入的 start_qq.sh 有一个启动即生效的堆上限 `--max-old-space-size=384`，
#     若 QQ 出现 OOM 崩，先把它调大；这台机器内存只有 4 GB，别调太大。
#   - openrc/systemd 都没有，没有「持久化」概念：所有改动都是写文件，重装容器就丢。
set -u
R=/root/ubuntu
echo "=== optimize $(date '+%F %T') ==="

echo "--- 1. 预编译 AstrBot 与插件 ---"
/root/venv/bin/python -m compileall -q /root/src/AstrBot-master/astrbot >/dev/null 2>&1
echo "core_rc=$?"
ls -d /root/src/AstrBot-master/data/plugins/*/ >/dev/null 2>&1 && \
  /root/venv/bin/python -m compileall -q /root/src/AstrBot-master/data/plugins >/dev/null 2>&1
echo "plugins_rc=$?"

echo "--- 2. QQ 启动参数（下次重启生效） ---"
# 写一个统一的启动脚本，watchdog/boot 都调它，避免参数散落
cat > "$R/root/start_qq.sh" <<'QQEOF'
#!/bin/bash
export DISPLAY=:99
# --disable-gpu / 关硬件加速；--disable-renderer-backgrounding 防后台被降频；
# --js-flags 限制堆，避免 Electron 吃满内存
exec /opt/QQ/qq --no-sandbox \
  --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage \
  --disable-software-rasterizer --disable-features=UseChromeOSDirectVideoDecoder \
  --js-flags="--max-old-space-size=384" >> /root/qq.out 2>&1
QQEOF
chmod +x "$R/root/start_qq.sh"
echo "start_qq.sh 已写入（含参数与内存上限）"

echo "--- 3. 内核网络参数（可用则设） ---"
sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 && echo "bbr=on" || echo "bbr=skip"
sysctl -w vm.swappiness=10 >/dev/null 2>&1 && echo "swappiness=10" || true

echo "--- 4. 关闭 AstrBot 里代价高的初始化项（保守） ---"
python3 - <<'PY'
import json
p="/root/src/AstrBot-master/data/cmd_config.json"
try:
    c=json.load(open(p,encoding="utf-8-sig"))
except Exception as e:
    print("cfg_err", e); raise SystemExit
ps=c.get("provider_settings") or {}
# 图生文默认 provider 指向可用模型，避免加载时告警
ps["default_image_caption_provider_id"]="ben/deepseek-v4.1-flash"
# 关闭不需要的联网搜索（省一次外部请求）
ps["web_search"]=False
c["provider_settings"]=ps
json.dump(c,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
print("provider_settings 已收敛")
PY

echo "--- 5. 当前负载 ---"
uptime
free -m | sed -n '2p'
echo "=== optimize done ==="
