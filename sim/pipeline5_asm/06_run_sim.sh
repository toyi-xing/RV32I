#!/usr/bin/env bash
set -euo pipefail

# 构建五级流水 smoke testbench，并用指定 .mem 镜像运行仿真。
# 用法：
#   sim/pipeline5_asm/06_run_sim.sh [test_name]
# 示例：
#   sim/pipeline5_asm/06_run_sim.sh 0301

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/sim/common/resolve_test_name.sh"

TEST_NAME="$(resolve_test_name "${REPO_ROOT}/sw/asm" "S" "${1:-}" "0301_pipeline5_nofwd_noredirect")"
MEM_FILE="${REPO_ROOT}/build/${TEST_NAME}.mem"

if [[ ! -f "${MEM_FILE}" ]]; then
    echo "ERROR: memory image not found: ${MEM_FILE}" >&2
    echo "Run: sim/pipeline5_asm/05_build_mem.sh ${TEST_NAME}" >&2
    exit 1
fi

cd "${REPO_ROOT}"

RTL_FILES=(
    rtl/common/*.sv
    rtl/core/*.sv
    rtl/mem/*.sv
)

verilator -sv --binary --timing --top-module tb_core_pipeline5 \
    "${RTL_FILES[@]}" \
    tb/sv/tb_core_pipeline5.sv

"${REPO_ROOT}/obj_dir/Vtb_core_pipeline5" "+imem=${MEM_FILE}"
