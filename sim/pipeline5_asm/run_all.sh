#!/usr/bin/env bash
set -euo pipefail

# 一键回归：编译所有 .mem → 构建仿真 → 逐个运行所有汇编测试。
# 当前列表覆盖基础 RV32I 指令集测试和流水线 hazard 测试。
# 每个测试都打印 PASS/FAIL，最后汇总。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SIM="${REPO_ROOT}/obj_dir/Vtb_core_pipeline5"

TESTS=(
    # 基础 RV32I 指令集测试（验证流水线 ISA 正确性）
    0001_smoke
    0101_branch
    0102_alu_imm
    0103_alu_reg
    0104_load_store
    0105_jump
    0106_u_type

    # 流水线专用（验证 data hazard / control hazard）
    0301_pipeline5_nofwd_noredirect
    0302_pipeline5_fwd_noredirect
    0303_pipeline5_fwd_redirect
)

PASS=0
FAIL=0
FAILED=""

# ------------------------------------------------------------------
# Step 1: 编译所有 .mem
# ------------------------------------------------------------------
echo ">>> [1/3] Building all .mem files..."
for t in "${TESTS[@]}"; do
    "${SCRIPT_DIR}/05_build_mem.sh" "$t"
done

# ------------------------------------------------------------------
# Step 2: 构建仿真二进制（只需一次）
# ------------------------------------------------------------------
echo ""
echo ">>> [2/3] Building simulation binary..."
cd "${REPO_ROOT}"
RTL_FILES=(
    rtl/common/*.sv
    rtl/core/*.sv
    rtl/mem/*.sv
)

verilator -sv --binary --timing --top-module tb_core_pipeline5 \
    "${RTL_FILES[@]}" \
    tb/sv/tb_core_pipeline5.sv

# ------------------------------------------------------------------
# Step 3: 逐个运行测试
# ------------------------------------------------------------------
echo ""
echo ">>> [3/3] Running all tests..."

for t in "${TESTS[@]}"; do
    echo ""
    echo "=========================================="
    echo "  RUN: ${t}"
    echo "=========================================="
    if "${SIM}" "+imem=${REPO_ROOT}/build/${t}.mem"; then
        echo "  >>> ${t}: PASS"
        PASS=$((PASS + 1))
    else
        echo "  >>> ${t}: FAIL"
        FAIL=$((FAIL + 1))
        FAILED="${FAILED} ${t}"
    fi
done

# ------------------------------------------------------------------
# 汇总
# ------------------------------------------------------------------
echo ""
echo "=========================================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "=========================================="
if [ "${FAIL}" -ne 0 ]; then
    echo "Failed:${FAILED}"
    exit 1
fi
