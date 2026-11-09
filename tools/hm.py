#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""hm.py — HarmonyOS 平板/手机控制台（基于 hdc，等价于 adb 那套 mobile-mcp 的用法）

定位：这是 **PC 侧** 的辅助工具，只在「用电脑接管平板」时用；机器人本体不需要它。
      鸿蒙 7 不是 Android，`adb devices` 永远为空，等价物是华为 hdc
      （HarmonyOS Device Connector，本机验证过的版本是 hdc 3.1.0e）。
依赖：hdc 可执行文件，默认路径 C:\\Users\\24560\\tools\\hdc\\hdc.exe，
      可用环境变量 HDC_BIN 覆盖。仅标准库。
安全提示：hdc 等于 root 级调试权限，无线调试的端口每次开关都会变；
      不要把这个脚本暴露给不可信网络。

用法示例：
  python hm.py devs                     # 发现 + 列出设备
  python hm.py conn 192.168.1.23:37111  # 无线连接（平板开发者选项里那个 IP:端口）
  python hm.py info                     # 型号/版本/API
  python hm.py shot out.png             # 截屏到 PC
  python hm.py tap 500 1200             # 点击
  python hm.py swipe 500 1500 500 500 400
  python hm.py text "你好"              # 输入文字（英文/数字最稳）
  python hm.py key back|home|power|recents
  python hm.py ui out.json              # dump 控件树（JSON）
  python hm.py apps                     # 已安装应用 bundle 列表
  python hm.py start <bundle> [ability]
  python hm.py shell "ls /data/local/tmp"
  python hm.py push 本地 远端 / pull 远端 本地
  python hm.py fport 6185               # 把平板上的 6185 转发到本机 6185
"""
import os, subprocess, sys, time, shutil, json

HDC = os.environ.get("HDC_BIN") or r"C:\Users\24560\tools\hdc\hdc.exe"
TMP = "/data/local/tmp"
KEYMAP = {"back": 2, "home": 3, "power": 18, "recents": 187, "menu": 2085,
          "enter": 2054, "del": 2055, "volup": 16, "voldown": 17}


_KEY = None


def pick_key():
    """从 list targets -v 里挑真正的设备（USB/TCP），排除 COM3/COM4 这类 UART 串口。"""
    global _KEY
    if _KEY:
        return _KEY
    rc, out, err = run(["-t", "none", "list", "targets", "-v"], timeout=25)
    text = (out or "") + (err or "")
    cands = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        key, typ, state = parts[0], parts[1], parts[2]
        if typ.upper() in ("USB", "TCP") and state.lower().startswith("connect"):
            cands.append(key)
    if cands:
        _KEY = cands[0]
        return _KEY
    return None


def run(args, timeout=60, binary=False):
    if args and args[0] not in ("-t", "list", "discover", "tconn", "kill", "version", "-v", "help", "-h"):
        k = pick_key()
        if k:
            args = ["-t", k] + args
    p = subprocess.run([HDC] + args, capture_output=True, timeout=timeout)
    if binary:
        return p.returncode, p.stdout, p.stderr
    out = (p.stdout or b"").decode("utf-8", "replace")
    err = (p.stderr or b"").decode("utf-8", "replace")
    return p.returncode, out, err


def sh(cmd, timeout=60):
    return run(["shell", cmd], timeout=timeout)


def has_device():
    rc, out, err = run(["list", "targets"])
    txt = (out + err).strip()
    return rc == 0 and txt and "[Empty]" not in txt and "Empty" not in txt


def need_device():
    if not has_device():
        print("❌ 没有连接设备。先在平板开 开发者选项→无线调试，然后：python hm.py tconn <IP:端口>")
        sys.exit(2)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    cmd, a = sys.argv[1], sys.argv[2:]

    if cmd in ("devs", "discover", "list"):
        rc, out, err = run(["list", "targets", "-v"])
        print("已连接设备:\n" + ((out or "") + (err or "")).strip())
        rc, out, err = run(["discover"], timeout=15)
        found = ((out or "") + (err or "")).strip()
        print("局域网发现:\n" + (found if found else "(未发现，检查平板是否开了无线调试、是否同一 WiFi)"))
        return

    if cmd in ("conn", "tconn"):
        rc, out, err = run(["tconn"] + a)
        print((out or "") + (err or ""))
        print("提示：平板可能弹窗要求允许调试，点“允许/信任”")
        return

    need_device()

    if cmd == "info":
        for p in ["const.product.model", "const.product.brand", "const.product.software.version",
                  "const.ohos.apiversion", "const.product.name"]:
            rc, out, err = sh(f"param get {p}", 20)
            print(f"{p:36s} = {(out or err).strip()}")
        rc, out, err = sh("wm size", 20)
        print("屏幕分辨率:", (out or err).strip())
        return

    if cmd == "shot":
        out_path = a[0] if a else "shot_%d.png" % int(time.time())
        remote = f"{TMP}/_hm_shot.jpeg"
        sh(f"snapshot_display -f {remote}")
        rc, o, e = run(["file", "recv", remote, out_path])
        sh(f"rm -f {remote}")
        print("已保存:", out_path, (o or e).strip())
        return

    if cmd == "tap":
        x, y = a[0], a[1]
        print(sh(f"uitest uiInput click {x} {y}")[1:])
        return

    if cmd == "swipe":
        x1, y1, x2, y2 = a[0], a[1], a[2], a[3]
        ms = a[4] if len(a) > 4 else "400"
        print(sh(f"uitest uiInput swipe {x1} {y1} {x2} {y2} {ms}")[1:])
        return

    if cmd == "text":
        txt = " ".join(a)
        rc, out, err = sh(f'uitest uiInput text "{txt}"')
        print((out or "") + (err or ""))
        return

    if cmd == "key":
        k = a[0].lower()
        code = KEYMAP.get(k, a[0])
        print(sh(f"uitest uiInput keyEvent {code}")[1:])
        return

    if cmd == "ui":
        out_path = a[0] if a else "ui.json"
        remote = f"{TMP}/_hm_layout.json"
        sh(f"uitest dumpLayout -p {remote}")
        run(["file", "recv", remote, out_path])
        sh(f"rm -f {remote}")
        print("已保存:", out_path)
        return

    if cmd == "apps":
        rc, out, err = sh("bm dump -a", 60)
        print((out or "") + (err or ""))
        return

    if cmd == "start":
        bundle = a[0]
        ability = a[1] if len(a) > 1 else "EntryAbility"
        rc, out, err = sh(f"aa start -b {bundle} -a {ability}")
        print((out or "") + (err or ""))
        return

    if cmd == "shell":
        rc, out, err = sh(" ".join(a))
        print(out, end="")
        if err:
            print(err, end="", file=sys.stderr)
        return

    if cmd == "push":
        print(run(["file", "send", a[0], a[1]])[1:])
        return

    if cmd == "pull":
        print(run(["file", "recv", a[0], a[1]])[1:])
        return

    if cmd == "fport":
        port = a[0]
        print(run(["fport", f"tcp:{port}", f"tcp:{port}"])[1:])
        return

    print("未知命令:", cmd)
    print(__doc__)


if __name__ == "__main__":
    main()
