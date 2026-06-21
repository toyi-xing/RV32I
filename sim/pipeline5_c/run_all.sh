#!/usr/bin/env bash
set -euo pipefail

# Core C regression:
# discover legacy core-level sw/c/*.c tests, build IMEM/DMEM images, build
# tb_core_pipeline5 once, then run each test on the core-only platform.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SIM="${REPO_ROOT}/obj_dir/Vtb_core_pipeline5"

TESTS=()
shopt -s nullglob
for f in "${REPO_ROOT}/sw/c/"*.c; do
    t="$(basename "${f}" .c)"
    if [[ "${t}" =~ ^0[0-5][0-9][0-9]_ ]]; then
        TESTS+=("${t}")
    fi
done
shopt -u nullglob

if [ "${#TESTS[@]}" -eq 0 ]; then
    echo "ERROR: no core-level C tests found in ${REPO_ROOT}/sw/c" >&2
    exit 1
fi

mapfile -t TESTS < <(printf '%s\n' "${TESTS[@]}" | sort)

PASS=0
FAIL=0
FAILED=""

echo ">>> [1/3] Building all core C IMEM/DMEM files..."
for t in "${TESTS[@]}"; do
    "${SCRIPT_DIR}/05_build_mem.sh" "$t"
done

echo ""
echo ">>> [2/3] Building core simulation binary..."
cd "${REPO_ROOT}"
RTL_FILES=(
    rtl/common/*.sv
    rtl/core/*.sv
    rtl/mem/*.sv
)

verilator -sv --binary --timing --top-module tb_core_pipeline5 \
    "${RTL_FILES[@]}" \
    tb/sv/tb_core_pipeline5.sv

echo ""
echo ">>> [3/3] Running all core C tests..."
for t in "${TESTS[@]}"; do
    echo ""
    echo "=========================================="
    echo "  RUN: ${t}"
    echo "=========================================="
    if "${SIM}" \
        "+imem=${REPO_ROOT}/build/pipeline5_c/${t}_imem.mem" \
        "+dmem=${REPO_ROOT}/build/pipeline5_c/${t}_dmem.mem"; then
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
