#!/usr/bin/env bash
set -euo pipefail

# Build one RV32I bare-metal C program into IMEM .mem and DMEM .mif images.
# Usage:
#   scripts/build_rv32i_c_image.sh <four_digit_code|test_name|path/to/file.c>
#
# Toolchain defaults:
#   RISCV_PREFIX=riscv64-unknown-elf
# Optional:
#   TOOLCHAIN_ENV=/path/to/env.sh
#   BUILD_DIR=/path/to/output
#   EXTRA_CFLAGS="-DKEY_ACTIVE_LOW=0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <four_digit_code|test_name|path/to/file.c>" >&2
    exit 1
fi

if [[ -n "${TOOLCHAIN_ENV:-}" ]]; then
    if [[ ! -f "${TOOLCHAIN_ENV}" ]]; then
        echo "ERROR: TOOLCHAIN_ENV does not exist: ${TOOLCHAIN_ENV}" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "${TOOLCHAIN_ENV}"
fi

query="$1"
sw_c_dir="${REPO_ROOT}/sw/c"
build_dir="${BUILD_DIR:-${REPO_ROOT}/build/fpga_c}"

resolve_c_file() {
    local q="$1"
    local candidate
    local -a matches

    if [[ -f "${q}" ]]; then
        realpath "${q}"
        return
    fi

    if [[ -f "${sw_c_dir}/${q}" ]]; then
        realpath "${sw_c_dir}/${q}"
        return
    fi

    if [[ "${q}" == *.c && -f "${sw_c_dir}/${q}" ]]; then
        realpath "${sw_c_dir}/${q}"
        return
    fi

    if [[ "${q}" != *.c && -f "${sw_c_dir}/${q}.c" ]]; then
        realpath "${sw_c_dir}/${q}.c"
        return
    fi

    shopt -s nullglob
    matches=("${sw_c_dir}/${q}"*.c)
    shopt -u nullglob

    if [[ ${#matches[@]} -eq 1 ]]; then
        realpath "${matches[0]}"
        return
    fi

    if [[ ${#matches[@]} -gt 1 ]]; then
        echo "ERROR: '${q}' matches multiple C files:" >&2
        printf '  %s\n' "${matches[@]}" >&2
        exit 1
    fi

    candidate="${sw_c_dir}/${q}.c"
    echo "ERROR: C file not found for '${q}'." >&2
    echo "Tried: ${candidate} and ${sw_c_dir}/${q}*.c" >&2
    exit 1
}

c_file="$(resolve_c_file "${query}")"
test_name="$(basename "${c_file}" .c)"
crt0_file="${REPO_ROOT}/sw/c_runtime/crt0.S"
linker_file="${REPO_ROOT}/sw/linker/c_baremetal.ld"

mkdir -p "${build_dir}"

riscv_prefix="${RISCV_PREFIX:-riscv64-unknown-elf}"
cc="${RISCV_CC:-${riscv_prefix}-gcc}"
objcopy="${RISCV_OBJCOPY:-${riscv_prefix}-objcopy}"
objdump="${RISCV_OBJDUMP:-${riscv_prefix}-objdump}"

elf="${build_dir}/${test_name}.elf"
dump="${build_dir}/${test_name}.dump"
map="${build_dir}/${test_name}.map"
imem_bin="${build_dir}/${test_name}_imem.bin"
dmem_bin="${build_dir}/${test_name}_dmem.bin"
imem_mem="${build_dir}/${test_name}_imem.mem"
dmem_mem="${build_dir}/${test_name}_dmem.mem"
dmem_mif="${build_dir}/${test_name}_dmem.mif"

"${cc}" \
    -march=rv32i_zicsr \
    -mabi=ilp32 \
    -mno-relax \
    -msmall-data-limit=0 \
    -mcmodel=medlow \
    -O2 \
    -g \
    -ffreestanding \
    -fno-builtin \
    -fno-pic \
    -fno-pie \
    -fno-asynchronous-unwind-tables \
    -fno-unwind-tables \
    -nostdlib \
    -nostartfiles \
    -I "${REPO_ROOT}/sw/include" \
    ${EXTRA_CFLAGS:-} \
    -Wl,-T,"${linker_file}" \
    -Wl,--no-relax \
    -Wl,-Map,"${map}" \
    -o "${elf}" \
    "${crt0_file}" \
    "${c_file}"

"${objdump}" -d -M no-aliases,numeric "${elf}" > "${dump}"

"${objcopy}" \
    -O binary \
    -j .text.init \
    -j .text.trap \
    -j .text \
    "${elf}" \
    "${imem_bin}"

"${objcopy}" \
    -O binary \
    -j .dmem_image \
    "${elf}" \
    "${dmem_bin}"

imem_size="$(stat -c%s "${imem_bin}")"
dmem_size="$(stat -c%s "${dmem_bin}")"

if (( imem_size > 16384 )); then
    echo "ERROR: IMEM image is ${imem_size} bytes, limit is 16384 bytes." >&2
    exit 1
fi

if (( dmem_size > 16384 )); then
    echo "ERROR: DMEM image is ${dmem_size} bytes, limit is 16384 bytes." >&2
    exit 1
fi

python3 "${REPO_ROOT}/scripts/bin2mem32.py" "${imem_bin}" "${imem_mem}"
python3 "${REPO_ROOT}/scripts/bin2mem32.py" "${dmem_bin}" "${dmem_mem}"
python3 "${REPO_ROOT}/scripts/mem32_to_mif.py" "${dmem_mem}" "${dmem_mif}" --depth 4096 --width 32

cp "${imem_mem}" "${build_dir}/current_imem.mem"
cp "${dmem_mif}" "${build_dir}/current_dmem.mif"

cat > "${build_dir}/last_build.txt" <<EOF
TEST_NAME=${test_name}
C_FILE=${c_file}
ELF=${elf}
DUMP=${dump}
MAP=${map}
IMEM_MEM=${imem_mem}
DMEM_MIF=${dmem_mif}
IMEM_SIZE=${imem_size}
DMEM_SIZE=${dmem_size}
EOF

echo "Built ${test_name}"
echo "  ELF      ${elf}"
echo "  dump     ${dump}"
echo "  map      ${map}"
echo "  IMEM     ${imem_mem} (${imem_size} bytes)"
echo "  DMEM MIF ${dmem_mif} (${dmem_size} bytes before MIF fill)"
