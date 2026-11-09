"""把 PC 上只监听 127.0.0.1:8788 的 DeepSeek 网关，转发到 0.0.0.0:8789，让平板能直连。

启动：py -3.12 fwd8789.py
用途：临时方案——平板上的 AstrBot 用 http://<PC_IP>:8789/v1 访问 PC 的模型网关。
注意：PC 关机/断开后平板就用不了，要真正独立需换成公网可访问的 key。
"""

import http.server
import socketserver
import urllib.request
import urllib.error

UPSTREAM = "http://127.0.0.1:8788"
LISTEN_PORT = 8789


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _forward(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        url = UPSTREAM + self.path
        headers = {
            k: v for k, v in self.headers.items()
            if k.lower() not in ("host", "content-length", "connection")
        }
        req = urllib.request.Request(url, data=body, headers=headers, method=self.command)
        try:
            with urllib.request.urlopen(req, timeout=300) as resp:
                data = resp.read()
                self.send_response(resp.status)
                for k, v in resp.headers.items():
                    if k.lower() in ("transfer-encoding", "connection", "content-length"):
                        continue
                    self.send_header(k, v)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        except urllib.error.HTTPError as e:
            data = e.read()
            self.send_response(e.code)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            msg = str(e).encode()
            self.send_response(502)
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)

    do_GET = _forward
    do_POST = _forward
    do_PUT = _forward
    do_DELETE = _forward

    def log_message(self, fmt, *args):
        print("[fwd]", self.address_string(), fmt % args, flush=True)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    print(f"forwarding 0.0.0.0:{LISTEN_PORT} -> {UPSTREAM}", flush=True)
    with Server(("0.0.0.0", LISTEN_PORT), Handler) as httpd:
        httpd.serve_forever()
