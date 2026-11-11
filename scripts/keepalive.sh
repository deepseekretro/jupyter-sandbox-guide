#!/bin/bash
# keepalive.sh — 长任务保活 + 监控 + 自愈
# 用法:
#   bash keepalive.sh run  --name NAME -- CMD...       启动受监控任务
#   bash keepalive.sh list                             列出所有任务
#   bash keepalive.sh status NAME                      查看状态
#   bash keepalive.sh log NAME                         跟踪日志
#   bash keepalive.sh stop NAME                        停止
#   bash keepalive.sh daemon                           启动自愈守护（检查所有 registered 任务）
#   bash keepalive.sh register --name NAME -- CMD...   登记为需要自愈的任务
#   bash keepalive.sh unregister NAME
#
# 特性:
#   • setsid + nohup，彻底脱离终端
#   • 自动记录 PID / 启动时间 / 退出码
#   • 周期性内存监控（便于发现 OOM 趋势）
#   • daemon 模式可自动拉起挂掉的任务

set -uo pipefail
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'

BASE="${KEEPALIVE_BASE:-/var/run/keepalive}"
[ -w "$(dirname "$BASE")" ] || BASE="${HOME}/.keepalive"
REG="$BASE/registry"
mkdir -p "$BASE/runs" "$REG"

log()  { printf '%s[%s]%s %s\n' "$GRN" "$(date +%T)" "$RST" "$*"; }
warn() { printf '%s[%s] WARN%s %s\n' "$YEL" "$(date +%T)" "$RST" "$*"; }
die()  { printf '%s[%s] FAIL%s %s\n' "$RED" "$(date +%T)" "$RST" "$*" >&2; exit 1; }

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

mem_info() {
    if [ -f /sys/fs/cgroup/memory.stat ]; then
        awk '/^anon /{printf "%.0f", $2/1048576}' /sys/fs/cgroup/memory.stat
    else
        free -m | awk '/^Mem:/{print $3}'
    fi
}

# ── run ───────────────────────────────────────────────────────
cmd_run() {
    local name="" ; local -a argv=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            --)     shift; argv=("$@"); break ;;
            *)      argv+=("$1"); shift ;;
        esac
    done
    [ -n "$name" ] || die "需要 --name"
    [ ${#argv[@]} -gt 0 ] || die "需要命令（-- 之后）"

    local id; id=$(sanitize "$name")
    local dir="$BASE/runs/$id"
    mkdir -p "$dir"
    local logf="$dir/output.log" pidf="$dir/pid" metf="$dir/metrics.log"

    log "启动: $name"
    log "命令: ${argv[*]}"
    log "日志: $logf"

    # setsid 创建新会话 + nohup 忽略 SIGHUP + </dev/null 防止 stdin 阻塞
    setsid nohup "${argv[@]}" > "$logf" 2>&1 < /dev/null &
    local pid=$!
    echo "$pid" > "$pidf"
    date +%s > "$dir/started"
    printf '%s\n' "${argv[*]}" > "$dir/command"

    # 记录内存占用（后台，随任务结束自己退出）
    (
        while kill -0 "$pid" 2>/dev/null; do
            printf '%s %s\n' "$(date +%s)" "$(mem_info)" >> "$metf"
            sleep 30
        done
    ) >/dev/null 2>&1 &

    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        log "✔ 运行中 PID=$pid"
        log "查看: bash $0 status $name"
        log "日志: bash $0 log $name"
    else
        warn "✘ 启动后立刻退出，请查看日志"
        tail -20 "$logf" 2>/dev/null | sed 's/^/  /'
        return 1
    fi
}

# ── register ──────────────────────────────────────────────────
cmd_register() {
    local name="" ; local -a argv=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            --)     shift; argv=("$@"); break ;;
            *)      argv+=("$1"); shift ;;
        esac
    done
    [ -n "$name" ] || die "需要 --name"
    [ ${#argv[@]} -gt 0 ] || die "需要命令"
    local id; id=$(sanitize "$name")
    printf '%s\n' "${argv[*]}" > "$REG/$id"
    log "已登记自愈任务: $name"
    log "命令: ${argv[*]}"
    log "可用 daemon 模式周期检查: bash $0 daemon"
}

cmd_unregister() {
    local id; id=$(sanitize "${1:-}")
    rm -f "$REG/$id"
    log "已取消登记: ${1:-}"
}

# ── list ──────────────────────────────────────────────────────
cmd_list() {
    printf '%-20s %-8s %-10s %-8s %s\n' NAME PID 状态 运行时长 内存/命令
    printf '%.0s─' {1..90}; echo
    local any=0
    for d in "$BASE"/runs/*/; do
        [ -d "$d" ] || continue
        any=1
        local id; id=$(basename "$d")
        local pid; pid=$(cat "$d/pid" 2>/dev/null || echo "-")
        local st="停止"; local col="$RED"
        if [ "$pid" != "-" ] && kill -0 "$pid" 2>/dev/null; then
            st="运行"; col="$GRN"
        fi
        local dur="-"
        if [ -f "$d/started" ]; then
            local s=$(( $(date +%s) - $(cat "$d/started") ))
            dur="$((s/3600))h$((s%3600/60))m"
        fi
        local mem="-"
        [ -f "$d/metrics.log" ] && mem="$(tail -1 "$d/metrics.log" 2>/dev/null | awk '{print $2"MB"}')"
        printf '%-20s %-8s %s%-10s%s %-8s %s\n' "$id" "$pid" "$col" "$st" "$RST" "$dur" "$mem"
    done
    [ $any -eq 1 ] || echo "  （无任务）"
    echo
    if [ -n "$(ls -A "$REG" 2>/dev/null)" ]; then
        echo "已登记自愈任务:"
        for f in "$REG"/*; do
            printf '  %-20s %s\n' "$(basename "$f")" "$(cat "$f")"
        done
    fi
}

# ── status ────────────────────────────────────────────────────
cmd_status() {
    local id; id=$(sanitize "${1:-}")
    local d="$BASE/runs/$id"
    [ -d "$d" ] || die "无此任务: ${1:-}"
    local pid; pid=$(cat "$d/pid" 2>/dev/null || echo "")
    echo "任务      $id"
    echo "PID       ${pid:--}"
    echo "命令      $(cat "$d/command" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "状态      ${GRN}运行中${RST}"
        ps -o pid,etime,%cpu,%mem,rss,stat -p "$pid" 2>/dev/null | sed 's/^/  /'
    else
        echo "状态      ${RED}已停止${RST}"
    fi
    if [ -f "$d/started" ]; then
        local s=$(( $(date +%s) - $(cat "$d/started") ))
        echo "运行时长  $((s/3600))h $((s%3600/60))m $((s%60))s"
    fi
    if [ -f "$d/metrics.log" ]; then
        echo "内存走势  (最近 10 次)"
        tail -10 "$d/metrics.log" | awk '{printf "  %s  %s MB\n", strftime("%H:%M:%S",$1), $2}'
    fi
    echo
    echo "日志尾部:"
    tail -10 "$d/output.log" 2>/dev/null | sed 's/^/  /'
}

cmd_log() {
    local id; id=$(sanitize "${1:-}")
    local f="$BASE/runs/$id/output.log"
    [ -f "$f" ] || die "无日志: $f"
    tail -f "$f"
}

cmd_stop() {
    local id; id=$(sanitize "${1:-}")
    local d="$BASE/runs/$id"
    [ -d "$d" ] || die "无此任务: ${1:-}"
    local pid; pid=$(cat "$d/pid" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "停止 PID=$pid (先 TERM，5 秒后 KILL)"
        kill -TERM "$pid" 2>/dev/null
        for _ in $(seq 5); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
        kill -0 "$pid" 2>/dev/null && { warn "强制 KILL"; kill -9 "$pid" 2>/dev/null; }
        log "已停止"
    else
        warn "任务未在运行"
    fi
}

# ── daemon（自愈）─────────────────────────────────────────────
cmd_daemon() {
    local interval="${1:-120}"
    log "自愈守护启动（间隔 ${interval}s）"
    log "登记任务目录: $REG"
    while :; do
        for f in "$REG"/*; do
            [ -f "$f" ] || continue
            local id; id=$(basename "$f")
            local cmdline; cmdline=$(cat "$f")
            local pidf="$BASE/runs/$id/pid"
            local pid; pid=$(cat "$pidf" 2>/dev/null || echo "")
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                continue   # 还活着
            fi
            warn "[$(date +%T)] $id 未运行，拉起中..."
            # shellcheck disable=SC2086
            cmd_run --name "$id" -- $cmdline >/dev/null 2>&1 || \
                warn "[$(date +%T)] $id 拉起失败"
        done
        sleep "$interval"
    done
}

# ── 分发 ──────────────────────────────────────────────────────
ACTION="${1:-help}"; shift || true
case "$ACTION" in
    run)        cmd_run "$@" ;;
    register)   cmd_register "$@" ;;
    unregister) cmd_unregister "$@" ;;
    list)       cmd_list ;;
    status)     cmd_status "$@" ;;
    log)        cmd_log "$@" ;;
    stop)       cmd_stop "$@" ;;
    daemon)     cmd_daemon "$@" ;;
    *)
        sed -n '2,20p' "$0" | sed 's/^# \?//'
        ;;
esac
