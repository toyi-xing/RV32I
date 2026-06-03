#!/usr/bin/env bash
set -euo pipefail

# 构建单周期 smoke testbench，并用指定 .mem 镜像运行仿真。
# 用法：
#   sim/single_cycle_asm/06_run_sim.sh [test_name]
# 示例：
#   sim/single_cycle_asm/06_run_sim.sh smoke

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEST_NAME="${1:-smoke}"
MEM_FILE="${REPO_ROOT}/build/${TEST_NAME}.mem"

if [[ ! -f "${MEM_FILE}" ]]; then
    echo "ERROR: memory image not found: ${MEM_FILE}" >&2
    echo "Run: sim/single_cycle_asm/05_build_mem.sh ${TEST_NAME}" >&2
    exit 1
fi

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

"${REPO_ROOT}/obj_dir/Vtb_core_single_cycle" "+imem=${MEM_FILE}"
