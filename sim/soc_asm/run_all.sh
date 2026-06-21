#!/usr/bin/env bash
set -euo pipefail

# SoC ASM regression:
# discover all sw/asm/*.S tests, build .mem images, build tb_rv32i_soc once,
# then run each test on the SoC platform.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SIM="${REPO_ROOT}/obj_dir/Vtb_rv32i_soc"

TESTS=()
shopt -s nullglob
for f in "${REPO_ROOT}/sw/asm/"*.S; do
    TESTS+=("$(basename "${f}" .S)")
done
shopt -u nullglob

if [ "${#TESTS[@]}" -eq 0 ]; then
    echo "ERROR: no ASM tests found in ${REPO_ROOT}/sw/asm" >&2
    exit 1
fi

mapfile -t TESTS < <(printf '%s\n' "${TESTS[@]}" | sort)

PASS=0
FAIL=0
FAILED=""

echo ">>> [1/3] Building all SoC ASM .mem files..."
for t in "${TESTS[@]}"; do
    "${SCRIPT_DIR}/05_build_mem.sh" "$t"
done

echo ""
echo ">>> [2/3] Building SoC simulation binary..."
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

echo ""
echo ">>> [3/3] Running all SoC ASM tests..."
for t in "${TESTS[@]}"; do
    echo ""
    echo "=========================================="
    echo "  RUN: ${t}"
    echo "=========================================="
    if "${SIM}" "+imem=${REPO_ROOT}/build/soc_asm/${t}.mem"; then
        echo "  >>> ${t}: PASS"
        PASS=$((PASS + 1))
    else
        echo "  >>> ${t}: FAIL"
        FAIL=$((FAIL + 1))
        FAILED="${FAILED} ${t}"
    fi
done

echo ""
echo "=========================================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "=========================================="
if [ "${FAIL}" -ne 0 ]; then
    echo "Failed:${FAILED}"
    exit 1
fi
