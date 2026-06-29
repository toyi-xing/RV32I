#!/usr/bin/env bash
set -euo pipefail

# Build a C program and replace the FPGA memory initialization files.
# Usage:
#   scripts/update_fpga_mem.sh <four_digit_code|test_name|path/to/file.c>
#
# Replaces:
#   fpga/mem/current_imem.mem
#   fpga/mem/current_dmem.mif
#
# It intentionally does not create fpga/mem/current_dmem.mem because the FPGA
# DMEM wrapper instantiates altsyncram with a MIF init file.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <four_digit_code|test_name|path/to/file.c>" >&2
    exit 1
fi

build_dir="${BUILD_DIR:-${REPO_ROOT}/build/fpga_c}"

BUILD_DIR="${build_dir}" "${SCRIPT_DIR}/build_rv32i_c_image.sh" "$1"

install -D -m 0644 "${build_dir}/current_imem.mem" "${REPO_ROOT}/fpga/mem/current_imem.mem"
install -D -m 0644 "${build_dir}/current_dmem.mif" "${REPO_ROOT}/fpga/mem/current_dmem.mif"
rm -f "${REPO_ROOT}/fpga/mem/current_dmem.mem"

echo "Updated FPGA memory init files:"
echo "  ${REPO_ROOT}/fpga/mem/current_imem.mem"
echo "  ${REPO_ROOT}/fpga/mem/current_dmem.mif"
echo
echo "Next: re-run Quartus compile so the new init files are packed into the SOF."
