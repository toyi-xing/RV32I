#!/usr/bin/env bash
set -euo pipefail

# Build one SoC-level RV32I assembly test into a 32-bit word IMEM .mem image.
# Usage:
#   sim/soc_asm/05_build_mem.sh [test_name]
# Example:
#   sim/soc_asm/05_build_mem.sh 0601

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOOLCHAIN_ENV="${TOOLCHAIN_ENV:-/home/a/tools/riscv-unknown-elf/env.sh}"

source "${REPO_ROOT}/sim/common/resolve_test_name.sh"

TEST_NAME="$(resolve_test_name "${REPO_ROOT}/sw/asm" "S" "${1:-}" "0601_soc_smoke")"
ASM_FILE="${REPO_ROOT}/sw/asm/${TEST_NAME}.S"
BUILD_DIR="${REPO_ROOT}/build/soc_asm"

if [[ -f "${TOOLCHAIN_ENV}" ]]; then
    # shellcheck disable=SC1090
    source "${TOOLCHAIN_ENV}"
fi

if [[ ! -f "${ASM_FILE}" ]]; then
    echo "ERROR: assembly test not found: ${ASM_FILE}" >&2
    exit 1
fi

mkdir -p "${BUILD_DIR}"

riscv64-unknown-elf-gcc \
    -march=rv32i \
    -mabi=ilp32 \
    -mno-relax \
    -nostdlib \
    -nostartfiles \
    -ffreestanding \
    -I "${REPO_ROOT}/sw/include" \
    -Wl,-T,"${REPO_ROOT}/sw/linker/asm_test.ld" \
    -Wl,--no-relax \
    -o "${BUILD_DIR}/${TEST_NAME}.elf" \
    "${ASM_FILE}"

riscv64-unknown-elf-objdump \
    -d \
    -M no-aliases,numeric \
    "${BUILD_DIR}/${TEST_NAME}.elf" > "${BUILD_DIR}/${TEST_NAME}.dump"

riscv64-unknown-elf-objcopy \
    -O binary \
    "${BUILD_DIR}/${TEST_NAME}.elf" \
    "${BUILD_DIR}/${TEST_NAME}.bin"

python3 "${REPO_ROOT}/scripts/bin2mem32.py" \
    "${BUILD_DIR}/${TEST_NAME}.bin" \
    "${BUILD_DIR}/${TEST_NAME}.mem"

echo "Built ${BUILD_DIR}/${TEST_NAME}.mem"
