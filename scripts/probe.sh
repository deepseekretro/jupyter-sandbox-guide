#!/bin/bash
# probe.sh — 一键探测 Jupyter 沙盒的资源与限制
# 用法: bash probe.sh [--memtest]
#   --memtest  额外做内存上限实测（会占用大量内存直到被杀，慎用）

set -u
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'

hr() { printf '%s\n' "────────────────────────────────────────────────"; }
sec() { printf '\n%s%s%s\n' "$BLU" "=== $* ===" "$RST"; }

sec "系统"
[ -f /etc/os-release ] && . /etc/os-release && echo "OS        ${PRETTY_NAME:-unknown}"
echo "内核      $(uname -r)"
echo "架构      $(uname -m)"
echo "主机名    $(hostname)"
echo "运行时长  $(uptime -p 2>/dev/null || uptime)"

sec "用户与权限"
echo "身份      $(id)"
if grep -q CapEff /proc/self/status; then
    CAPEFF=$(awk '/^CapEff:/{print $2}' /proc/self/status)
    echo "CapEff    $CAPEFF"
    if [ "$CAPEFF" = "0000000000000000" ]; then
        echo "          ${RED}← 无任何 capability！chroot/mount 全部不可用${RST}"
        echo "          ${YEL}→ 需要 rootfs 能力时请用 proot${RST}"
    else
        echo "          ${GRN}← 有 capability（可能可 chroot/mount）${RST}"
    fi
fi
if grep -q Seccomp /proc/self/status; then
    SC=$(awk '/^Seccomp:/{print $2}' /proc/self/status)
    echo "Seccomp   $SC $([ "$SC" = "0" ] && echo '(未启用)' || echo '(已启用，部分 syscall 会被拦)')"
fi

sec "CPU"
echo "逻辑核数  $(nproc)"
lscpu 2>/dev/null | grep -E '^Model name|^CPU\(s\)|^Thread|^Core|^Socket' | sed 's/^/          /' \
  || grep -m1 'model name' /proc/cpuinfo | sed 's/^/          /'
[ -f /sys/fs/cgroup/cpu.max ] && echo "cpu.max   $(cat /sys/fs/cgroup/cpu.max)"

sec "内存"
free -h | sed 's/^/  /'
echo
if [ -f /sys/fs/cgroup/memory.current ]; then
    echo "memory.current  $(( $(cat /sys/fs/cgroup/memory.current) / 1048576 )) MB"
    echo "memory.max      $(cat /sys/fs/cgroup/memory.max 2>/dev/null)"
    echo
    echo "memory.stat 明细:"
    awk '/^(anon|file|kernel|kernel_stack|slab|sock|shmem) /{printf "  %-14s %6.0f MB\n", $1, $2/1048576}' \
      /sys/fs/cgroup/memory.stat 2>/dev/null
    echo
    echo "  ${YEL}注意: memory.max 显示 max 不代表真无限制${RST}"
    echo "        可能是宿主外层限制，容器内看不到"
    echo "        判断真实上限请用: bash $0 --memtest"
fi
if command -v swapon >/dev/null; then
    SW=$(swapon --show 2>/dev/null)
    if [ -z "$SW" ]; then
        echo "swap      ${RED}无${RST}  ← OOM 会直接 SIGKILL，无缓冲"
    else
        echo "swap:"; echo "$SW" | sed 's/^/  /'
    fi
fi

sec "磁盘"
df -h / /tmp /dev/shm 2>/dev/null | awk 'NR==1 || !seen[$6]++' | sed 's/^/  /'
echo
echo "挂载类型:"
findmnt -no TARGET,FSTYPE,SIZE /tmp /dev/shm 2>/dev/null | sed 's/^/  /'
echo
echo "  ${YEL}注意: /tmp 不一定是 tmpfs，也不保证持久${RST}"

sec "持久化检查"
echo "查找可能的宿主 bind mount (非 overlay/tmpfs):"
findmnt -no TARGET,SOURCE,FSTYPE 2>/dev/null \
  | awk '$3!="overlay" && $3!="tmpfs" && $3!="proc" && $3!="sysfs" && $3!~/^cgroup/ {print "  "$0}' \
  | head -10
echo
echo "  ${YEL}上面非 / 的挂载点，通常就是容器重启后仍保留的位置${RST}"

sec "GPU"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/  /'
else
    echo "  无 nvidia-smi（通常意味着无 GPU）"
fi

sec "网络"
IP=$(timeout 8 curl -s https://api.ipify.org 2>/dev/null)
echo "出口 IP   ${IP:-获取失败}"
if [ -n "$IP" ]; then
    timeout 8 curl -s "http://ip-api.com/line/$IP?fields=country,regionName,city,isp" 2>/dev/null \
      | paste -sd' ' - | sed 's/^/          /'
fi

sec "已装工具"
for t in gcc g++ make cmake python3 pip3 git curl wget docker cargo node java go rustc tmux proot; do
    if command -v "$t" >/dev/null 2>&1; then
        V=$("$t" --version 2>&1 | head -1 | cut -c1-60)
        printf "  %-8s ${GRN}✔${RST} %s\n" "$t" "$V"
    else
        printf "  %-8s ${RED}✘${RST}\n" "$t"
    fi
done

sec "proot 检测"
if pgrep -f '[p]root' >/dev/null 2>&1; then
    echo "  ${GRN}检测到 proot 进程:${RST}"
    ps -eo pid,cmd 2>/dev/null | grep '[p]root' | head -3 | sed 's/^/    /'
else
    echo "  未检测到 proot 进程"
fi
echo "  可执行文件: $(command -v proot 2>/dev/null || echo '未安装')"

# ── 可选：内存实测 ────────────────────────────────────────────
if [ "${1:-}" = "--memtest" ]; then
    sec "内存上限实测"
    echo "${YEL}警告: 将不断分配内存直到被 OOM 杀掉。当前进程可能一并被杀。${RST}"
    echo "5 秒后开始，Ctrl+C 取消..."
    sleep 5
    python3 - <<'PYEOF'
import sys
CHUNK = 256 * 1024 * 1024
kept = []
try:
    for i in range(1, 200):
        b = bytearray(CHUNK)
        # 逐页触碰，强制真实物理分配
        for off in range(0, len(b), 4096):
            b[off] = 1
        kept.append(b)
        print(f"  {i*256} MB  OK", flush=True)
except MemoryError:
    print(f"  MemoryError，已分配 {len(kept)*256} MB", flush=True)
PYEOF
    RC=$?
    echo
    if [ $RC -eq 137 ]; then
        echo "  ${RED}进程被 SIGKILL (exit=137)${RST} → 触到了真实内存上限"
    else
        echo "  退出码: $RC"
    fi
fi

hr
echo "${GRN}探测完成${RST}"
echo
echo "下一步建议:"
echo "  CapEff=0  → 用 proot 拿 rootfs 能力: bash scripts/bootstrap.sh"
echo "  无 swap   → 长任务务必限制内存，参考 docs/04-资源利用.md"
echo "  找持久卷  → 参考 docs/05-持久化与迁移.md"
