#!/usr/bin/env python3
"""panel_preview.py —— 在 PC 上离线预览 panel_v3 的界面（数据是假的）。

用途：平板不在手上时，先验证 panel_v3 的 HTML/JS 有没有渲染错误、体检卡/性能卡/维修页布局对不对。
跑法：py -3.12 panel_preview.py  →  浏览器打开 http://127.0.0.1:8099/
说明：/api/* 返回固定假数据；真实部署仍是 panel_v3.py。
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "hish-qqbot", "scripts"))

import panel_v3 as P  # noqa: E402

FAKE_STATUS = {
    "host": "hish · aarch64",
    "verdict": "全能聊",
    "services": {"xvfb": True, "qq": True, "snowluma": True, "astrbot": True, "panel": True},
    "models": [{"id": "ben", "model": "deepseek-v4.1-flash", "enable": True},
               {"id": "vyceai", "model": "deepseek-v4.1", "enable": False}],
    "wake_prefix": [],
    "ab_login": True,
    "perf": {"nproc": "8", "load": "3.42 4.10 4.55", "mem": "Mem: 4012 1620 2392",
             "uptime_sec": 4211, "ab_ready_at": "2026-11-09 18:42:07", "qq_proc": "5516", "watchdog": "on"},
}
FAKE_PLUGINS = {"items": [
    {"name": "astrbot_plugin_angel_memory", "display": "天使记忆", "version": "1.2.0", "activated": True},
    {"name": "astrbot_plugin_livingmemory", "display": "LivingMemory", "version": "0.9.1", "activated": False},
    {"name": "astrbot_plugin_apis", "display": "APIs", "version": "2.0.3", "activated": True},
    {"name": "astrbot_plugin_qzone", "display": "QQ 空间", "version": "1.0.7", "activated": True},
]}
FAKE_PERSONAS = {"items": [{"persona_id": "default", "system_prompt": "你是一只住在平板里的猫娘助手，说话简短。"}]}
FAKE_LOGS = {"text": "[18:42:07] AstrBot started\n[18:42:19] 适配器已连接\n"
                     "[18:43:02] [default(aiocqhttp)] 火娃/2456018331: 在吗\n"
                     "[18:43:11] Prepare to send - 火娃/2456018331: 在的，怎么了。"}


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
            return self._send(200, P.PAGE, "text/html; charset=utf-8")
        if p.startswith("/settings"):
            return self._send(200, P.SETTINGS, "text/html; charset=utf-8")
        if p.startswith("/quick"):
            return self._send(200, P.QUICK, "text/html; charset=utf-8")
        if p == "/api/status":
            return self._send(200, FAKE_STATUS)
        if p == "/api/perf":
            return self._send(200, FAKE_STATUS["perf"])
        if p == "/api/logs":
            return self._send(200, FAKE_LOGS)
        if p == "/api/plugins":
            return self._send(200, FAKE_PLUGINS)
        if p == "/api/personas":
            return self._send(200, FAKE_PERSONAS)
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(n)
        return self._send(200, {"message": "预览模式：不会真的改配置"})

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    print("preview on http://127.0.0.1:8099/", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 8099), H).serve_forever()
