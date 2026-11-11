#!/bin/bash
# check-capabilities.sh — 判断沙盒能力，给出建议
# 这是最容易搞错的一步：uid=0 不等于有 root 权限
#
# 判断原则：以实测为准，不只看 CapEff。
# 有些环境 CapEff 显示有对应位，但被 seccomp/AppArmor/外层策略拦截。

set -u
G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[34m'; N=$'\033[0m'

echo "${B}════════ 沙盒能力诊断 ════════${N}"
echo

# 1. uid
UID_NOW=$(id -u)
echo "uid          = $UID_NOW"
if [ "$UID_NOW" = "0" ]; then
    echo "               ${Y}⚠ uid=0 不代表有权限（继续看 CapEff 与实测）${N}"
fi

# 2. capabilities
NEED_PROOT=1
if [ -r /proc/self/status ]; then
    CAPEFF=$(awk '/^CapEff:/{print $2}' /proc/self/status)
    CAPBND=$(awk '/^CapBnd:/{print $2}' /proc/self/status)
    echo "CapEff       = $CAPEFF"
    echo "CapBnd       = $CAPBND"

    if [ "$CAPEFF" = "0000000000000000" ]; then
        echo
        echo "${R}✘ 无任何生效的 capability${N}"
        echo
        echo "  这意味着以下操作全部失败:"
        echo "    • chroot        (需要 CAP_SYS_CHROOT)"
        echo "    • mount         (需要 CAP_SYS_ADMIN)"
        echo "    • sysctl -w     (需要写 /proc/sys)"
        echo "    • iptables      (需要 CAP_NET_ADMIN)"
        echo "    • docker        (需要完整特权)"
        echo
        echo "${G}  → 解决方案: 用 proot${N}"
        echo "     proot --rootfs=DIR -0 -b /proc -b /dev -b /sys /bin/bash"
        echo "     详见 docs/03-proot详解.md"
        NEED_PROOT=1
    else
        echo
        echo "${G}✔ 有 capability${N}（十六进制位掩码）"
        has_cap() { [ $(( 16#$CAPEFF & (1 << $1) )) -ne 0 ]; }
        has_cap 0  && echo "    CAP_CHOWN        ✔"
        has_cap 6  && echo "    CAP_SETUID       ✔"
        has_cap 7  && echo "    CAP_SETGID       ✔"
        has_cap 18 && echo "    CAP_SYS_CHROOT   ✔ → chroot 权限具备"
        has_cap 21 && echo "    CAP_SYS_ADMIN    ✔ → mount 权限具备"
        has_cap 12 && echo "    CAP_NET_ADMIN    ✔ → iptables 权限具备"
        NEED_PROOT=0
    fi
else
    echo "${Y}无法读取 /proc/self/status${N}"
fi

# 3. seccomp
echo
if grep -q Seccomp /proc/self/status; then
    SC=$(awk '/^Seccomp:/{print $2}' /proc/self/status)
    echo "Seccomp      = $SC $([ "$SC" = "0" ] && echo '（未启用）' || echo '（已启用，部分 syscall 被拦）')"
fi

# 4. 实测关键操作
echo
echo "${B}──── 实测 ────${N}"

# chroot：搭一个最小可用 rootfs 来测，避免"目录不合格"造成的假阴性
CHROOT_SKIP=0
CHROOT_DIR=/tmp/.captest-root
rm -rf "$CHROOT_DIR" 2>/dev/null
if mkdir -p "$CHROOT_DIR/bin" "$CHROOT_DIR/lib" "$CHROOT_DIR/lib64" 2>/dev/null && [ -x /bin/sh ]; then
    cp -f /bin/sh "$CHROOT_DIR/bin/sh" 2>/dev/null
    for l in $(ldd /bin/sh 2>/dev/null | awk '/=> \//{print $3}'); do
        cp -f "$l" "$CHROOT_DIR/lib/" 2>/dev/null
    done
    for l in /lib64/ld-linux-x86-64.so.2 /lib/ld-linux-aarch64.so.1; do
        [ -f "$l" ] && cp -f "$l" "$CHROOT_DIR/lib64/" 2>/dev/null
    done
fi

if ! command -v chroot >/dev/null 2>&1; then
    printf '  %-16s %s? 未安装 chroot 命令%s\n' "chroot" "$Y" "$N"
    CHROOT_OK=0; CHROOT_SKIP=1
else
    ERR=$(chroot "$CHROOT_DIR" /bin/sh -c 'echo ok' 2>&1)
    if [ "$ERR" = "ok" ]; then
        printf '  %-16s %s✔ 可用%s\n' "chroot" "$G" "$N"; CHROOT_OK=1
    else
        printf '  %-16s %s✘ 不可用%s\n' "chroot" "$R" "$N"; CHROOT_OK=0
        echo "                   ${Y}原因: ${ERR:-unknown}${N}"
    fi
fi
rm -rf "$CHROOT_DIR" 2>/dev/null

# mount
mkdir -p /tmp/.captest 2>/dev/null
MOUNT_ERR=$(mount -t tmpfs none /tmp/.captest 2>&1)
if [ -z "$MOUNT_ERR" ]; then
    printf '  %-16s %s✔ 可用%s\n' "mount" "$G" "$N"; MOUNT_OK=1
    umount /tmp/.captest 2>/dev/null
else
    printf '  %-16s %s✘ 不可用%s\n' "mount" "$R" "$N"; MOUNT_OK=0
    echo "                   ${Y}原因: $MOUNT_ERR${N}"
fi
rmdir /tmp/.captest 2>/dev/null

# unshare（用户命名空间）
if unshare --user --map-root-user true >/dev/null 2>&1; then
    printf '  %-16s %s✔ 可用%s\n' "unshare" "$G" "$N"
else
    printf '  %-16s %s✘ 不可用%s\n' "unshare" "$R" "$N"
fi

# 5. 结论（以实测为准）
echo
echo "${B}──── 结论 ────${N}"
REAL_OK=0
if [ "${CHROOT_SKIP:-0}" = "1" ]; then
    [ "${MOUNT_OK:-0}" = "1" ] && REAL_OK=1
else
    [ "${CHROOT_OK:-0}" = "1" ] && [ "${MOUNT_OK:-0}" = "1" ] && REAL_OK=1
fi

if [ "$REAL_OK" = "1" ]; then
    cat <<EOF
  ${G}有实际特权${N} —— chroot/mount 实测可用

  可以直接:
    debootstrap --arch=amd64 focal /mnt/rootfs http://archive.ubuntu.com/ubuntu
    chroot /mnt/rootfs /bin/bash

  不需要 proot（但 proot 仍可用于非特权场景）
EOF
else
    cat <<EOF
  ${Y}实际无特权${N}（chroot/mount 至少一项不可用）

  即使 CapEff 显示有对应位，也可能被 seccomp / AppArmor / 外层策略拦截。
  ${Y}判断以实测为准，不要只看 CapEff。${N}

  你可以:
    ✔ 编译任意代码
    ✔ 运行任意本架构二进制
    ✔ 自由访问网络

  你不能:
    ✘ chroot / mount / sysctl / iptables / docker

  推荐路径:
    ${G}bash scripts/bootstrap.sh${N}
    它会装好 proot + 一个完整发行版 rootfs
EOF
fi
echo
