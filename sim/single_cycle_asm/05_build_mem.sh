#!/usr/bin/env bash
set -euo pipefail

# 把一个 RV32I 裸机汇编测试编译成 32-bit word .mem 镜像。
# 用法：
#   sim/single_cycle_asm/05_build_mem.sh [test_name]
# 示例：
#   sim/single_cycle_asm/05_build_mem.sh smoke

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOOLCHAIN_ENV="/home/a/tools/riscv-unknown-elf/env.sh"

TEST_NAME="${1:-smoke}"
ASM_FILE="${REPO_ROOT}/sw/asm/${TEST_NAME}.S"
BUILD_DIR="${REPO_ROOT}/build"

if [[ -f "${TOOLCHAIN_ENV}" ]]; then
    # 即使从非交互 shell 运行，也不要求用户手动 source 工具链环境。
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
