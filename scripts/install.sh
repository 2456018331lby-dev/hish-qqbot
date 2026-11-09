#!/bin/sh
# install.sh —— 从零部署引导脚本（骨架）
#
# 运行环境：HiSH 里的 Alpine 3.22（aarch64 / musl），**在 HiSH 终端里**执行，
#           不是在你自己的 Ubuntu 上，也不是在平板的「卓易通」里。
# 用法：
#   1) 先按 docs/flow.md 的阶段 0–1 把虚机调成 4 核 / 4096 MB、加 6185 端口映射；
#   2) 把本仓库传到虚机（HiSH 共享文件夹 / wget / scp 任选）；
#   3) cd 到仓库根目录，执行：sh scripts/install.sh
#      只跑某一步：sh scripts/install.sh 3
#
# 本脚本是**骨架**：每个阶段只做「能自动化的部分」，凡是有歧义、要下载第三方包、
# 需要人工扫码的步骤，一律打印指引后停下，让你手动确认。原因是这个工程里
# 真正会踩坑的地方（QQ 掉登录、hook 失效、模型 key）全都没法脚本化。
#
# 依赖（Alpine 侧）：apk、wget、tar（GNU tar，不是 busybox tar）、chroot、mount
# 依赖（chroot 内）：见阶段 3
set -u

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ROOT_UBUNTU=/root/ubuntu
UBUNTU_TARBALL=ubuntu-base-24.04.5-base-arm64.tar.gz
UBUNTU_URL="http://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/$UBUNTU_TARBALL"
SRC_ASTRBOT=/root/src/AstrBot-master
VENV=/root/venv
SNOWLUMA_DIR=/root/sl

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\n[FATAL] %s\n' "$*" >&2; exit 1; }
ask() {
  # ask "提示" -> 回车继续，其它键退出
  printf '%s [回车继续 / Ctrl-C 退出] ' "$1"
  read -r _ || exit 1
}

# ---------------------------------------------------------------- 阶段 0：体检
stage0_check() {
  say "阶段 0：环境体检"
  echo "内核: $(uname -a)"
  [ "$(uname -m)" = "aarch64" ] || die "本工程只在 aarch64 上验证过，当前是 $(uname -m)"
  echo "内存: $(free -m 2>/dev/null | sed -n 2p)"
  echo "磁盘:"; df -h / /root 2>/dev/null

  # HiSH 默认虚机是 512 MB / 1 核，装不动东西；低于 2 GB 直接劝退
  mem_mb=$(free -m 2>/dev/null | awk '/Mem:/{print $2}')
  if [ -n "${mem_mb:-}" ] && [ "$mem_mb" -lt 2000 ]; then
    die "内存只有 ${mem_mb} MB。先在 HiSH：齿轮 → 模拟器管理 → 修改 → 4 核 / 4096 MB，再重跑。"
  fi

  command -v chroot >/dev/null || die "缺 chroot"
  command -v wget   >/dev/null || die "缺 wget：apk add --no-cache wget"
  echo "OK"
}

# ------------------------------------------------- 阶段 1：Alpine 侧基础包
stage1_apk() {
  say "阶段 1：Alpine 侧基础包"
  # busybox tar 解 ubuntu-base 会失败（镜像里有 merged-/usr 软链），必须装 GNU tar
  apk add --no-cache tar wget ca-certificates procps net-tools || die "apk add 失败，检查网络/DNS"
  tar --version | head -1
  echo "OK"
}

# ------------------------------------- 阶段 2：下载并解包 Ubuntu base + chroot
stage2_ubuntu() {
  say "阶段 2：Ubuntu 24.04 arm64 chroot"
  [ -f "/root/$UBUNTU_TARBALL" ] || {
    echo "下载 $UBUNTU_URL"
    wget -O "/root/$UBUNTU_TARBALL" "$UBUNTU_URL" || die "下载失败（平板网络能否访问 cdimage.ubuntu.com？）"
  }
  mkdir -p "$ROOT_UBUNTU"
  echo "解两遍（第一遍会报 tar: Cannot open '.../dev/...' 之类，是正常的）"
  tar -xzf "/root/$UBUNTU_TARBALL" -C "$ROOT_UBUNTU" || true
  tar -xzf "/root/$UBUNTU_TARBALL" -C "$ROOT_UBUNTU" || die "第二遍解包仍失败"

  mount -t proc proc "$ROOT_UBUNTU/proc" 2>/dev/null || true
  mount --bind /dev "$ROOT_UBUNTU/dev"   2>/dev/null || true
  mount --bind /sys "$ROOT_UBUNTU/sys"   2>/dev/null || true

  # arm64 必须换 ubuntu-ports（不是 archive）
  cat > "$ROOT_UBUNTU/etc/apt/sources.list" <<'EOF'
deb http://mirrors.aliyun.com/ubuntu-ports/ noble main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu-ports/ noble-updates main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu-ports/ noble-backports main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu-ports/ noble-security main restricted universe multiverse
EOF
  echo "验证 chroot："
  chroot "$ROOT_UBUNTU" /bin/bash -lc 'cat /etc/os-release | head -2; uname -m' || die "chroot 进不去"
  ask "chroot 能进？"
}

# ------------------------------------------- 阶段 3：图形环境（Xvfb + 依赖库）
stage3_gui() {
  say "阶段 3：Xvfb 与 QQ 的运行库"
  # 这批包名是 Ubuntu 24.04（noble）上的实际名字，t64 后缀是 noble 的 time_t 迁移改名，
  # 在 22.04 及更早的镜像是 libatk1.0-0 / libasound2，别照抄。
  chroot "$ROOT_UBUNTU" /bin/bash -lc '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y xvfb x11-utils fonts-noto-cjk \
      libnss3 libatk1.0-0t64 libgbm1 libxkbcommon0 libgtk-3-0 libasound2t64 \
      libsecret-1-0 imagemagick xdotool procps net-tools wget curl
  ' || die "apt 安装失败（先 apt-get update 看源）"
  echo "手动起一次假屏幕试试："
  chroot "$ROOT_UBUNTU" /bin/bash -lc 'Xvfb :99 -screen 0 1280x800x24 -nolisten tcp & sleep 3; DISPLAY=:99 xdpyinfo | head -5; kill %1'
  echo "OK（正式启动交给 scripts/boot.sh）"
}

# ------------------------------------------------- 阶段 4：Linux QQ（手动）
stage4_qq() {
  say "阶段 4：Linux QQ（需要手动确认版本/安装包）"
  if [ -x "$ROOT_UBUNTU/opt/QQ/qq" ]; then
    echo "已存在 /opt/QQ/qq，跳过。"
    return 0
  fi
  cat <<'EOF'
这一步刻意不做自动化：
  - QQ 安装包要从官网取，版本与下载 URL 会变，本仓库不写死（当前实测版本 3.2.32，待验证）；
  - 装完确认路径是 /opt/QQ/qq，否则 scripts/*.sh 里的路径都要跟着改。
装完跑一遍（必须带这四个参数，否则在 QEMU 里必崩）：
  DISPLAY=:99 /opt/QQ/qq --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-software-rasterizer
EOF
  ask "装好后回车继续（或 Ctrl-C 稍后再跑阶段 5）"
}

# --------------------------------------------- 阶段 5：AstrBot（venv 隔离）
stage5_astrbot() {
  say "阶段 5：AstrBot 源码 + venv"
  # 注意分层：AstrBot 跑在 **Alpine 侧**（boot.sh 里直接 python3 main.py，不 chroot），
  # 所以它的 python 与 venv 都是 musl 的；chroot 里的 glibc python 给不了它用。
  apk add --no-cache python3 py3-pip git || die "apk 装 python3/git 失败"
  echo "python: $(python3 -V)"

  if [ ! -d "$SRC_ASTRBOT" ]; then
    mkdir -p /root/src
    git clone https://github.com/AstrBotDevs/AstrBot "$SRC_ASTRBOT" || die "clone AstrBot 失败"
  else
    echo "已存在 $SRC_ASTRBOT，跳过 clone。"
  fi

  if [ ! -x "$VENV/bin/python3" ]; then
    python3 -m venv "$VENV" || die "建 venv 失败（Alpine 需 py3-pip 与 python3-venv 能力）"
  fi
  echo "装依赖（TCG 下很慢，可能 20–40 分钟，慢是正常的）"
  # musl 上少数带 C 扩展的依赖没有预编译 wheel，会走源码编译；先备好编译链
  apk add --no-cache build-base libffi-dev openssl-dev || true
  "$VENV/bin/pip" install -U pip || die "pip 自升级失败"
  "$VENV/bin/pip" install -r "$SRC_ASTRBOT/requirements.txt" \
    || die "依赖安装失败；看报错是不是缺 -dev 包或网络超时"

  echo "先手动起一次，让 AstrBot 生成 data/cmd_config.json："
  echo "  cd $SRC_ASTRBOT && $VENV/bin/python3 -u main.py    # 首次 3–4 分钟，Ctrl-C 停掉"
  ask "cmd_config.json 生成了？"

  echo "写平台适配器（aiocqhttp，反向 WS 6199）："
  python3 "$REPO_DIR/scripts/patch_cfg.py" \
    || echo "提示：本步骤需在能读到 $SRC_ASTRBOT/data/cmd_config.json 的前提下执行"
  echo "模型源请在 6185 后台填 base_url + key + model；不要写进仓库。"
}

# ------------------------------------------- 阶段 6：SnowLuma（手动下载）
stage6_snowluma() {
  say "阶段 6：SnowLuma（QQ 注入端）"
  if [ -d "$SNOWLUMA_DIR" ]; then
    echo "已存在 $SNOWLUMA_DIR，跳过。"
  else
    cat <<'EOF'
从这里开始只能人工做：
  1. 取 SnowLuma 发行包（当前实测 2.4.2，待验证），解到 /root/sl，确认里面是 launcher.sh；
  2. 首次启动后打开 http://127.0.0.1:5099 ：同意协议 → 设密码 → 选中 QQ 进程 → 「加载」注入；
  3. OneBot 侧填 AstrBot 的反向 WS 地址 127.0.0.1:6199；
  4. 勾上 hookAutoLoad: true，让 QQ 一启动就自动注入（开机自启的一半靠它）。
EOF
  fi
  ask "SnowLuma 装好并注入成功？"
}

# --------------------------------------------------- 阶段 7：脚本与自启钩子
stage7_autostart() {
  say "阶段 7：部署脚本 + 开机自启"
  for f in boot.sh restart_all.sh restart_astrbot.sh restart_snowluma.sh restart_qq.sh hide_qq.sh; do
    cp "$REPO_DIR/scripts/$f" "/root/$f" && chmod +x "/root/$f" || die "拷贝 $f 失败"
  done
  cp "$REPO_DIR/scripts/panel_v3.py" /root/panel.py || die "拷贝 panel_v3.py 失败"
  [ -d /root/novnc ] || echo "提示：noVNC 没装，6080 会起不来（不影响 QQ/机器人本身）"

  # HiSH 的 Alpine 明确说 OpenRC is disabled by default，所以不能用 rc-update，
  # 只能挂在 login shell 的 .profile 上。BOTSTACK_STARTED 防止重复拉起。
  if ! grep -q BOTSTACK_STARTED /root/.profile 2>/dev/null; then
    cat >> /root/.profile <<'EOF'

# --- QQ 机器人栈开机自启（本仓库 scripts/install.sh 追加，删掉这三行就是关闭自启）---
if [ -z "$BOTSTACK_STARTED" ]; then
  export BOTSTACK_STARTED=1
  ( sh /root/boot.sh > /root/boot.log 2>&1 & )
  echo "[bot] 正在启动 QQ / SnowLuma / AstrBot ..."
fi
EOF
    echo "已写入 /root/.profile"
  else
    echo "/root/.profile 已有自启钩子，跳过。"
  fi

  echo "现在手动跑一次全量启动：sh /root/boot.sh"
  echo "看结果：tail -20 /root/boot.log"
}

# ---------------------------------------------------------------------- 主流程
case "${1:-all}" in
  0) stage0_check ;;
  1) stage1_apk ;;
  2) stage2_ubuntu ;;
  3) stage3_gui ;;
  4) stage4_qq ;;
  5) stage5_astrbot ;;
  6) stage6_snowluma ;;
  7) stage7_autostart ;;
  all)
    stage0_check
    stage1_apk
    stage2_ubuntu
    stage3_gui
    stage4_qq
    stage5_astrbot
    stage6_snowluma
    stage7_autostart
    say "全部阶段结束"
    echo "检查清单见 docs/testing.md；排错见 docs/flow.md 的故障表。"
    ;;
  *) die "未知阶段：$1（可用 0-7 / all）" ;;
esac
