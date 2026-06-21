#!/usr/bin/env bash
set -euo pipefail

# Build and run the SoC-level C testbench with IMEM/DMEM images.
# Usage:
#   sim/soc_c/06_run_sim.sh [test_name]
# Example:
#   sim/soc_c/06_run_sim.sh 0651

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${REPO_ROOT}/sim/common/resolve_test_name.sh"

TEST_NAME="$(resolve_test_name "${REPO_ROOT}/sw/c" "c" "${1:-}" "0651_soc_mmio_smoke")"
BUILD_DIR="${REPO_ROOT}/build/soc_c"
IMEM_FILE="${BUILD_DIR}/${TEST_NAME}_imem.mem"
DMEM_FILE="${BUILD_DIR}/${TEST_NAME}_dmem.mem"

if [[ ! -f "${IMEM_FILE}" ]]; then
    echo "ERROR: IMEM image not found: ${IMEM_FILE}" >&2
    echo "Run: sim/soc_c/05_build_mem.sh ${TEST_NAME}" >&2
    exit 1
fi

if [[ ! -f "${DMEM_FILE}" ]]; then
    echo "ERROR: DMEM image not found: ${DMEM_FILE}" >&2
    echo "Run: sim/soc_c/05_build_mem.sh ${TEST_NAME}" >&2
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

"${REPO_ROOT}/obj_dir/Vtb_rv32i_soc" "+imem=${IMEM_FILE}" "+dmem=${DMEM_FILE}"
