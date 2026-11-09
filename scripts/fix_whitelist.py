#!/usr/bin/env python3
"""关掉 id 白名单（否则群里只有管理员会被回复）+ 确保 wake_prefix 为空。"""
import json, os, shutil, time

P = "/root/src/AstrBot-master/data/cmd_config.json"
c = json.load(open(P, encoding="utf-8-sig"))
ps = c.setdefault("platform_settings", {})
ch = []
if ps.get("enable_id_white_list") is not False:
    ch.append("enable_id_white_list: %r -> False" % ps.get("enable_id_white_list"))
    ps["enable_id_white_list"] = False
if c.get("wake_prefix") != []:
    ch.append("wake_prefix -> []")
    c["wake_prefix"] = []
if ch:
    shutil.copy2(P, P + ".bak." + time.strftime("%H%M%S"))
    tmp = P + ".tmp"
    json.dump(c, open(tmp, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    os.replace(tmp, P)
print("已改：", ch or "无需修改")
