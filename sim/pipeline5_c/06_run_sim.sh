#!/usr/bin/env bash
set -euo pipefail

# 构建五级流水 testbench，并用指定 C 测试的 IMEM/DMEM 镜像运行仿真。
# 用法：
#   sim/pipeline5_c/06_run_sim.sh [test_name]
# 示例：
#   sim/pipeline5_c/06_run_sim.sh 0201

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/sim/common/resolve_test_name.sh"

TEST_NAME="$(resolve_test_name "${REPO_ROOT}/sw/c" "c" "${1:-}" "0201_c_smoke")"
BUILD_DIR="${REPO_ROOT}/build/pipeline5_c"
IMEM_FILE="${BUILD_DIR}/${TEST_NAME}_imem.mem"
DMEM_FILE="${BUILD_DIR}/${TEST_NAME}_dmem.mem"

if [[ ! -f "${IMEM_FILE}" ]]; then
    echo "ERROR: IMEM image not found: ${IMEM_FILE}" >&2
    echo "Run: sim/pipeline5_c/05_build_mem.sh ${TEST_NAME}" >&2
    exit 1
fi

if [[ ! -f "${DMEM_FILE}" ]]; then
    echo "ERROR: DMEM image not found: ${DMEM_FILE}" >&2
    echo "Run: sim/pipeline5_c/05_build_mem.sh ${TEST_NAME}" >&2
    exit 1
fi

cd "${REPO_ROOT}"

verilator -sv --binary --timing --top-module tb_core_pipeline5 \
    rtl/common/core_pkg.sv \
    rtl/common/pipeline_pkg.sv \
    rtl/core/alu.sv \
    rtl/core/branch_unit.sv \
    rtl/core/decoder.sv \
    rtl/core/imm_gen.sv \
    rtl/core/regfile.sv \
    rtl/core/pc_reg.sv \
    rtl/core/hazard_unit.sv \
    rtl/core/forwarding_unit.sv \
    rtl/core/if_stage.sv \
    rtl/core/id_stage.sv \
    rtl/core/ex_stage.sv \
    rtl/core/mem_stage.sv \
    rtl/core/wb_stage.sv \
    rtl/core/pipe_reg.sv \
    rtl/core/core_pipeline5.sv \
    rtl/mem/simple_rom.sv \
    rtl/mem/simple_ram.sv \
    tb/sv/tb_core_pipeline5.sv

"${REPO_ROOT}/obj_dir/Vtb_core_pipeline5" "+imem=${IMEM_FILE}" "+dmem=${DMEM_FILE}"
