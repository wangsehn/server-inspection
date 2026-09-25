#!/usr/bin/env bash
# ============================================================
# health_check.sh 自动化测试脚本
# 用法: bash tests/run_tests.sh
# 覆盖: 语法 / 正常参数 / 错误参数 / 配置缺失 / 报告生成 /
#       退出码一致性 / ANSI 乱码 / 临时文件清理(正常+SIGTERM中断) /
#       零告警场景 / 故障注入场景（必现告警）
# 说明: T10/T11 通过临时配置夹具构造确定性场景，
#       不依赖当前机器的资源使用率等不确定因素
# ============================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/health_check.sh"
TMP="$(mktemp -d)"
PASS=0
FAIL=0
SKIP=0

ok()   { PASS=$((PASS + 1)); echo "✅ $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "❌ $1"; }
skip() { SKIP=$((SKIP + 1)); echo "⏭️  $1"; }

# 统计报告中的告警条数
# 注意: grep -c 在无匹配时本身会输出 0（退出码为 1），
#       不能写成 "grep -c ... || echo 0"，否则零告警时会得到两个 0；
#       这里只对"命令无输出"（文件不存在等）兜底为 0
count_warns() {
    local n
    n=$(grep -c '\[警告\]' "$1" 2>/dev/null)
    printf '%s' "${n:-0}"
}

# ---------- T1 语法检查 ----------
if bash -n "$SCRIPT" 2>"$TMP/syntax.err"; then
    ok "T1 Bash 语法检查通过"
else
    bad "T1 语法错误: $(cat "$TMP/syntax.err")"
fi

# ---------- T2 --help 正常参数 ----------
"$SCRIPT" --help >"$TMP/help.out" 2>&1
if [ $? -eq 0 ] && grep -q "用法" "$TMP/help.out"; then
    ok "T2 --help 返回 0 并输出用法"
else
    bad "T2 --help 行为异常"
fi

# ---------- T3 未知参数 ----------
"$SCRIPT" --no-such-option >/dev/null 2>&1
if [ $? -eq 2 ]; then
    ok "T3 未知参数返回 2"
else
    bad "T3 未知参数退出码不是 2"
fi

# ---------- T4 --outdir 缺少目录参数（回归：set -u 未定义变量） ----------
out=$("$SCRIPT" --outdir 2>&1)
rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "需要一个目录参数"; then
    ok "T4 --outdir 缺参数时明确报错并返回 2"
else
    bad "T4 --outdir 缺参数行为异常 (rc=$rc, out=$out)"
fi

# ---------- T5 --outdir= 空值 ----------
"$SCRIPT" --outdir= >/dev/null 2>&1
if [ $? -eq 2 ]; then
    ok "T5 --outdir= 空值返回 2"
else
    bad "T5 --outdir= 空值未拒绝"
fi

# ---------- T6 配置文件缺失时可用默认值运行 ----------
cp "$SCRIPT" "$TMP/health_check.sh"
chmod +x "$TMP/health_check.sh"
( cd "$TMP" && ./health_check.sh --outdir "$TMP/out" >/dev/null 2>&1 )
rc=$?
if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
    ok "T6 无配置文件可正常运行 (rc=$rc)"
else
    bad "T6 无配置文件运行失败 (rc=$rc)"
fi

# ---------- T7 报告生成 + 退出码与告警数一致 ----------
rep=$(ls "$TMP/out"/inspection_*.txt 2>/dev/null | head -1)
if [ -z "$rep" ]; then
    bad "T7 巡检报告未生成"
else
    warns=$(count_warns "$rep")
    if { [ "$warns" -eq 0 ] && [ "$rc" -eq 0 ]; } || { [ "$warns" -gt 0 ] && [ "$rc" -eq 1 ]; }; then
        ok "T7 退出码与告警数一致 (警告 $warns 项, rc=$rc)"
    else
        bad "T7 退出码与告警数不一致 (警告 $warns 项, rc=$rc)"
    fi
fi

# ---------- T8 报告文件不含 ANSI 转义乱码 ----------
if [ -n "${rep:-}" ] && ! grep -qP '\x1b\[' "$rep" 2>/dev/null; then
    ok "T8 报告文件无 ANSI 转义乱码"
else
    bad "T8 报告文件含 ANSI 转义符"
fi

# ---------- T9 临时文件清理（真实验证） ----------
# 原理: mktemp 遵循 TMPDIR 环境变量。把 TMPDIR 指向一个专用空目录运行脚本，
#       正常退出后该目录应为空——否则说明 trap 'rm -f "$WARN_LOG"' 未生效
mkdir -p "$TMP/t9tmp" "$TMP/t9out"
TMPDIR="$TMP/t9tmp" "$SCRIPT" --outdir "$TMP/t9out" >/dev/null 2>&1
if [ -z "$(ls -A "$TMP/t9tmp" 2>/dev/null)" ]; then
    ok "T9 正常退出后告警临时文件已清理（专用 TMPDIR 无残留）"
else
    bad "T9 临时文件残留: $(ls -A "$TMP/t9tmp")"
fi

# ---------- T10 零告警场景（确定性夹具） ----------
# 阈值调到 100%（永不触发）+ ping 回环地址 + DNS 解析 localhost（hosts 必成功）
# + 服务名不存在（跳过不告警）+ python3 本地 HTTP 服务（探活必 200）
mkdir -p "$TMP/zero" "$TMP/zero-out" "$TMP/zero-tmp"
cp "$SCRIPT" "$TMP/zero/health_check.sh"
chmod +x "$TMP/zero/health_check.sh"
cat > "$TMP/zero/inspection.conf" <<'EOF'
# 测试夹具: 所有检查项设计为必然通过
CPU_THRESHOLD=100
MEM_THRESHOLD=100
DISK_THRESHOLD=100
DNS_TARGET=localhost
SERVICES=(svc-not-installed-for-test)
PING_TARGETS=(127.0.0.1)
HTTP_TARGETS=("http://127.0.0.1:59998")
EOF
if command -v python3 >/dev/null 2>&1; then
    python3 -m http.server 59998 --bind 127.0.0.1 >/dev/null 2>&1 &
    httpd_pid=$!
    ready=0
    for _ in $(seq 1 20); do
        if curl -s -o /dev/null -m 1 http://127.0.0.1:59998/; then ready=1; break; fi
        sleep 0.2
    done
    if [ "$ready" -eq 1 ]; then
        ( cd "$TMP/zero" && TMPDIR="$TMP/zero-tmp" ./health_check.sh --outdir "$TMP/zero-out" >/dev/null 2>&1 )
        rc10=$?
        kill "$httpd_pid" 2>/dev/null; wait "$httpd_pid" 2>/dev/null
        zero_rep=$(ls "$TMP/zero-out"/inspection_*.txt 2>/dev/null | head -1)
        zw=$(count_warns "$zero_rep")
        if [ "$rc10" -eq 0 ] && [ "$zw" -eq 0 ] \
           && grep -q "全部检查项正常" "$zero_rep" 2>/dev/null \
           && [ -z "$(ls -A "$TMP/zero-tmp" 2>/dev/null)" ]; then
            ok "T10 零告警场景: rc=0、无告警、结论为全部正常、无临时文件残留"
        else
            bad "T10 零告警场景异常 (rc=$rc10, 警告=$zw, 报告=${zero_rep:-未生成})"
        fi
    else
        kill "$httpd_pid" 2>/dev/null; wait "$httpd_pid" 2>/dev/null
        bad "T10 本地探活服务启动失败（检查 59998 端口是否被占用）"
    fi
else
    skip "T10 零告警场景（需要 python3 起本地 HTTP 服务，当前环境未安装）"
fi

# ---------- T11 故障注入场景（必现告警） ----------
# 三个必现故障全部构造在"本地校验/连接层"，不依赖网络环境:
#   DNS / ping 用带空标签的非法主机名 invalid..hostname——
#     在本地名字校验层即失败，任何解析器（含代理的 fake-IP DNS）都会拒绝，
#     而保留网段/保留域名在开启代理 TUN 的机器上会被代答，不可靠
#   HTTP 探活指向必然关闭的本地端口（连接拒绝，状态码 000）
# 预期: 至少 3 项告警、退出码 1、汇总条数与实际告警数一致（回归验证落盘计数）
mkdir -p "$TMP/fault" "$TMP/fault-out" "$TMP/fault-tmp"
cp "$SCRIPT" "$TMP/fault/health_check.sh"
chmod +x "$TMP/fault/health_check.sh"
cat > "$TMP/fault/inspection.conf" <<'EOF'
# 测试夹具: 注入三个必现故障
CPU_THRESHOLD=100
MEM_THRESHOLD=100
DISK_THRESHOLD=100
DNS_TARGET=invalid..hostname
SERVICES=(svc-not-installed-for-test)
PING_TARGETS=(invalid..hostname)
HTTP_TARGETS=("http://127.0.0.1:59997")
EOF
( cd "$TMP/fault" && TMPDIR="$TMP/fault-tmp" ./health_check.sh --outdir "$TMP/fault-out" >/dev/null 2>&1 )
rc11=$?
fault_rep=$(ls "$TMP/fault-out"/inspection_*.txt 2>/dev/null | head -1)
fw=$(count_warns "$fault_rep")
summary_n=$(grep -oE '共发现 [0-9]+ 项异常' "$fault_rep" 2>/dev/null | grep -oE '[0-9]+' | head -1)
summary_n=${summary_n:-0}
if [ "$rc11" -eq 1 ] && [ "$fw" -ge 3 ] && [ "$summary_n" -eq "$fw" ] \
   && [ -z "$(ls -A "$TMP/fault-tmp" 2>/dev/null)" ]; then
    ok "T11 故障注入场景: rc=1、${fw} 项告警、汇总计数一致、无临时文件残留"
else
    bad "T11 故障注入场景异常 (rc=$rc11, 警告=$fw, 汇总=$summary_n, 报告=${fault_rep:-未生成})"
fi

# ---------- T12 临时文件清理（SIGTERM 中断路径） ----------
# 巡检全程数秒，1.5 秒时必在运行中；此时发 SIGTERM，
# trap 'rm -f "$WARN_LOG"' INT/TERM 应清理专用 TMPDIR 中的临时文件
mkdir -p "$TMP/t12tmp" "$TMP/t12out"
TMPDIR="$TMP/t12tmp" "$SCRIPT" --outdir "$TMP/t12out" >/dev/null 2>&1 &
t12pid=$!
sleep 1.5
if kill -0 "$t12pid" 2>/dev/null; then
    kill -TERM "$t12pid" 2>/dev/null
    wait "$t12pid" 2>/dev/null
    if [ -z "$(ls -A "$TMP/t12tmp" 2>/dev/null)" ]; then
        ok "T12 SIGTERM 中断后告警临时文件已清理"
    else
        bad "T12 SIGTERM 中断后临时文件残留: $(ls -A "$TMP/t12tmp")"
    fi
else
    bad "T12 脚本提前退出，未测到中断路径"
fi

# ---------- 清理与汇总 ----------
rm -rf "$TMP"
echo ""
echo "========================================"
echo "  测试结果: 通过 $PASS 项 / 失败 $FAIL 项 / 跳过 $SKIP 项"
echo "========================================"
[ "$FAIL" -eq 0 ]
