#!/usr/bin/env python3
"""vyceai_proxy.py —— 把「非流式」请求翻译成上游唯一接受的「流式」请求的适配代理。

为什么需要它：vyceai.com 的 /v1/chat/completions 对 deepseek-v4.1 只接受
"stream": true；普通非流式请求一律返回
  {"error":{"message":"Invalid request...","code":"invalid_request"}}
而 AstrBot 默认走非流式调用，所以直接对接会一直报错。

做法：监听 127.0.0.1:8790，收 AstrBot 的普通请求 → 强制 stream=true 转发上游
→ 把 SSE 增量拼回一个标准 chat.completion JSON 返回。

依赖：仅 Python 3 标准库（json / os / sys / urllib / http.server），无需 pip 安装。
      upstream 侧需要能 HTTPS 访问 vyceai（或任何只吃 stream 的 OpenAI 兼容网关）。
日志：/root/vyceai_proxy.log（由启动命令重定向；每条请求一行 [proxy] 访问记录，
      不打印 prompt 与 key）。
用法：
    nohup python3 /root/vyceai_proxy.py >/root/vyceai_proxy.log 2>&1 &
AstrBot 里把该 provider 的 api_base 指到 http://127.0.0.1:8790/v1 即可。

环境变量：
    UPSTREAM  上游基址，默认 https://vyceai.com/v1
    PORT      监听端口，默认 8790
    TIMEOUT   单次请求超时秒数，默认 300（流式拼包要等整段生成完）

安全提示：
    - 只 bind 127.0.0.1，不对外。**不要**改成 0.0.0.0，否则等于把带 key 的
      上游通道开给同网段所有人。
    - 它不校验自己的调用方，鉴权完全靠客户端传上来的 Authorization 头透传；
      不要把它的端口做任何端口映射 / 反代。
    - 日志只做访问行记录，不含请求体；如要排查请临时加日志，别把 prompt 写进文件。
"""

import json
import os
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("UPSTREAM", "https://vyceai.com/v1").rstrip("/")
PORT = int(os.environ.get("PORT", "8790"))
TIMEOUT = int(os.environ.get("TIMEOUT", "300"))


def upstream_chat(payload, auth_header):
    body = dict(payload)
    body["stream"] = True
    data = json.dumps(body, ensure_ascii=False).encode()
    headers = {
        "Content-Type": "application/json",
        "Authorization": auth_header or "",
        "Accept": "text/event-stream",
        "User-Agent": "vyceai-proxy/1.0",
    }
    req = urllib.request.Request(UPSTREAM + "/chat/completions", data=data, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        content_type = resp.headers.get("Content-Type", "")
        chunks = []
        if "text/event-stream" not in content_type:
            # 上游没按流式回，直接返回原文
            return resp.read()
        for raw in resp:
            line = raw.decode("utf-8", "ignore").strip()
            if not line.startswith("data:"):
                continue
            piece = line[5:].strip()
            if piece == "[DONE]":
                break
            try:
                chunks.append(json.loads(piece))
            except Exception:
                continue
    if not chunks:
        raise RuntimeError("upstream streamed nothing")

    text_parts = []
    reasoning_parts = []
    finish_reason = None
    role = "assistant"
    model = chunks[0].get("model", "")
    cid = chunks[0].get("id", "")
    created = chunks[0].get("created", 0)
    usage = {}
    for ch in chunks:
        if ch.get("usage"):
            usage = ch["usage"]
        for choice in ch.get("choices") or []:
            delta = choice.get("delta") or {}
            if delta.get("role"):
                role = delta["role"]
            if delta.get("reasoning_content"):
                reasoning_parts.append(delta["reasoning_content"])
            if delta.get("content"):
                text_parts.append(delta["content"])
            if choice.get("finish_reason"):
                finish_reason = choice["finish_reason"]

    message = {"role": role, "content": "".join(text_parts)}
    if reasoning_parts:
        message["reasoning_content"] = "".join(reasoning_parts)
    result = {
        "id": cid or "chatcmpl-proxy",
        "object": "chat.completion",
        "created": created or 0,
        "model": model,
        "choices": [{"index": 0, "message": message, "finish_reason": finish_reason or "stop"}],
    }
    if usage:
        result["usage"] = usage
    return json.dumps(result, ensure_ascii=False).encode()


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            req = urllib.request.Request(UPSTREAM + "/models",
                                         headers={"Authorization": self.headers.get("Authorization", "")})
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    return self._send(200, r.read())
            except Exception as e:
                return self._send(502, json.dumps({"error": str(e)}))
        return self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n)
        try:
            payload = json.loads(raw.decode() or "{}")
        except Exception:
            return self._send(400, json.dumps({"error": "bad json"}))
        try:
            out = upstream_chat(payload, self.headers.get("Authorization", ""))
            return self._send(200, out)
        except urllib.error.HTTPError as e:
            body = e.read()
            return self._send(e.code, body)
        except Exception as e:
            return self._send(502, json.dumps({"error": str(e)}))

    def log_message(self, fmt, *args):
        sys.stdout.write("[proxy] %s\n" % (fmt % args))
        sys.stdout.flush()


if __name__ == "__main__":
    print("vyceai proxy on :%d -> %s" % (PORT, UPSTREAM), flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
