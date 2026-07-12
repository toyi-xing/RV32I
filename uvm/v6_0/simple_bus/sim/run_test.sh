#!/usr/bin/env bash
set -euo pipefail

# 编译并运行一个 simple bus UVM test。
# 用法：./run_test.sh [test_name] [seed] [extra_plusargs...]
# 示例：./run_test.sh simple_bus_base_test 1 +UVM_VERBOSITY=UVM_HIGH

TEST_NAME="${1:-simple_bus_base_test}"
SEED="${2:-1}"

if [ "$#" -gt 0 ]; then
    shift
fi
if [ "$#" -gt 0 ]; then
    shift
fi
EXTRA_ARGS=("$@")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# 每组 test/seed 使用独立构建目录，避免不同随机种子或并行运行相互覆盖。
BUILD_DIR="build/${TEST_NAME}_${SEED}"
LOG_DIR="logs"
mkdir -p "${BUILD_DIR}" "${LOG_DIR}"

echo ">>> Compiling ${TEST_NAME} (seed=${SEED})"
vcs -full64 -sverilog -ntb_opts uvm \
    -timescale=1ns/1ps \
    -top tb_simple_bus_uvm_top \
    -f filelist.f \
    -Mdir="${BUILD_DIR}/csrc" \
    -o "${BUILD_DIR}/simv" \
    -l "${LOG_DIR}/${TEST_NAME}_${SEED}_compile.log"

echo ">>> Running ${TEST_NAME} (seed=${SEED})"
"${BUILD_DIR}/simv" \
    +UVM_TESTNAME="${TEST_NAME}" \
    +ntb_random_seed="${SEED}" \
    "${EXTRA_ARGS[@]}" \
    -l "${LOG_DIR}/${TEST_NAME}_${SEED}.log"
