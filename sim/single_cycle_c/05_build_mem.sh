#!/usr/bin/env bash
set -euo pipefail

# 把一个 RV32I C 裸机测试编译成 IMEM/DMEM 两份 .mem 镜像。
# 用法：
#   sim/single_cycle_c/05_build_mem.sh [test_name]
# 示例：
#   sim/single_cycle_c/05_build_mem.sh c_smoke

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOOLCHAIN_ENV="${TOOLCHAIN_ENV:-/home/a/tools/riscv-unknown-elf/env.sh}"

TEST_NAME="${1:-c_smoke}"
C_FILE="${REPO_ROOT}/sw/c/${TEST_NAME}.c"
CRT0_FILE="${REPO_ROOT}/sw/c_runtime/crt0.S"
LINKER_FILE="${REPO_ROOT}/sw/linker/c_baremetal.ld"
BUILD_DIR="${REPO_ROOT}/build/single_cycle_c"

if [[ -f "${TOOLCHAIN_ENV}" ]]; then
    # 即使从非交互 shell 运行，也不要求用户手动 source 工具链环境。
    # shellcheck disable=SC1090
    source "${TOOLCHAIN_ENV}"
fi

if [[ ! -f "${C_FILE}" ]]; then
    echo "ERROR: C test not found: ${C_FILE}" >&2
    exit 1
fi

if [[ ! -f "${CRT0_FILE}" ]]; then
    echo "ERROR: C runtime startup not found: ${CRT0_FILE}" >&2
    exit 1
fi

mkdir -p "${BUILD_DIR}"

riscv64-unknown-elf-gcc \
    -march=rv32i \
    -mabi=ilp32 \
    -mno-relax \
    -msmall-data-limit=0 \
    -mcmodel=medlow \
    -O0 \
    -g \
    -ffreestanding \
    -fno-builtin \
    -fno-pic \
    -fno-pie \
    -fno-asynchronous-unwind-tables \
    -fno-unwind-tables \
    -nostdlib \
    -nostartfiles \
    -Wl,-T,"${LINKER_FILE}" \
    -Wl,--no-relax \
    -Wl,-Map,"${BUILD_DIR}/${TEST_NAME}.map" \
    -o "${BUILD_DIR}/${TEST_NAME}.elf" \
    "${CRT0_FILE}" \
    "${C_FILE}"

riscv64-unknown-elf-objdump \
    -d \
    -M no-aliases,numeric \
    "${BUILD_DIR}/${TEST_NAME}.elf" > "${BUILD_DIR}/${TEST_NAME}.dump"

riscv64-unknown-elf-objcopy \
    -O binary \
    -j .text \
    "${BUILD_DIR}/${TEST_NAME}.elf" \
    "${BUILD_DIR}/${TEST_NAME}_imem.bin"

riscv64-unknown-elf-objcopy \
    -O binary \
    -j .dmem_image \
    "${BUILD_DIR}/${TEST_NAME}.elf" \
    "${BUILD_DIR}/${TEST_NAME}_dmem.bin"

python3 "${REPO_ROOT}/scripts/bin2mem32.py" \
    "${BUILD_DIR}/${TEST_NAME}_imem.bin" \
    "${BUILD_DIR}/${TEST_NAME}_imem.mem"

python3 "${REPO_ROOT}/scripts/bin2mem32.py" \
    "${BUILD_DIR}/${TEST_NAME}_dmem.bin" \
    "${BUILD_DIR}/${TEST_NAME}_dmem.mem"

echo "Built ${BUILD_DIR}/${TEST_NAME}_imem.mem"
echo "Built ${BUILD_DIR}/${TEST_NAME}_dmem.mem"

