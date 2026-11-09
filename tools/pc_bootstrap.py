#!/usr/bin/env python3
"""pc_bootstrap.py —— 平板回来后的「一键编排」（**只跑在 PC 上**）

用途：把「PC 侧准备工作 + 给平板下发 quick.sh + 取证」串成一条命令：
  1. 检查/拉起 PC 侧三个服务：静态文件服务(80)、日志接收(8081)、模型网关转发(8789)
  2. 检查 hdc 是否连上平板（没连就提示插线/开 USB 调试）
  3. 把 quick.sh 塞进 VM 并执行（优先走 z2 命令通道；通道死了就用 hdc 在终端里敲一行）
  4. 轮询 VM 状态、抓平板截图与 VM 桌面截图，最后打印体检报告

**边界（重要）**：本脚本只负责「从外面推平板」，不含任何平板内数据、不读取平板内业务数据、
不参与机器人运行。平板上的运行体是 scripts/ 与 tests/ 里的脚本；PC 只当工具链
（遥控 + 文件服务器 + 本机模型网关）。关掉 PC，机器人照跑；反过来则不行——所以
它不是架构的一部分，别把它写进数据流。

依赖（全部 PC 侧）：
  - Python 3.12（只用标准库）
  - hdc：鸿蒙版 adb，需在 PATH 上，或用 HDC_BIN 指定绝对路径
  - 同目录的辅助服务：logsvr.py（收 8081 回传）、fwd8789.py（8789 → 127.0.0.1:8788 模型网关）
    —— 这两个是 PC 本机的小工具，未随本仓库发布，**待补**
日志：PC 侧 `tools/remote.log`（z2 通道回传的命令输出）、`tools/tablet.jpg` / `tools/vm_desktop.png`
      （截图产物）；平板侧看 `/root/quick.log`
用法：
    set HDC_DEV=<你的设备序列号>        # 必须，`hdc list targets` 拿；仓库不内置任何真实序列号
    set TABLET_IP=192.168.x.x           # 可选，探活平板四个端口用
    set PC_IP=192.168.x.x               # 可选，VM 从哪个地址 wget quick.sh
    py -3.12 tools/pc_bootstrap.py            # 全流程
    py -3.12 tools/pc_bootstrap.py --check    # 只看状态，不动手（不写文件、不下发命令）
安全提示：
  - `send_cmd()` 会通过 z2 通道下发**任意 shell 命令**（改 `cmd.txt`），等于 PC 上的免密 root
    通道，仅限内网自用；`--check` 不写 cmd.txt。
  - 截图里可能含 QQ 号 / 群名 / 二维码，入库前按 docs/screenshots/README.md 脱敏。
  - 仓库不写死设备序列号、平板 IP 与用户名路径：全部走环境变量，避免把个人环境提交上去
    （对应 docs/testing.md 的 T19 检查）。
"""

import argparse
import base64
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
# 静态文件根：默认用仓库里的 scripts/（quick.sh 等就在那儿，可被 VM 直接 wget）
WWW = os.environ.get("WWW_DIR") or os.path.abspath(os.path.join(HERE, os.pardir, "scripts"))
LOG = os.path.join(HERE, "remote.log")
HDC = os.environ.get("HDC_BIN") or "hdc"
DEV = os.environ.get("HDC_DEV", "")
TABLET_IP = os.environ.get("TABLET_IP", "192.168.x.x")
PC_IP = os.environ.get("PC_IP", "192.168.x.x")
PY = sys.executable


def port_open(host, port, timeout=1.5):
    s = socket.socket()
    s.settimeout(timeout)
    try:
        return s.connect_ex((host, port)) == 0
    finally:
        s.close()


def sh(cmd, timeout=60):
    return subprocess.run(["/bin/sh", "-c", cmd], capture_output=True, text=True, timeout=timeout,
                          cwd=HERE)


def ensure_pc_services():
    """三个 PC 侧后台服务，缺哪个补哪个：80 静态文件 / 8081 日志接收 / 8789 模型网关转发。"""
    started = []
    if not port_open("127.0.0.1", 80):
        subprocess.Popen([PY, "-m", "http.server", "80", "--directory", WWW],
                         cwd=HERE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         creationflags=getattr(subprocess, "DETACHED_PROCESS", 0))
        started.append("http80")
    if not port_open("127.0.0.1", 8081):
        subprocess.Popen([PY, "logsvr.py"], cwd=HERE,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         creationflags=getattr(subprocess, "DETACHED_PROCESS", 0))
        started.append("log8081")
    if not port_open("127.0.0.1", 8789):
        subprocess.Popen([PY, "fwd8789.py"], cwd=HERE,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         creationflags=getattr(subprocess, "DETACHED_PROCESS", 0))
        started.append("fwd8789")
    time.sleep(2.5)
    return started


def pc_status():
    return {
        "http80": port_open("127.0.0.1", 80),
        "log8081": port_open("127.0.0.1", 8081),
        "fwd8789": port_open("127.0.0.1", 8789),
        "tablet_6185": http_ok(TABLET_IP, 6185),
        "tablet_8080": http_ok(TABLET_IP, 8080),
        "tablet_5099": http_ok(TABLET_IP, 5099),
        "tablet_6080": http_ok(TABLET_IP, 6080),
    }


def hdc_ready():
    env = dict(os.environ, MSYS_NO_PATHCONV="1", MSYS2_ARG_CONV_EXCL="*")
    try:
        out = subprocess.run([HDC, "-t", DEV, "shell", "echo ok"], capture_output=True,
                             text=True, timeout=25, env=env).stdout
        return "ok" in out
    except Exception:
        return False


def http_ok(host, port, timeout=6):
    """远端探活必须走真实 HTTP。

    坑：Clash 的 TUN / 透明代理会让 connect_ex() 对任何远端端口都返回 0（本地就握手成功），
    纯 TCP 探测会把「平板已关机」误判成 OK。这里显式禁用 HTTP(S)_PROXY 再请求。
    """
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open("http://%s:%d/" % (host, port), timeout=timeout) as r:
            return 200 <= r.status < 400
    except urllib.error.HTTPError as e:
        return 200 <= e.code < 500
    except Exception:
        return False


def send_cmd(cmd_text, wait=90):
    """通过 z2 通道下发命令：改 cmd.txt → 轮询 remote.log，等到 `#runNNNNN` 与 `--- done`。"""
    marker = "#run%d" % int(time.time() % 100000)
    payload = 'echo "%s"; %s' % (marker, cmd_text)
    path = os.path.join(WWW, "cmd.txt")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(payload + "\n")
    deadline = time.time() + wait
    while time.time() < deadline:
        if os.path.exists(LOG):
            txt = open(LOG, "rb").read().decode("utf-8", "ignore")
            idx = txt.rfind(marker)
            if idx != -1 and "--- done" in txt[idx:]:
                return txt[idx:idx + 4000]
        time.sleep(3)
    return ""


def hdc_type_quick_sh():
    """z2 死了时的兜底：hdc 唤醒 → 起 HiSH → 点终端 → 敲一行命令。"""
    env = dict(os.environ, MSYS_NO_PATHCONV="1", MSYS2_ARG_CONV_EXCL="*")

    def run(*args):
        subprocess.run([HDC, "-t", DEV] + list(args), capture_output=True, text=True,
                       timeout=40, env=env)

    run("shell", "power-shell wakeup")
    time.sleep(1)
    run("shell", "aa start -b app.hackeris.hish -a EntryAbility")
    time.sleep(5)
    run("shell", "uitest uiInput click 1400 500")
    time.sleep(2)
    run("shell", "uitest uiInput text 'sh /root/quick.sh'")
    time.sleep(2)
    run("shell", "uitest uiInput keyEvent 2054")
    time.sleep(5)


def tablet_shot(name="tablet.jpg"):
    env = dict(os.environ, MSYS_NO_PATHCONV="1", MSYS2_ARG_CONV_EXCL="*")
    remote = "/data/local/tmp/_bs.jpeg"
    out = os.path.join(HERE, name)
    subprocess.run([HDC, "-t", DEV, "shell", "snapshot_display -f " + remote],
                   capture_output=True, text=True, timeout=45, env=env)
    subprocess.run([HDC, "-t", DEV, "file", "recv", remote, out.replace("/", "\\")],
                   capture_output=True, text=True, timeout=45, env=env)
    return out if os.path.exists(out) else None


def vm_shot(name="vm_desktop.png"):
    """让 VM 截 X 桌面并回传（shot.sh 输出 IMGSTART/IMGEND 包着 base64），存到本地。"""
    send_cmd("sh /root/shot.sh 2>&1 | tail -2", wait=60)
    time.sleep(3)
    if not os.path.exists(LOG):
        return None
    txt = open(LOG, "rb").read().decode("utf-8", "ignore")
    blocks = re.findall(r"IMGSTART\s*\n(.*?)\nIMGEND", txt, re.S)
    if not blocks:
        return None
    data = base64.b64decode(blocks[-1])
    out = os.path.join(HERE, name)
    with open(out, "wb") as f:
        f.write(data)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--no-shot", action="store_true")
    args = ap.parse_args()

    print("== PC 服务 ==")
    if not args.check:
        print("  started:", ensure_pc_services() or "无需启动")
    for k, v in pc_status().items():
        print("  %-14s %s" % (k, "OK" if v else "DOWN"))

    print("== hdc ==")
    if not DEV:
        print("  未设置 HDC_DEV（设备序列号），跳过 hdc 段。")
        print("  先跑一次 `hdc list targets` 拿到序列号，再 set HDC_DEV=<序列号>。")
        return
    ready = hdc_ready()
    print("  device:", "OK" if ready else "未连接（插线 / 打开 USB 调试 / 允许调试）")
    if args.check or not ready:
        return

    print("== 下发 quick.sh ==")
    out = send_cmd("cd /root && wget -q -O quick.sh http://%s/quick.sh && PC_IP=%s sh quick.sh 2>&1" % (PC_IP, PC_IP),
                   wait=120)
    if not out:
        print("  z2 通道无响应，改用 hdc 敲终端…")
        hdc_type_quick_sh()
        time.sleep(90)
        out = send_cmd("echo probe", wait=40) or "(无回执，请在平板上看 /root/quick.log)"
    print(out[:3000])

    if not args.no_shot:
        print("== 截图 ==")
        print("  tablet:", tablet_shot())
        print("  vm:", vm_shot())

    print("== 结果 ==")
    for k, v in pc_status().items():
        print("  %-14s %s" % (k, "OK" if v else "DOWN"))


if __name__ == "__main__":
    main()
