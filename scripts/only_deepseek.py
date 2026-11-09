#!/usr/bin/env python3
"""only_deepseek.py —— 把 AstrBot 的模型列表收敛到「只留 DeepSeek」

用途：AstrBot 初始自带一堆 OpenAI 模型配置，平板网络下逐个探测很慢；
      本脚本只留一个可用的 chat_completion 模型，并把 ben（PC 本地网关）源保留但停用，
      以后 PC 开着网关可随时在控制台里启用。
用法（虚机内）：python3 only_deepseek.py
依赖：仅标准库。目标文件 /root/src/AstrBot-master/data/cmd_config.json（带 UTF-8 BOM，需 utf-8-sig）。
行为：改前自动备份为 cmd_config.json.bak.<时间戳>；打印改后的模型与模型源两张表；
      顺手清掉 provider_settings 里指向 gpt/openai 的图片描述与联网搜索提供者。
注意：脚本里 vyceai 源的 api_base 兜底写的是 https://api.openai.com/v1 —— 这是 AstrBot 的
      默认占位值，真正生效的是 provider_sources 里已有条目上的 api_base。首次配置请到
      6185 后台或直接改 JSON 填你自己的 base_url 与 key，别把 key 提交进仓库。
"""
import json
import shutil
import time

CFG = "/root/src/AstrBot-master/data/cmd_config.json"
bak = CFG + ".bak." + time.strftime("%Y%m%d-%H%M%S")
shutil.copy2(CFG, bak)
print("backup:", bak)

with open(CFG, encoding="utf-8-sig") as f:
    cfg = json.load(f)

sources = cfg.get("provider_sources") or []
providers = cfg.get("provider") or []

# 只留 DeepSeek：保留 vyceai 源（可用），ben 源保留但停用（PC 本地代理）
keep_sources = []
for s in sources:
    if s.get("id") == "vyceai":
        s["enable"] = True
        keep_sources.append(s)
    elif s.get("id") == "ben":
        s["enable"] = False
        keep_sources.append(s)
cfg["provider_sources"] = keep_sources

keep_providers = []
deepseek = None
for p in providers:
    if p.get("id") == "vyceai/deepseek-v4.1":
        deepseek = p
if deepseek is None:
    deepseek = {
        "id": "vyceai/deepseek-v4.1",
        "type": "openai_chat_completion",
        "provider": "openai",
        "provider_type": "chat_completion",
        "enable": True,
        "key": [],
        "api_base": "https://api.openai.com/v1",
        "model": "deepseek-v4.1",
        "provider_source_id": "vyceai",
        "timeout": 180,
    }
deepseek["enable"] = True
keep_providers.append(deepseek)

# 备用：把 ben/deepseek-v4.1-flash 留着但停用（以后 PC 开着代理可以随时启用）
for p in providers:
    if p.get("id") == "ben/deepseek-v4.1-flash":
        p["enable"] = False
        keep_providers.append(p)

cfg["provider"] = keep_providers
cfg["wake_prefix"] = []

# provider_settings 里如果引用了被删的 GPT 模型，清掉
ps = cfg.get("provider_settings") or {}
for k in ("default_image_caption_provider_id", "websearch_provider"):
    v = ps.get(k)
    if isinstance(v, str) and ("gpt" in v or "openai" in v):
        ps[k] = ""
cfg["provider_settings"] = ps

with open(CFG, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)

print("=== 现在的模型 ===")
for p in cfg["provider"]:
    print("  prov:", p.get("id"), "| model:", p.get("model"), "| enable:", p.get("enable"), "| src:", p.get("provider_source_id"))
print("=== 模型源 ===")
for s in cfg["provider_sources"]:
    print("  src :", s.get("id"), "|", s.get("api_base"), "| enable:", s.get("enable"))
