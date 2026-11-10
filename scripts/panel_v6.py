#!/usr/bin/env python3
"""鸿蒙平板一体化控制台 v3（端口 8080）。

v3 相比 v2 新增：
  - /api/perf     性能快照（核数/负载/内存/运行时长/AstrBot 启动耗时）
  - /api/logs     查看 ab / boot / sl / watchdog 日志尾部
  - /api/repair   一键跑 /root/quick.sh（幂等修复，约 3-6 分钟）
  - /quick        维修页（按钮 + 日志滚动）
  - 首页顶部加「体检卡」：一句话告诉你现在能不能用

依赖：python3 标准库；AstrBot 后台 6185（账号见 AB_USER/AB_PASS，可用环境变量覆盖）
安全：无鉴权，仅监听内网 + 由 HiSH 端口映射暴露；不要在公网直接映射 8080。
"""

import json
import os
import re
import shutil
import socket
import subprocess
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AB = "http://127.0.0.1:6185"
AB_USER = os.environ.get("AB_USER", "astrbot")
def _ab_pass():
    """不在仓库里存密码：优先环境变量 AB_PASS，其次读 /root/.abpass（部署时本地写，700 权限）。"""
    v = os.environ.get("AB_PASS")
    if v:
        return v
    try:
        with open("/root/.abpass", encoding="utf-8") as f:
            return f.read().strip()
    except Exception:
        return ""


AB_PASS = _ab_pass()
CFG = "/root/src/AstrBot-master/data/cmd_config.json"
PORT = 8080
LOGS = {
    "ab": "/root/ab.log",
    "boot": "/root/boot.log",
    "sl": "/root/sl.log",
    "watchdog": "/root/watchdog.log",
    "quick": "/root/quick.log",
}

_cache = {}
_token = {"v": None, "ts": 0, "fail_ts": 0}


def ab_login():
    """登录 AstrBot 后台拿 JWT。失败要负缓存：否则 /api/status 每 5 秒都会卡满超时。"""
    now = time.time()
    if _token["v"] and now - _token["ts"] < 1800:
        return _token["v"]
    if now - _token["fail_ts"] < 60:      # 60 秒内不重试，保住页面响应速度
        return None
    try:
        body = json.dumps({"username": AB_USER, "password": AB_PASS}).encode()
        r = urllib.request.Request(AB + "/api/auth/login", data=body,
                                   headers={"Content-Type": "application/json"}, method="POST")
        op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with op.open(r, timeout=12) as x:
            tok = json.loads(x.read().decode())["data"]["token"]
        _token["v"] = tok
        _token["ts"] = time.time()
        return tok
    except Exception:
        _token["fail_ts"] = now
        return None


def ab_call(path, data=None, method="POST"):
    tok = ab_login()
    if not tok:
        return None, "AstrBot 未响应（可能正在启动）"
    h = {"Content-Type": "application/json", "Authorization": "Bearer " + tok}
    body = json.dumps(data).encode() if data is not None else None
    r = urllib.request.Request(AB + path, data=body, headers=h, method=method)
    try:
        with urllib.request.urlopen(r, timeout=45) as x:
            return json.loads(x.read().decode()), None
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode()), "HTTP %d" % e.code
        except Exception:
            return None, "HTTP %d" % e.code
    except Exception as e:
        return None, str(e)[:80]


def port_open(p, timeout=1.2):
    s = socket.socket()
    s.settimeout(timeout)
    try:
        return s.connect_ex(("127.0.0.1", p)) == 0
    finally:
        s.close()


def load_cfg():
    try:
        with open(CFG, encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return {}


def save_cfg(cfg):
    try:
        shutil.copy2(CFG, CFG + ".bak." + time.strftime("%H%M%S"))
    except Exception:
        pass
    tmp = CFG + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    os.replace(tmp, CFG)


def sh(cmd, timeout=120):
    try:
        return subprocess.run(["/bin/sh", "-c", cmd], capture_output=True, text=True,
                              timeout=timeout).stdout
    except Exception as e:
        return "ERR %s" % e


def tail(path, n=60):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 64 * 1024))
            data = f.read().decode("utf-8", "ignore").splitlines()
        return "\n".join(data[-n:])
    except Exception as e:
        return "读取失败：%s" % e


def perf():
    def kv(cmd):
        return sh(cmd).strip()
    raw_mem = kv("free -m | sed -n '2p'")
    mem = raw_mem
    try:
        parts = raw_mem.split()
        # free -m 第二行：total used free shared buff/cache available
        total, used = parts[1], parts[2]
        mem = "%s / %s MB" % (used, total)
    except Exception:
        pass
    load = kv("cut -d' ' -f1-3 /proc/loadavg")
    uptime = kv("cut -d' ' -f1 /proc/uptime")
    ab_start = ""
    try:
        with open("/root/ab.log", "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 400 * 1024))
            for line in f.read().decode("utf-8", "ignore").splitlines():
                if "Running on http://0.0.0.0:6185" in line:
                    m = re.match(r"\[(\d\d:\d\d:\d\d)", line)
                    ab_start = m.group(1) if m else line[:8]
    except Exception:
        pass
    return {
        "nproc": kv("nproc"),
        "load": load,
        "mem": mem,
        "uptime_sec": int(float(uptime)) if uptime.replace(".", "").isdigit() else 0,
        "ab_ready_at": (ab_start or "以日志为准"),
        "qq_proc": kv("pgrep -f '[q]q --no-sandbox' | head -1"),
        "watchdog": "on" if kv("pgrep -f '[w]atchdog.sh' | head -1") else "off",
    }


SL_TOKEN = os.environ.get("SL_TOKEN", "")
SL_CFG = "/root/ubuntu/root/sl/config/onebot_3982034942.json"


def _sl_token():
    global SL_TOKEN
    if SL_TOKEN:
        return SL_TOKEN
    try:
        with open(SL_CFG, encoding="utf-8") as f:
            c = json.load(f)
        SL_TOKEN = (c.get("networks") or {}).get("httpServers", [{}])[0].get("accessToken", "")
    except Exception:
        pass
    return SL_TOKEN


def _sl_call(action, **params):
    """问 SnowLuma 的 OneBot HTTP（127.0.0.1:3000）。"""
    tok = _sl_token()
    if not tok:
        return None
    q = "&".join("%s=%s" % (k, v) for k, v in params.items())
    url = "http://127.0.0.1:3000/%s%s" % (action, ("?" + q) if q else "")
    op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + tok})
    try:
        with op.open(req, timeout=5) as r:
            return json.loads(r.read().decode())
    except Exception:
        return None


def group_mute():
    """群里是不是把机器人禁言了 —— 这是「私聊能回、群里不回」的第一嫌疑人。结果缓存 30 秒。"""
    if "mute" in _cache and time.time() - _cache["mute"][0] < 30:
        return _cache["mute"][1]
    out = _group_mute_uncached()
    _cache["mute"] = (time.time(), out)
    return out


def _group_mute_uncached():
    gl = _sl_call("get_group_list")
    out = []
    if not gl or gl.get("status") != "ok":
        return out
    me = (login_info or {}).get("user_id")
    for g in (gl.get("data") or [])[:5]:
        gid = g.get("group_id")
        info = _sl_call("get_group_member_info", group_id=gid, user_id=me, no_cache="true") if me else None
        if not info or info.get("status") != "ok":
            continue
        d = info.get("data") or {}
        until = int(d.get("shut_up_timestamp") or 0)
        if until > time.time():
            out.append({"group": gid, "name": g.get("group_name"), "until": until,
                        "left_sec": until - int(time.time())})
    return out


login_info = {}


def tail_lines(path, n):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 80 * 1024))
            return f.read().decode("utf-8", "ignore").splitlines()[-n:]
    except Exception:
        return []


def log_stat():
    """从 ab.log 里抠出：最后一条收到的消息、最后一条发出的回复、最近 10 分钟的发送失败数。"""
    now = time.time()
    last_in = last_out = 0
    fails = 0
    try:
        with open("/root/ab.log", "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 300 * 1024))
            lines = f.read().decode("utf-8", "ignore").splitlines()
    except Exception:
        lines = []
    for ln in lines:
        m = re.search(r"^\[(\d\d:\d\d:\d\d)\.(\d+)\].*\[default\(aiocqhttp\)\]", ln)
        if m:
            last_in = max(last_in, _hms(m.group(1)))
        if "Prepare to send" in ln:
            m2 = re.search(r"^\[(\d\d:\d\d:\d\d)", ln)
            if m2:
                last_out = max(last_out, _hms(m2.group(1)))
        if "Failed to send the message chain" in ln:
            m3 = re.search(r"^\[(\d\d:\d\d:\d\d)", ln)
            if m3 and now - _hms(m3.group(1)) < 600:
                fails += 1
    return {"last_in_ts": last_in, "last_out_ts": last_out, "send_fail_10min": fails}


def _hms(h):
    hh, mm, ss = h.split(":")
    return int(hh) * 3600 + int(mm) * 60 + int(ss)


def status():
    global login_info
    if "li" not in _cache or time.time() - _cache["li"][0] > 60:
        li = _sl_call("get_login_info")
        if li and li.get("status") == "ok":
            login_info = li.get("data") or {}
        _cache["li"] = (time.time(), login_info)
    cfg = load_cfg()
    provs = cfg.get("provider") or []
    qq = sh("ps -eo args | grep -c '[q]q --no-sandbox'").strip()
    st = {
        "xvfb": port_open(5900),
        "qq": qq not in ("", "0"),
        "snowluma": port_open(5099),
        "astrbot": port_open(6185),
        "panel": True,
    }
    ok = st["qq"] and st["snowluma"] and st["astrbot"]
    return {
        "host": "hish · aarch64",
        "verdict": "全能聊" if ok else ("部分可用" if (st["astrbot"] or st["snowluma"]) else "未就绪"),
        "services": st,
        "models": [{"id": p.get("id"), "model": p.get("model"), "enable": bool(p.get("enable"))} for p in provs],
        "wake_prefix": cfg.get("wake_prefix") or [],
        "ab_login": bool(ab_login()),
        "perf": perf(),
        "live": dict(log_stat(), now=int(time.time())),
        "muted": group_mute(),
    }


PAGE = """<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>平板机器人控制台</title>
<style>
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
body{margin:0;background:#0f1115;color:#e6e8ee;font:16px/1.5 -apple-system,"HarmonyOS Sans","PingFang SC",sans-serif;padding:14px 14px 40px}
h1{font-size:20px;margin:6px 0 10px}
.verdict{background:#17251b;border:1px solid #2b4a33;color:#8ef0a8;border-radius:12px;padding:10px 14px;margin-bottom:12px;font-weight:600}
.verdict.warn{background:#2a2416;border-color:#4d3f1c;color:#f5cf6b}
.verdict.bad{background:#2a1717;border-color:#4d2020;color:#ff9a94}
.card{background:#171a21;border:1px solid #242935;border-radius:14px;padding:14px;margin-bottom:12px}
.row{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:9px 0;border-bottom:1px solid #20242e}
.row:last-child{border-bottom:0}
.dot{width:10px;height:10px;border-radius:50%;display:inline-block;margin-right:8px}
.on{background:#35c759;box-shadow:0 0 8px #35c75988}
.off{background:#ff453a}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}
button,a.btn{display:block;width:100%;padding:13px 10px;border-radius:12px;border:1px solid #2c3240;background:#1d222c;color:#e6e8ee;font-size:15px;text-align:center;text-decoration:none;font-family:inherit}
button:active{background:#2a3140}
.pri{background:#1f6feb;border-color:#2f7dfb}
.danger{background:#3a1d1d;border-color:#5a2626}
.small{font-size:13px;color:#98a0b3}
.mono{font-family:ui-monospace,Menlo,monospace;font-size:12px;white-space:pre-wrap;color:#9fe0b0;background:#0b0d11;border-radius:10px;padding:10px;max-height:220px;overflow:auto}
.toast{position:fixed;left:50%;transform:translateX(-50%);bottom:24px;background:#2b3240;padding:10px 16px;border-radius:10px;font-size:14px;opacity:0;transition:.25s;max-width:90%}
.toast.show{opacity:1}
</style></head><body>
<h1>平板机器人控制台</h1>
<div id="verdict" class="verdict">检查中…</div>
<div id="muteBar" style="display:none;background:#2a1717;border:1px solid #5a2626;color:#ff9a94;border-radius:12px;padding:10px 14px;margin:0 0 12px;font-weight:600"></div>

<div class="card">
  <div class="row"><span>QQ 客户端</span><span><i id="d-qq" class="dot off"></i><span id="s-qq" class="small">?</span></span></div>
  <div class="row"><span>SnowLuma（协议端）</span><span><i id="d-sl" class="dot off"></i><span id="s-sl" class="small">?</span></span></div>
  <div class="row"><span>AstrBot（机器人）</span><span><i id="d-ab" class="dot off"></i><span id="s-ab" class="small">?</span></span></div>
  <div class="row"><span>桌面（VNC）</span><span><i id="d-vnc" class="dot off"></i><span id="s-vnc" class="small">?</span></span></div>
  <div class="row"><span>看门狗</span><span><i id="d-wd" class="dot off"></i><span id="s-wd" class="small">?</span></span></div>
</div>

<div class="card">
  <div class="small" style="margin-bottom:8px">性能</div>
  <div class="mono"><div id="perf1">—</div><div id="perf2">—</div><div id="perf3">—</div></div>
  <div class="mono" style="margin-top:8px"><div id="live1">—</div><div id="live2">—</div></div>
</div>

<div class="card">
  <div class="small" style="margin-bottom:8px">实时日志（每 3 秒推送，来自真机 /root/ab.log）</div>
  <div id="liveLog" class="mono" style="max-height:180px">…</div>
</div>

<div class="card">
  <div class="small" style="margin-bottom:8px">常用入口</div>
  <div class="grid">
    <a class="btn pri" href="/settings">设置（模型/插件/人格）</a>
    <a class="btn" href="/quick">维修与日志</a>
    <a class="btn" href="http://127.0.0.1:6080/vnc.html" target="_blank">看虚拟机桌面</a>
    <a class="btn" href="http://127.0.0.1:6185" target="_blank">AstrBot 后台</a>
  </div>
</div>

<div class="card">
  <div class="small" style="margin-bottom:8px">服务操作（重启要等 3~10 分钟）</div>
  <div class="grid">
    <button onclick="act('/api/restart','astrbot')">重启 AstrBot</button>
    <button onclick="act('/api/restart','snowluma')">重启 SnowLuma</button>
    <button onclick="act('/api/restart','qq')">重启 QQ</button>
    <button class="danger" onclick="act('/api/restart','all')">全部重启</button>
  </div>
</div>
<div id="toast" class="toast"></div>
<script>
var NL=String.fromCharCode(10);
function ago(ts){
  if(!ts) return '—';
  var d0=new Date();
  var now=d0.getHours()*3600+d0.getMinutes()*60+d0.getSeconds(), d=now-ts;
  if(d<0) d+=86400;
  if(d<5) return '刚刚';
  if(d<60) return d+' 秒前';
  return Math.floor(d/60)+' 分钟前';
}
function txt(id,v){var e=document.getElementById(id); if(e) e.textContent=v;}
async function refresh(){
  try{
    var j=await (await fetch('/api/status',{cache:'no-store'})).json();
    var v=document.getElementById('verdict');
    v.textContent='当前状态：'+j.verdict+'（每 5 秒自动刷新）';
    v.className='verdict'+(j.verdict==='全能聊'?'':(j.verdict==='部分可用'?' warn':' bad'));
    var m={qq:['d-qq','s-qq'],snowluma:['d-sl','s-sl'],astrbot:['d-ab','s-ab'],xvfb:['d-vnc','s-vnc']};
    for(var k in m){
      var on=j.services[k];
      document.getElementById(m[k][0]).className='dot '+(on?'on':'off');
      txt(m[k][1], on?'运行中':'未运行');
    }
    var won=(j.perf.watchdog==='on');
    document.getElementById('d-wd').className='dot '+(won?'on':'off');
    txt('s-wd', won?'运行中':'未运行');
    txt('perf1','核心数 '+j.perf.nproc+'　负载 '+j.perf.load);
    txt('perf2','内存 '+j.perf.mem);
    txt('perf3','AstrBot 就绪 '+j.perf.ab_ready_at);
    var L=j.live||{};
    txt('live1','最后收到消息 '+ago(L.last_in_ts)+'　最后发出回复 '+ago(L.last_out_ts));
    txt('live2','近 10 分钟发送失败 '+(L.send_fail_10min||0)+' 次');
    var mb=document.getElementById('muteBar');
    if(j.muted && j.muted.length){
      var g=j.muted[0];
      mb.style.display='block';
      mb.textContent='⚠ 群「'+(g.name||g.group)+'」把机器人禁言了，还剩 '+(g.left_sec/3600).toFixed(1)+' 小时；私聊不受影响。';
    }else{ mb.style.display='none'; }
    var lg=document.getElementById('liveLog');
    if(lg && j.log && j.log.length){ lg.textContent=j.log.join(NL); }
  }catch(e){
    var v2=document.getElementById('verdict');
    v2.textContent='控制台读不到数据：虚拟机可能暂停（切后台/锁屏会冻结）';
    v2.className='verdict bad';
  }
}
refresh();
setInterval(refresh,5000);
</script></body></html>"""

SETTINGS = """<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>设置</title>
<style>
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
body{margin:0;background:#0f1115;color:#e6e8ee;font:16px/1.5 -apple-system,"HarmonyOS Sans","PingFang SC",sans-serif;padding:14px 14px 40px}
h1{font-size:20px;margin:6px 0 6px}a{color:#6ab0ff;text-decoration:none}
.card{background:#171a21;border:1px solid #242935;border-radius:14px;padding:14px;margin-bottom:12px}
.row{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:9px 0;border-bottom:1px solid #20242e}
.row:last-child{border-bottom:0}
.small{font-size:13px;color:#98a0b3}
.sw{width:56px;height:32px;border-radius:99px;background:#333a48;position:relative;flex:none;transition:.2s}
.sw.on{background:#2f7dfb}
.sw i{position:absolute;top:3px;left:3px;width:26px;height:26px;border-radius:50%;background:#fff;transition:.2s}
.sw.on i{left:27px}
button{padding:12px 14px;border-radius:12px;border:1px solid #2c3240;background:#1d222c;color:#e6e8ee;font-size:15px;font-family:inherit}
button:active{background:#2a3140}
.pri{background:#1f6feb;border-color:#2f7dfb}
textarea{width:100%;min-height:130px;padding:11px;border-radius:10px;border:1px solid #2c3240;background:#11141a;color:#e6e8ee;font-size:14px;font-family:inherit}
input[type=text]{width:100%;padding:11px;border-radius:10px;background:#11141a;color:#e6e8ee;border:1px solid #2c3240;font-size:15px;font-family:inherit}
select{width:100%;padding:11px;border-radius:10px;background:#11141a;color:#e6e8ee;border:1px solid #2c3240;font-size:15px;font-family:inherit}
.pill{font-size:12px;padding:2px 8px;border-radius:99px;background:#232935;color:#9aa4b8;margin-left:6px}
.toast{position:fixed;left:50%;transform:translateX(-50%);bottom:24px;background:#2b3240;padding:10px 16px;border-radius:10px;font-size:14px;opacity:0;transition:.25s;max-width:90%}
.toast.show{opacity:1}
</style></head><body>
<h1>设置 <span class="small">· <a href="/">控制台</a> · <a href="/quick">维修</a></span></h1>

<div class="card">
  <div class="small" style="margin-bottom:6px">模型（切换后需重启 AstrBot 生效）</div>
  <div id="models"><div class="small">加载中…</div></div>
</div>

<div class="card">
  <div class="small" style="margin-bottom:6px">插件（立即生效）</div>
  <div id="plugins"><div class="small">加载中…</div></div>
</div>

<div class="card">
  <div class="small" style="margin-bottom:6px">人格</div>
  <select id="sel"></select>
  <textarea id="prompt" placeholder="系统提示词…" style="margin-top:10px"></textarea>
  <button class="pri" style="margin-top:10px;width:100%" onclick="savePersona()">保存人格</button>
</div>

<div class="card">
  <div class="small" style="margin-bottom:6px">唤醒前缀（留空 = 群里不用 @ 也回复）</div>
  <input id="wake" type="text" placeholder="留空即可">
  <button style="margin-top:10px;width:100%" onclick="saveWake()">保存并重启 AstrBot</button>
</div>

<div id="toast" class="toast"></div>
<script>
function toast(t){const e=document.getElementById('toast');e.textContent=t;e.classList.add('show');setTimeout(()=>e.classList.remove('show'),2600)}
let PERSONAS=[];
async function jget(u){return await (await fetch(u)).json()}
async function jpost(u,b){return await (await fetch(u,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)})).json()}
async function load(){
  const st=await jget('/api/status');
  const mw=document.getElementById('models');mw.innerHTML='';
  (st.models||[]).forEach(m=>{
    const d=document.createElement('div');d.className='row';
    d.innerHTML='<div><div>'+m.id+'</div><div class="small">'+(m.model||'')+'</div></div>';
    const s=document.createElement('div');s.className='sw'+(m.enable?' on':'');s.innerHTML='<i></i>';
    s.onclick=async()=>{const j=await jpost('/api/model',{id:m.id,enable:!m.enable});toast(j.message||'已保存');load()};
    d.appendChild(s);mw.appendChild(d);
  });
  const pl=await jget('/api/plugins');
  const pw=document.getElementById('plugins');pw.innerHTML='';
  if((pl.items||[]).length===0)pw.innerHTML='<div class="small">'+(pl.error||'读不到插件列表')+'</div>';
  (pl.items||[]).forEach(p=>{
    const d=document.createElement('div');d.className='row';
    d.innerHTML='<div><div>'+p.display+'</div><div class="small">'+p.name+'<span class="pill">'+(p.version||'')+'</span></div></div>';
    const s=document.createElement('div');s.className='sw'+(p.activated?' on':'');s.innerHTML='<i></i>';
    s.onclick=async()=>{const j=await jpost('/api/plugin',{name:p.name,enable:!p.activated});toast(j.message||'已切换');setTimeout(load,1800)};
    d.appendChild(s);pw.appendChild(d);
  });
  const pr=await jget('/api/personas');
  PERSONAS=pr.items||[];
  const sel=document.getElementById('sel');sel.innerHTML='';
  if(PERSONAS.length===0){const o=document.createElement('option');o.textContent=pr.error||'读不到人格';sel.appendChild(o)}
  PERSONAS.forEach((p,i)=>{const o=document.createElement('option');o.value=i;o.textContent=p.persona_id;sel.appendChild(o)});
  const fill=()=>{const i=sel.value;if(PERSONAS[i])document.getElementById('prompt').value=PERSONAS[i].system_prompt||''};
  sel.onchange=fill;fill();
  document.getElementById('wake').value=(st.wake_prefix||[]).join(',');
}
async function savePersona(){
  const i=document.getElementById('sel').value;
  if(i===''||!PERSONAS[i])return toast('没有人格');
  const j=await jpost('/api/persona',{persona_id:PERSONAS[i].persona_id,system_prompt:document.getElementById('prompt').value});
  toast(j.message||'已保存');
}
async function saveWake(){
  const v=document.getElementById('wake').value.split(',').map(s=>s.trim()).filter(Boolean);
  const j=await jpost('/api/wake',{prefixes:v});
  toast(j.message||'已保存');
}
load();
</script></body></html>"""

QUICK = """<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>维修与日志</title>
<style>
body{margin:0;background:#0f1115;color:#e6e8ee;font:15px/1.55 -apple-system,"HarmonyOS Sans","PingFang SC",sans-serif;padding:14px 14px 40px}
h1{font-size:19px;margin:4px 0 12px}a{color:#6ab0ff;text-decoration:none}
.card{background:#171a21;border:1px solid #242935;border-radius:14px;padding:14px;margin-bottom:12px}
button{width:100%;padding:13px;border-radius:12px;border:1px solid #2c3240;background:#1d222c;color:#e6e8ee;font-size:15px;font-family:inherit;margin-bottom:10px}
.pri{background:#1f6feb;border-color:#2f7dfb}
.danger{background:#3a1d1d;border-color:#5a2626}
.mono{font-family:ui-monospace,Menlo,monospace;font-size:12px;white-space:pre-wrap;color:#9fe0b0;background:#0b0d11;border-radius:10px;padding:10px;max-height:340px;overflow:auto}
.small{font-size:13px;color:#98a0b3}
.toast{position:fixed;left:50%;transform:translateX(-50%);bottom:24px;background:#2b3240;padding:10px 16px;border-radius:10px;font-size:14px;opacity:0;transition:.25s}
.toast.show{opacity:1}
</style></head><body>
<h1>维修与日志 <span class="small">· <a href="/">控制台</a> · <a href="/settings">设置</a></span></h1>

<div class="card">
  <div class="small" style="margin-bottom:8px">一键修复（会依次修 X / QQ / SnowLuma / AstrBot / 看门狗，约 3~6 分钟）</div>
  <button class="pri" onclick="repair()">开始一键修复</button>
  <button onclick="loadLog('quick')">看修复日志</button>
</div>

<div class="card">
  <div class="small" style="margin-bottom:8px">日志</div>
  <button onclick="loadLog('ab')">AstrBot</button>
  <button onclick="loadLog('sl')">SnowLuma</button>
  <button onclick="loadLog('watchdog')">看门狗</button>
  <button onclick="loadLog('boot')">开机启动</button>
  <div id="log" class="mono">点上面的按钮看日志</div>
</div>
<div id="toast" class="toast"></div>
<script>
function toast(t){const e=document.getElementById('toast');e.textContent=t;e.classList.add('show');setTimeout(()=>e.classList.remove('show'),2600)}
async function repair(){
  toast('已下发，正在修复…');
  await fetch('/api/repair',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});
  setTimeout(()=>loadLog('quick'),8000);
}
async function loadLog(name){
  const j=await (await fetch('/api/logs?name='+name)).json();
  document.getElementById('log').textContent=j.text||'(空)';
}
</script></body></html>"""


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        p = self.path.split("?")[0]
        if p == "/" or p.startswith("/index"):
            return self._send(200, PAGE, "text/html; charset=utf-8")
        if p.startswith("/settings"):
            return self._send(200, SETTINGS, "text/html; charset=utf-8")
        if p.startswith("/quick"):
            return self._send(200, QUICK, "text/html; charset=utf-8")
        if p == "/api/status":
            return self._send(200, status())
        if p == "/api/stream":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            try:
                while True:
                    st = status()
                    snap = {
                        "verdict": st["verdict"],
                        "services": st["services"],
                        "perf": st["perf"],
                        "live": st["live"],
                        "muted": st["muted"],
                        "log": tail_lines("/root/ab.log", 6),
                    }
                    self.wfile.write(("data: " + json.dumps(snap, ensure_ascii=False) + "\n\n").encode())
                    self.wfile.flush()
                    time.sleep(3)
            except Exception:
                return

        if p == "/api/perf":
            return self._send(200, perf())
        if p == "/api/logs":
            name = "ab"
            for kv in self.path.split("?")[1:]:
                for pair in kv.split("&"):
                    if pair.startswith("name="):
                        name = pair[5:]
            return self._send(200, {"name": name, "text": tail(LOGS.get(name, LOGS["ab"]), 80)})
        if p == "/api/plugins":
            data, err = ab_call("/api/plugin/get", None, "GET")
            if not data:
                return self._send(200, {"items": [], "error": err})
            items = [{"name": x.get("name"), "display": x.get("display_name") or x.get("name"),
                      "version": x.get("version"), "activated": x.get("activated")}
                     for x in (data.get("data") or [])]
            return self._send(200, {"items": items})
        if p == "/api/personas":
            data, err = ab_call("/api/persona/list", None, "GET")
            if not data:
                return self._send(200, {"items": [], "error": err})
            items = [{"persona_id": x.get("persona_id"), "system_prompt": x.get("system_prompt") or ""}
                     for x in (data.get("data") or [])]
            return self._send(200, {"items": items})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        p = self.path.split("?")[0]
        n = int(self.headers.get("Content-Length") or 0)
        try:
            payload = json.loads(self.rfile.read(n).decode() or "{}")
        except Exception:
            payload = {}

        if p == "/api/model":
            cfg = load_cfg()
            for x in cfg.get("provider") or []:
                if x.get("id") == payload.get("id"):
                    x["enable"] = bool(payload.get("enable"))
            save_cfg(cfg)
            return self._send(200, {"message": "已保存（重启 AstrBot 后生效）"})

        if p == "/api/plugin":
            ep = "/api/plugin/on" if payload.get("enable") else "/api/plugin/off"
            data, err = ab_call(ep, {"name": payload.get("name")})
            ok = bool(data and data.get("status") == "ok")
            return self._send(200, {"message": ("已" + ("启用 " if payload.get("enable") else "停用 ") + str(payload.get("name"))) if ok else (err or "失败")})

        if p == "/api/persona":
            data, err = ab_call("/api/persona/update", {"persona_id": payload.get("persona_id"),
                                                        "system_prompt": payload.get("system_prompt")})
            ok = bool(data and data.get("status") == "ok")
            return self._send(200, {"message": "人格已保存" if ok else (err or "失败")})

        if p == "/api/wake":
            cfg = load_cfg()
            cfg["wake_prefix"] = payload.get("prefixes") or []
            save_cfg(cfg)
            sh("nohup sh /root/restart_astrbot.sh >/dev/null 2>&1 &", timeout=10)
            return self._send(200, {"message": "已保存，AstrBot 重启中（约 3-6 分钟）"})

        if p == "/api/repair":
            sh("nohup sh /root/quick.sh >/root/quick.log 2>&1 &", timeout=10)
            return self._send(200, {"message": "已开始一键修复，约 3-6 分钟，可点『看修复日志』"})

        if p == "/api/restart":
            t = payload.get("target")
            if t == "all":
                sh("nohup sh /root/restart_all.sh >/dev/null 2>&1 &", timeout=10)
                return self._send(200, {"message": "全部重启中"})
            m = {"astrbot": "restart_astrbot.sh", "snowluma": "restart_snowluma.sh", "qq": "restart_qq.sh"}
            if t in m:
                sh("nohup sh /root/%s >/dev/null 2>&1 &" % m[t], timeout=10)
                return self._send(200, {"message": t + " 重启中"})
            return self._send(400, {"message": "未知目标"})

        return self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    print("panel v3 on :%d" % PORT, flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
