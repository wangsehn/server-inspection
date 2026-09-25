#!/usr/bin/env bash
# ============================================================
# Linux 服务器自动化巡检脚本
# 用法: ./health_check.sh [--outdir 输出目录]
# 退出码: 0 = 巡检全部正常; 1 = 存在告警项（方便 cron 里判断后触发通知）
# 基础思路参考 MickaxL/bash-system-health-check (MIT)，本项目在其基础上重写：
#   1. 新增配置文件 inspection.conf（阈值/服务/巡检目标可配置）
#   2. 新增网络连通性检查（ping / DNS / HTTP 探活）
#   3. 登录日志增加 journalctl 兼容（适配无 /var/log/auth.log 的发行版）
#   4. CPU 使用率改用 /proc/stat 双采样计算，比 top 首屏更准确
#   5. 内存使用率按"可用内存"计算（total-available），更符合实际占用
#   6. 非交互场景（cron）自动关闭颜色，报告文件中不含乱码转义符
# ============================================================
set -u
# 统一 C 语言环境，保证 top/df/sort 等输出格式稳定可解析
export LC_ALL=C

# ---------- 路径与配置 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/inspection.conf"
OUTDIR="${SCRIPT_DIR}/reports"

# 解析命令行参数
while [ $# -gt 0 ]; do
    case "$1" in
        --outdir)
            # 参数校验：--outdir 后必须跟目录参数，避免 set -u 下引用未定义的 $2
            if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
                echo "错误: --outdir 需要一个目录参数" >&2
                echo "用法: $0 --outdir <目录>（或直接运行 $0 使用默认 reports/ 目录）" >&2
                exit 2
            fi
            OUTDIR="$2"; shift 2 ;;
        --outdir=*)
            OUTDIR="${1#--outdir=}"
            if [ -z "$OUTDIR" ]; then
                echo "错误: --outdir= 后不能为空" >&2
                exit 2
            fi
            shift ;;
        -h|--help)
            echo "用法: $0 [--outdir 输出目录]"
            echo "巡检系统/CPU/内存/磁盘/服务/安全/端口/网络，生成 TXT 巡检报告"
            exit 0 ;;
        *)
            echo "未知参数: $1（使用 --help 查看用法）" >&2; exit 2 ;;
    esac
done

# 读取外部配置（不存在则使用下方默认值）
if [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
fi

# 默认值兜底：配置文件缺失或缺少某项时也不会报错
: "${CPU_THRESHOLD:=85}"          # CPU 使用率告警阈值（%）
: "${MEM_THRESHOLD:=85}"          # 内存使用率告警阈值（%）
: "${DISK_THRESHOLD:=85}"         # 磁盘使用率告警阈值（%）
: "${DNS_TARGET:=www.baidu.com}"  # DNS 解析检测目标
: "${HTTP_TIMEOUT:=5}"            # HTTP 探活超时（秒）
: "${FAILED_LOGIN_SINCE:=7 days ago}"  # journalctl 模式下失败登录回溯窗口
# 巡检的核心服务（systemd 单元名）
DEFAULT_SERVICES=(ssh cron rsyslog)
DEFAULT_PING_TARGETS=(223.5.5.5 119.29.29.29)
DEFAULT_HTTP_TARGETS=("http://localhost:8080")
SERVICES=("${SERVICES[@]:-${DEFAULT_SERVICES[@]}}")
PING_TARGETS=("${PING_TARGETS[@]:-${DEFAULT_PING_TARGETS[@]}}")
HTTP_TARGETS=("${HTTP_TARGETS[@]:-${DEFAULT_HTTP_TARGETS[@]}}")

# ---------- 颜色（cron 非终端时自动关闭） ----------
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# 告警临时记录文件：巡检输出经过 tee 管道（子 shell），变量计数会丢失，
# 因此把告警同时落盘，汇总和退出码都从这里统计
# trap 保证脚本被中断（Ctrl+C / kill）时临时文件也会被清理
WARN_LOG="$(mktemp)"
trap 'rm -f "$WARN_LOG" 2>/dev/null' EXIT INT TERM
REPORT_FILE="${OUTDIR}/inspection_$(hostname)_$(date +%Y%m%d_%H%M%S).txt"

# 打印章节标题
section() {
    echo ""
    echo "========================================"
    echo "  $1"
    echo "========================================"
}

# 记录一条告警（终端高亮 + 落盘计数）
warn() {
    printf "%b⚠️  [警告] %s%b\n" "$YELLOW" "$1" "$NC"
    echo "$1" >> "$WARN_LOG"
}

# ============================================================
# 1. 系统信息
# ============================================================
check_os() {
    section "1. 系统信息"
    local pretty="未知"
    [ -r /etc/os-release ] && pretty=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
    echo "操作系统 : ${pretty}"
    echo "内核版本 : $(uname -r)"
    echo "运行时长 : $(uptime -p 2>/dev/null || uptime)"
    echo "当前用户 : $(whoami)"
    echo "服务器时间: $(date '+%Y-%m-%d %H:%M:%S')"
}

# ============================================================
# 2. CPU（/proc/stat 双采样，间隔 1 秒）
# ============================================================
get_cpu_usage() {
    local i1 t1 i2 t2
    read -r i1 t1 < <(awk '/^cpu /{idle=$5+$6; total=0; for(i=2;i<=NF;i++) total+=$i; print idle, total}' /proc/stat)
    sleep 1
    read -r i2 t2 < <(awk '/^cpu /{idle=$5+$6; total=0; for(i=2;i<=NF;i++) total+=$i; print idle, total}' /proc/stat)
    awk -v i1="$i1" -v t1="$t1" -v i2="$i2" -v t2="$t2" \
        'BEGIN{d=t2-t1; if(d<=0){print "0.0"} else {printf "%.1f", 100*(1-(i2-i1)/d)}}'
}

check_cpu() {
    section "2. CPU 检查"
    local model="未知"
    [ -r /proc/cpuinfo ] && model=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//')
    echo "CPU 型号 : ${model}"
    echo "CPU 核数 : $(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)"
    local usage
    usage=$(get_cpu_usage)
    echo "CPU 使用率: ${usage}%"
    echo "系统负载 : $(uptime | sed 's/.*load average/load average/')"
    awk -v u="$usage" -v th="$CPU_THRESHOLD" 'BEGIN{exit !(u>th)}' \
        && warn "CPU 使用率 ${usage}% 已超过阈值 ${CPU_THRESHOLD}%"
}

# ============================================================
# 3. 内存（按"可用内存"计算使用率）
# ============================================================
check_mem() {
    section "3. 内存检查"
    free -h 2>/dev/null || cat /proc/meminfo | head -5
    local total avail pct
    total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    if [ -n "$total" ] && [ -n "$avail" ] && [ "$total" -gt 0 ]; then
        pct=$(awk -v t="$total" -v a="$avail" 'BEGIN{printf "%.1f", (t-a)/t*100}')
        echo "内存使用率: ${pct}%（按可用内存计算）"
        awk -v u="$pct" -v th="$MEM_THRESHOLD" 'BEGIN{exit !(u>th)}' \
            && warn "内存使用率 ${pct}% 已超过阈值 ${MEM_THRESHOLD}%"
    fi
    local swap_total swap_free
    swap_total=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
    swap_free=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
    if [ -n "$swap_total" ] && [ "$swap_total" -gt 0 ]; then
        echo "Swap 使用 : $(( (swap_total - swap_free) * 100 / swap_total ))%"
    else
        echo "Swap 使用 : 未启用"
    fi
}

# ============================================================
# 4. 磁盘（遍历真实文件系统分区）
# ============================================================
check_disk() {
    section "4. 磁盘检查"
    # 排除内存盘/容器只读层等虚拟文件系统，-P 保证输出格式可解析
    df -h -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | grep -vE '^Filesystem.*loop'
    echo ""
    # 逐分区检查使用率（比原版只检查 / 更全面）
    df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1{print $6, $5}' | while read -r mount use; do
        local pct=${use%\%}
        if awk -v u="$pct" -v th="$DISK_THRESHOLD" 'BEGIN{exit !(u>th)}'; then
            warn "挂载点 ${mount} 使用率 ${use} 已超过阈值 ${DISK_THRESHOLD}%"
        fi
    done
    echo "（检查阈值: 使用率 > ${DISK_THRESHOLD}% 告警）"
}

# ============================================================
# 5. 核心服务状态（systemd 优先，兼容 SysV；未安装的服务跳过）
# ============================================================
svc_installed() {
    if [ -d /run/systemd/system ]; then
        systemctl list-unit-files "${1}.service" --no-legend 2>/dev/null | grep -q .
    else
        [ -x "/etc/init.d/${1}" ] || command -v "$1" >/dev/null 2>&1
    fi
}

svc_status() {
    if [ -d /run/systemd/system ]; then
        systemctl is-active "$1" 2>/dev/null
    else
        service "$1" status >/dev/null 2>&1 && echo active || echo inactive
    fi
}

check_services() {
    section "5. 核心服务状态"
    for svc in "${SERVICES[@]}"; do
        if ! svc_installed "$svc"; then
            printf "➖ %-12s : 未安装，跳过\n" "$svc"
            continue
        fi
        if [ "$(svc_status "$svc")" = "active" ]; then
            printf "%b✅ %-12s : 运行中%b\n" "$GREEN" "$svc" "$NC"
        else
            printf "%b❌ %-12s : 未运行%b\n" "$RED" "$svc" "$NC"
            warn "核心服务 ${svc} 未运行"
        fi
    done
}

# ============================================================
# 6. 安全检查：最近登录 + 失败登录尝试 + 来源 IP 统计
#    登录日志兼容：/var/log/auth.log(Debian系) / /var/log/secure(RHEL系) / journalctl
# ============================================================
get_failed_login_lines() {
    if [ -r /var/log/auth.log ]; then
        grep "Failed password" /var/log/auth.log 2>/dev/null
    elif [ -r /var/log/secure ]; then
        grep "Failed password" /var/log/secure 2>/dev/null
    elif command -v journalctl >/dev/null 2>&1; then
        # 无传统登录日志的发行版走 systemd 日志（需要权限，普通用户可能读不到）
        journalctl -q --since "${FAILED_LOGIN_SINCE}" 2>/dev/null | grep "Failed password"
    fi
    # 没有记录不算错误，返回 0
    return 0
}

check_security() {
    section "6. 安全检查"
    echo "--- 最近登录记录（前 6 条） ---"
    if command -v last >/dev/null 2>&1; then
        last -a -n 6 2>/dev/null | head -6
    else
        echo "last 命令不可用"
    fi
    echo ""
    echo "--- 失败登录尝试（最近 10 条） ---"
    local failed_lines
    failed_lines=$(get_failed_login_lines | tail -10)
    if [ -n "$failed_lines" ]; then
        echo "$failed_lines"
    else
        echo "无失败登录记录（或当前用户无权限读取登录日志）"
    fi
    echo ""
    echo "--- 失败登录来源 IP TOP5 ---"
    local top_ips
    top_ips=$(get_failed_login_lines | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort | uniq -c | sort -rn | head -5)
    if [ -n "$top_ips" ]; then
        echo "$top_ips"
    else
        echo "无数据"
    fi
}

# ============================================================
# 7. 网络检查：监听端口 + ping + DNS + HTTP 探活
# ============================================================
check_network() {
    section "7. 网络与连通性检查"

    echo "--- 本机监听端口 ---"
    if command -v ss >/dev/null 2>&1; then
        ss -tuln 2>/dev/null | grep LISTEN || echo "（无监听端口）"
    else
        netstat -tuln 2>/dev/null | grep LISTEN || echo "（ss/netstat 均不可用）"
    fi

    echo ""
    echo "--- 外网连通性（ping） ---"
    for ip in "${PING_TARGETS[@]}"; do
        if ping -c 3 -W 2 "$ip" >/dev/null 2>&1; then
            printf "%b✅ %-16s : 可达%b\n" "$GREEN" "$ip" "$NC"
        else
            printf "%b❌ %-16s : 不可达%b\n" "$RED" "$ip" "$NC"
            warn "ping 目标 ${ip} 不可达"
        fi
    done

    echo ""
    echo "--- DNS 解析 ---"
    if command -v getent >/dev/null 2>&1 && getent hosts "$DNS_TARGET" >/dev/null 2>&1; then
        echo "✅ ${DNS_TARGET} 解析正常: $(getent hosts "$DNS_TARGET" | awk '{print $1}' | head -1)"
    elif command -v nslookup >/dev/null 2>&1 && nslookup "$DNS_TARGET" >/dev/null 2>&1; then
        echo "✅ ${DNS_TARGET} 解析正常（nslookup）"
    else
        echo "❌ ${DNS_TARGET} 解析失败"
        warn "DNS 解析 ${DNS_TARGET} 失败"
    fi

    echo ""
    echo "--- 业务 HTTP 探活 ---"
    if command -v curl >/dev/null 2>&1; then
        for url in "${HTTP_TARGETS[@]}"; do
            local code
            code=$(curl -sS -o /dev/null -m "$HTTP_TIMEOUT" -w '%{http_code}' "$url" 2>/dev/null)
            if [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 400 ] 2>/dev/null; then
                printf "%b✅ %-30s : HTTP %s%b\n" "$GREEN" "$url" "$code" "$NC"
            else
                printf "%b❌ %-30s : HTTP %s%b\n" "$RED" "$url" "${code:-无响应}" "$NC"
                warn "HTTP 探活失败: ${url}（状态码 ${code:-无响应}）"
            fi
        done
    else
        echo "curl 不可用，跳过 HTTP 探活"
    fi
}

# ============================================================
# 8. 汇总
# ============================================================
check_summary() {
    section "8. 巡检结论"
    WARN_COUNT=$(wc -l < "$WARN_LOG" 2>/dev/null || echo 0)
    if [ "$WARN_COUNT" -eq 0 ]; then
        printf "%b✅ 巡检完成：全部检查项正常%b\n" "$GREEN" "$NC"
    else
        printf "%b⚠️  巡检完成：共发现 %d 项异常，详见上方告警条目%b\n" "$YELLOW" "$WARN_COUNT" "$NC"
    fi
}

# ---------- 主流程 ----------
main() {
    mkdir -p "$OUTDIR"
    {
        echo "========================================"
        echo "  LINUX 服务器巡检报告"
        echo "  主机名称 : $(hostname)"
        echo "  巡检时间 : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  执行用户 : $(whoami)"
        echo "========================================"

        check_os
        check_cpu
        check_mem
        check_disk
        check_services
        check_security
        check_network
        check_summary

        echo ""
        echo "========================================"
        echo "  报告文件: $REPORT_FILE"
        echo "========================================"
    } | tee "$REPORT_FILE"

    # 交互模式下彩色码会写入报告文件，统一清洗掉，保证报告可读
    if [ -t 1 ] && command -v sed >/dev/null 2>&1; then
        sed -i -r 's/\x1B\[[0-9;]*[mK]//g' "$REPORT_FILE" 2>/dev/null
    fi

    # 有告警时返回 1，便于 cron / 监控系统判断是否需要通知
    WARN_COUNT=$(wc -l < "$WARN_LOG" 2>/dev/null || echo 0)
    rm -f "$WARN_LOG"
    [ "$WARN_COUNT" -eq 0 ] && exit 0 || exit 1
}

main "$@"
