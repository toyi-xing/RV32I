#!/usr/bin/env bash
set -euo pipefail

# 一键回归：编译所有 .mem → 构建仿真 → 逐个运行所有测试。
# 每个测试都打印 PASS/FAIL，最后汇总。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SIM="${REPO_ROOT}/obj_dir/Vtb_core_single_cycle"

TESTS=(
    0001_smoke
    0101_branch
    0102_alu_imm
    0103_alu_reg
    0104_load_store
    0105_jump
    0106_u_type
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
verilator -sv --binary --timing --top-module tb_core_single_cycle \
    rtl/common/core_pkg.sv \
    rtl/core/alu.sv \
    rtl/core/branch_unit.sv \
    rtl/core/decoder.sv \
    rtl/core/imm_gen.sv \
    rtl/core/regfile.sv \
    rtl/core/pc_reg.sv \
    rtl/core/if_stage.sv \
    rtl/core/id_stage.sv \
    rtl/core/ex_stage.sv \
    rtl/core/mem_stage.sv \
    rtl/core/wb_stage.sv \
    rtl/core/core_single_cycle.sv \
    rtl/mem/simple_rom.sv \
    rtl/mem/simple_ram.sv \
    tb/sv/tb_core_single_cycle.sv

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
