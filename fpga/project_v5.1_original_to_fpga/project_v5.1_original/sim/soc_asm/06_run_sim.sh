#!/usr/bin/env bash
set -euo pipefail

# Build and run the SoC-level assembly testbench with one IMEM image.
# Usage:
#   sim/soc_asm/06_run_sim.sh [test_name]
# Example:
#   sim/soc_asm/06_run_sim.sh 0601

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/sim/common/resolve_test_name.sh"

TEST_NAME="$(resolve_test_name "${REPO_ROOT}/sw/asm" "S" "${1:-}" "0601_soc_smoke")"
MEM_FILE="${REPO_ROOT}/build/soc_asm/${TEST_NAME}.mem"

if [[ ! -f "${MEM_FILE}" ]]; then
    echo "ERROR: memory image not found: ${MEM_FILE}" >&2
    echo "Run: sim/soc_asm/05_build_mem.sh ${TEST_NAME}" >&2
    exit 1
fi

cd "${REPO_ROOT}"

RTL_FILES=(
    rtl/common/*.sv
    rtl/core/*.sv
    rtl/mem/*.sv
    rtl/periph/*.sv
    rtl/soc/*.sv
)

verilator -sv --binary --timing --top-module tb_rv32i_soc \
    "${RTL_FILES[@]}" \
    tb/sv/tb_rv32i_soc.sv

"${REPO_ROOT}/obj_dir/Vtb_rv32i_soc" "+imem=${MEM_FILE}"
