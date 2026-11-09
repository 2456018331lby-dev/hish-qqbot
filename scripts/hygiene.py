#!/usr/bin/env python3
"""清理 AstrBot 配置里指向「已删除 provider」的死引用（幂等，改前备份）。"""
import json, os, shutil, time

P = "/root/src/AstrBot-master/data/cmd_config.json"
GOOD = "ben/deepseek-v4.1-flash"

c = json.load(open(P, encoding="utf-8-sig"))
ids = {x.get("id") for x in (c.get("provider") or [])}
changed = []

# 1) agent_runner 的 fallback 列表：只保留真实存在的 provider
ar = c.setdefault("agent_runner", {}).setdefault("config", {})
model = ar.setdefault("model", {})
fb = model.get("fallback_provider_ids") or []
keep = [x for x in fb if x in ids]
if keep != fb:
    model["fallback_provider_ids"] = keep
    changed.append("fallback_provider_ids -> %r" % keep)

# 2) 主 provider 如果指向不存在的，回落到 GOOD
if model.get("provider_id") not in ids:
    changed.append("provider_id %r -> %r" % (model.get("provider_id"), GOOD))
    model["provider_id"] = GOOD

# 3) 图生文 / 长期记忆里的 provider 死引用
ps = c.setdefault("provider_settings", {})
ltm = c.setdefault("provider_ltm_settings", {})
for obj, key in ((ps, "default_image_caption_provider_id"), (ltm, "image_caption_provider_id")):
    if obj.get(key) and obj.get(key) not in ids:
        changed.append("%s %r -> %r" % (key, obj.get(key), GOOD))
        obj[key] = GOOD
if ltm.get("image_caption") and not any("embedding" in (x.get("model") or "").lower() for x in (c.get("provider") or [])):
    ltm["image_caption"] = False
    changed.append("provider_ltm_settings.image_caption -> False（没有可用的图像/嵌入模型）")

if changed:
    shutil.copy2(P, P + ".bak." + time.strftime("%H%M%S"))
    tmp = P + ".tmp"
    json.dump(c, open(tmp, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    os.replace(tmp, P)
    print("已修改 %d 处：" % len(changed))
    for x in changed:
        print("  -", x)
else:
    print("无需修改（配置已干净）")
print("当前 providers:", sorted(ids))
