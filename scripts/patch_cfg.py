#!/usr/bin/env python3
"""patch_cfg.py —— 把 AstrBot 的平台适配器改成 aiocqhttp（反向 WS，监听 6199）

用途：AstrBot 首次启动生成的 data/cmd_config.json 里 platform 是空的，
      跑一遍本脚本即可让 AstrBot 当 OneBot 反连的服务端，等 SnowLuma 连上来。
用法（虚机内）：python3 patch_cfg.py
依赖：仅标准库。目标文件路径写死在 /root/src/AstrBot-master/data/cmd_config.json。
要点：
  - 该 JSON 由 AstrBot 写入时带 UTF-8 BOM，读必须用 encoding='utf-8-sig'，否则 json.load 直接报错；
  - ws_reverse_host 是 0.0.0.0 表示监听所有网卡；
  - 本脚本不备份原文件（只有 13 行），跑完请再用 only_deepseek.py / panel 之类带备份的脚本改别的字段。
"""
import json, sys
p = '/root/src/AstrBot-master/data/cmd_config.json'
d = json.load(open(p, encoding='utf-8-sig'))
d['platform'] = [{
    "id": "default",
    "type": "aiocqhttp",
    "enable": True,
    "ws_reverse_host": "0.0.0.0",
    "ws_reverse_port": 6199,
    "ws_reverse_token": ""
}]
json.dump(d, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print('PATCH_OK', json.dumps(d['platform'], ensure_ascii=False))
