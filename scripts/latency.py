#!/usr/bin/env python3
"""从 AstrBot 日志里量「收到消息 → 准备发送」的耗时分布（P50/P90/最大值）。"""
import re, sys
from datetime import datetime

LOG = "/root/ab.log"
IN = re.compile(r"^\[(\d\d:\d\d:\d\d)\.(\d+)\].*\[default\(aiocqhttp\)\] (\S+): (.*)$")
OUT = re.compile(r"^\[(\d\d:\d\d:\d\d)\.(\d+)\].*Prepare to send - (\S+): (.*)$")

def ts(h, ms):
    t = datetime.strptime(h, "%H:%M:%S")
    return t.hour * 3600 + t.minute * 60 + t.second + int(ms) / 1000.0

pending = {}
pairs = []
for line in open(LOG, encoding="utf-8", errors="ignore"):
    m = IN.match(line.strip())
    if m:
        pending[m.group(3)] = ts(m.group(1), m.group(2))
        continue
    m = OUT.match(line.strip())
    if m:
        who = m.group(3)
        if who in pending:
            pairs.append((pending.pop(who), ts(m.group(1), m.group(2)), line.strip()[:90]))

lat = sorted(b - a for a, b, _ in pairs)
if not lat:
    print("没找到可配对的收/发记录")
    sys.exit(0)
def pct(p):
    return lat[min(len(lat) - 1, int(len(lat) * p))]
print("配对样本：%d 条" % len(lat))
print("P50 = %.1fs   P90 = %.1fs   max = %.1fs   min = %.1fs" % (pct(0.5), pct(0.9), lat[-1], lat[0]))
print("\n最近 5 条：")
for a, b, txt in pairs[-5:]:
    print("  %5.1fs  %s" % (b - a, txt))
