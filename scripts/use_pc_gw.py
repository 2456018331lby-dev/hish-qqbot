#!/usr/bin/env python3
"""use_pc_gw.py —— 把 AstrBot 的模型源切到「PC 上的 OpenAI 兼容网关」

用途：平板在 TCG 下跑 HTTPS 很慢/不稳时的备选方案：把 PC 上的网关（默认 8789 端口）
      当成 OpenAI 兼容 API 用，AstrBot 只发内网 HTTP 请求。
用法（虚机内）：python3 use_pc_gw.py [PC_IP] [PORT]   # 默认取环境变量 PC_IP，端口 8789
依赖：仅标准库。目标文件 /root/src/AstrBot-master/data/cmd_config.json（带 UTF-8 BOM，需 utf-8-sig）。
行为：改前自动备份为 cmd_config.json.bak.<时间戳>；启用 ben 源、停用 vyceai 源；
      清空 wake_prefix（不需要唤醒词，群里被 @ 就回）。
注意：PC 侧网关（8789）不在本仓库内，属于当时那台机器的私有组件；没有它别用这个脚本。
"""
import json
import shutil
import os
import sys
import time

PC_HOST = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("PC_IP", "")
if not PC_HOST:
    raise SystemExit("请传参或用环境变量 PC_IP 指定 PC 的局域网 IP")
PORT = sys.argv[2] if len(sys.argv) > 2 else "8789"

CFG = "/root/src/AstrBot-master/data/cmd_config.json"
bak = CFG + ".bak." + time.strftime("%Y%m%d-%H%M%S")
shutil.copy2(CFG, bak)

with open(CFG, encoding="utf-8-sig") as f:
    cfg = json.load(f)

sources = cfg.get("provider_sources") or []
providers = cfg.get("provider") or []

for s in sources:
    if s.get("id") == "ben":
        s["api_base"] = f"http://{PC_HOST}:{PORT}/v1"
        s["enable"] = True
        s["timeout"] = 300
    if s.get("id") == "vyceai":
        s["enable"] = False

for p in providers:
    if p.get("id") == "ben/deepseek-v4.1-flash":
        p["enable"] = True
        p["timeout"] = 300
        p["model"] = "deepseek-v4.1-flash"
    if p.get("id") == "vyceai/deepseek-v4.1":
        p["enable"] = False

# 只留 ben 的 deepseek 排第一
order = {"ben/deepseek-v4.1-flash": 0, "vyceai/deepseek-v4.1": 1}
providers.sort(key=lambda p: order.get(p.get("id"), 9))

cfg["provider_sources"] = sources
cfg["provider"] = providers
cfg["wake_prefix"] = []

with open(CFG, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)

print("=== 结果 ===")
for s in cfg["provider_sources"]:
    print("  src :", s.get("id"), "|", s.get("api_base"), "| enable:", s.get("enable"))
for p in cfg["provider"]:
    print("  prov:", p.get("id"), "| enable:", p.get("enable"))
