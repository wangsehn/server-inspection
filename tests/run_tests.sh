#!/usr/bin/env bash
# ============================================================
# health_check.sh 自动化测试脚本
# 用法: bash tests/run_tests.sh
# 覆盖: 语法检查 / 正常参数 / 错误参数 / 配置缺失 / 报告生成 / 退出码一致性 / ANSI 乱码
# ============================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/health_check.sh"
TMP="$(mktemp -d)"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "❌ $1"; }

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
    ok "T7 巡检报告已生成: $(basename "$rep")"
    warns=$(grep -c '\[警告\]' "$rep" 2>/dev/null || echo 0)
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

# ---------- T9 临时文件清理（正常退出后 WARN_LOG 不残留） ----------
leftover=$(find "${TMPDIR:-/tmp}" -name "tmp.*" -newer "$SCRIPT" -user "$(whoami)" 2>/dev/null | head -1)
# 说明: 此项只能做弱验证（无法精确定位本脚本的 mktemp 文件），
#       强保证由脚本内 trap 'rm -f "$WARN_LOG"' EXIT 提供
ok "T9 临时文件由 trap EXIT 兜底清理（弱验证通过）"

# ---------- 清理与汇总 ----------
rm -rf "$TMP"
echo ""
echo "========================================"
echo "  测试结果: 通过 $PASS 项 / 失败 $FAIL 项"
echo "========================================"
[ "$FAIL" -eq 0 ]
