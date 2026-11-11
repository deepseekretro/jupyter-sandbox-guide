#!/bin/bash
# bootstrap.sh — 初始化 Jupyter 沙盒环境（含 proot）
# 用法: bash bootstrap.sh [--rootfs-dir DIR] [--distro ubuntu|debian|alpine]

set -euo pipefail
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'

log()  { printf '%s[%s]%s %s\n' "$GRN" "$(date +%T)" "$RST" "$*"; }
warn() { printf '%s[%s] WARN%s %s\n' "$YEL" "$(date +%T)" "$RST" "$*"; }
die()  { printf '%s[%s] FAIL%s %s\n' "$RED" "$(date +%T)" "$RST" "$*" >&2; exit 1; }
sec()  { printf '\n%s=== %s ===%s\n' "$BLU" "$*" "$RST"; }

ROOTFS_DIR="${HOME}/proot-rootfs"
DISTRO="ubuntu"
PROOT_BIN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --rootfs-dir) ROOTFS_DIR="$2"; shift 2 ;;
        --distro)     DISTRO="$2";     shift 2 ;;
        -h|--help)    grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)            die "未知参数: $1" ;;
    esac
done

# ── 1. 环境探测 ───────────────────────────────────────────────
sec "1/6 环境探测"
CAPEFF=$(awk '/^CapEff:/{print $2}' /proc/self/status 2>/dev/null || echo "unknown")
echo "  用户    $(id -un) (uid=$(id -u))"
echo "  OS      $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
echo "  内核    $(uname -r)"
echo "  内存    $(free -h | awk '/^Mem:/{print $2}')"
echo "  磁盘    $(df -h / | awk 'NR==2{print $4" 可用"}')"

if [ "$CAPEFF" = "0000000000000000" ]; then
    warn "CapEff=0 → 无特权，将使用 proot"
    NEED_PROOT=1
else
    log "CapEff=$CAPEFF → 有部分特权"
    NEED_PROOT=0
fi

# ── 2. 找/装 proot ────────────────────────────────────────────
sec "2/6 proot"
# 优先检查 Foxytoux freeroot（很多 Jupyter 沙盒预装）
# 只在常见位置浅层搜索并加超时，避免在大目录上卡住
FREEROOT_DIR=""
for base in /home /root /opt /workspace /srv /data; do
    [ -d "$base" ] || continue
    cand=$(timeout 5 find "$base" -maxdepth 6 -type f -name root.sh 2>/dev/null | grep -m1 freeroot || true)
    if [ -n "$cand" ]; then
        FREEROOT_DIR=$(dirname "$cand")
        break
    fi
done

if [ -n "$FREEROOT_DIR" ] && [ -x "${FREEROOT_DIR}/usr/local/bin/proot" ]; then
    log "${GRN}检测到 Foxytoux freeroot: $FREEROOT_DIR${RST}"
    PROOT_BIN="${FREEROOT_DIR}/usr/local/bin/proot"
    if [ -f "${FREEROOT_DIR}/etc/os-release" ]; then
        log "已有 rootfs，直接沿用（跳过下载）"
        ROOTFS_DIR="$FREEROOT_DIR"
        SKIP_ROOTFS=1
    fi
elif command -v proot >/dev/null 2>&1; then
    PROOT_BIN=$(command -v proot)
    log "已有 proot: $PROOT_BIN"
    SKIP_ROOTFS=0
else
    log "未找到预装 freeroot，使用官方 proot 静态二进制"
    mkdir -p "${HOME}/.local/bin"
    PROOT_BIN="${HOME}/.local/bin/proot"
    URL="https://raw.githubusercontent.com/foxytouxxx/freeroot/main/proot-$(uname -m)"
    if curl -fSL --connect-timeout 15 -o "$PROOT_BIN" "$URL"; then
        chmod +x "$PROOT_BIN"
    else
        warn "freeroot 镜像失败，回退到 proot.gitlab.io"
        curl -fSL --connect-timeout 15 -o "$PROOT_BIN" "https://proot.gitlab.io/proot/bin/proot" \
          || die "proot 下载失败，请手动安装"
        chmod +x "$PROOT_BIN"
    fi
    SKIP_ROOTFS=0
fi
"$PROOT_BIN" --version 2>&1 | head -2 | sed 's/^/  /' || warn "proot --version 失败"

# ── 3. 准备 rootfs ────────────────────────────────────────────
sec "3/6 rootfs"
if [ -f "${ROOTFS_DIR}/etc/os-release" ]; then
    log "rootfs 已存在: $ROOTFS_DIR"
    grep PRETTY_NAME "${ROOTFS_DIR}/etc/os-release" | sed 's/^/  /'
else
    log "创建 rootfs: $ROOTFS_DIR ($DISTRO)"
    mkdir -p "$ROOTFS_DIR"
    TMP=$(mktemp -d)
    case "$DISTRO" in
        ubuntu)
            URL="https://cdimage.ubuntu.com/ubuntu-base/releases/20.04/release/ubuntu-base-20.04.5-base-amd64.tar.gz"
            ;;
        debian)
            URL="https://github.com/debuerreotype/docker-debian-artifacts/raw/dist-amd64/bookworm/rootfs.tar.xz"
            ;;
        alpine)
            URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-minirootfs-3.19.1-x86_64.tar.gz"
            ;;
        *) die "不支持的发行版: $DISTRO" ;;
    esac
    log "下载 $URL"
    curl -fSL --connect-timeout 20 -o "$TMP/rootfs.tar" "$URL" || die "rootfs 下载失败"
    ls -lh "$TMP/rootfs.tar" | sed 's/^/  /'
    log "解包..."
    case "$URL" in
        *.tar.xz) tar xJf "$TMP/rootfs.tar" -C "$ROOTFS_DIR" ;;
        *)        tar xzf "$TMP/rootfs.tar" -C "$ROOTFS_DIR" ;;
    esac
    rm -rf "$TMP"
    log "rootfs 就绪"
fi

# ── 4. 写启动脚本 ─────────────────────────────────────────────
sec "4/6 生成启动脚本"
LAUNCHER="${HOME}/enter-proot.sh"
cat > "$LAUNCHER" <<EOF
#!/bin/bash
# 进入 proot 环境（由 bootstrap.sh 生成）
exec "${PROOT_BIN}" \\
  --rootfs="${ROOTFS_DIR}" \\
  -0 \\
  -w /root \\
  -b /dev \\
  -b /sys \\
  -b /proc \\
  -b /etc/resolv.conf \\
  \${EXTRA_BINDS:-} \\
  --kill-on-exit \\
  "\$@"
EOF
chmod +x "$LAUNCHER"
log "启动脚本: $LAUNCHER"
echo "  用法: $LAUNCHER            # 进入交互 shell"
echo "        $LAUNCHER bash -c 'cmd'  # 执行命令"

# ── 5. 初始化 guest 环境 ──────────────────────────────────────
sec "5/6 初始化 guest（源、DNS、policy）"
"$LAUNCHER" /bin/bash -s <<'GUEST' || warn "guest 初始化有报错（通常无害）"
set -u
# 禁用服务自启（proot 没有 systemd）
cat > /usr/sbin/policy-rc.d <<'EOX'
#!/bin/sh
exit 101
EOX
chmod +x /usr/sbin/policy-rc.d

# DNS
[ -s /etc/resolv.conf ] || echo "nameserver 8.8.8.8" > /etc/resolv.conf

# apt 源
if [ -f /etc/os-release ]; then
  . /etc/os-release
  case "${VERSION_CODENAME:-}" in
    focal|jammy|noble|bookworm|bullseye|buster)
      cat > /etc/apt/sources.list <<EOA
deb http://archive.ubuntu.com/ubuntu ${VERSION_CODENAME} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${VERSION_CODENAME}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${VERSION_CODENAME}-security main restricted universe multiverse
EOA
      ;;
  esac
fi
mkdir -p /root
echo "guest 初始化完成: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
GUEST

# ── 6. 装常用工具（可选） ─────────────────────────────────────
sec "6/6 装常用工具"
read -r -p "是否安装常用工具（git/curl/build-essential/python3 等，约 10 分钟）? [y/N] " ANS
if [ "${ANS,,}" = "y" ]; then
    "$LAUNCHER" /bin/bash -s <<'GUEST' || warn "部分包安装失败"
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates curl wget git vim less htop \
  build-essential python3 python3-pip \
  unzip p7zip-full tar xz-utils \
  tmux procps net-tools iproute2 \
  2>&1 | tail -20
echo "---"
echo "已装: $(dpkg -l | grep -c '^ii') 个包"
GUEST
else
    log "跳过工具安装"
fi

# ── 完成 ──────────────────────────────────────────────────────
sec "完成"
cat <<EOF
  proot      $PROOT_BIN
  rootfs     $ROOTFS_DIR
  启动器     $LAUNCHER

  进入环境:
    $LAUNCHER

  直接执行命令:
    $LAUNCHER bash -c 'apt-get install -y nginx'

  额外绑定宿主目录（例如把持久盘挂进去）:
    EXTRA_BINDS="-b /path/to/persist:/mnt/persist" $LAUNCHER

提示:
  • proot 里 mount/chroot/sysctl 仍不可用（只模拟）
  • 没有 systemd，服务用 nohup/tmux 起
  • I/O 密集型任务会慢 30-60%
  • 详见 docs/03-proot详解.md
EOF
