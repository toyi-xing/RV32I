#!/usr/bin/env bash
set -euo pipefail

#------------------------------------------------------------------------------
# 文件      : uvm/v6_0/data_subsystem/sim/run_test.sh
# 用途      : 编译并运行一个 v6.0 simple data bus UVM test。
#
# 规范：
#   - 编译、仿真、UVM Report Summary 和 simulator $error 使用统一 PASS/FAIL 口径。
#   - ASSERT_ON 是编译期开关；不同开关使用独立 build 目录，不能共用 VCS 增量缓存。
#
# 用法：
#   ./run_test.sh [test_name] [seed] [extra_plusargs...]
#   ASSERT_ON=1 ./run_test.sh [test_name] [seed] [extra_plusargs...]
#------------------------------------------------------------------------------

TEST_NAME="${1:-data_subsystem_base_test}"
SEED="${2:-1}"
ASSERT_ON="${ASSERT_ON:-0}"

if [ "$#" -gt 0 ]; then
    shift
fi
if [ "$#" -gt 0 ]; then
    shift
fi
EXTRA_ARGS=("$@")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# 每组 test/seed/compile configuration 使用独立构建目录，避免 VCS 增量缓存串扰。
BUILD_TAG="${TEST_NAME}_${SEED}"
VCS_DEFINE_ARGS=()
if [[ "${ASSERT_ON}" == "1" ]]; then
    BUILD_TAG+="_assert_on"
    VCS_DEFINE_ARGS+=(+define+ASSERT_ON)
fi

BUILD_DIR="build/${BUILD_TAG}"
LOG_DIR="logs"
mkdir -p "${BUILD_DIR}" "${LOG_DIR}"

RUNTIME_LOG="${LOG_DIR}/${TEST_NAME}_${SEED}.log"
COMPILE_LOG="${LOG_DIR}/${TEST_NAME}_${SEED}_compile.log"

get_uvm_count() {
    local severity="$1"

    if [[ ! -f "${RUNTIME_LOG}" ]]; then
        printf '%s' '-'
        return
    fi

    awk -v severity="${severity}" '
        $1 == severity && $2 == ":" {
            print $3
            found = 1
            exit
        }
        END {
            if (!found) {
                print "-"
            }
        }
    ' "${RUNTIME_LOG}"
}

get_sim_error_count() {
    if [[ ! -f "${RUNTIME_LOG}" ]]; then
        printf '%s' '-'
        return
    fi

    awk '
        /^(Error:|%Error)/ {
            count++
        }
        END {
            print count + 0
        }
    ' "${RUNTIME_LOG}"
}

print_result() {
    local result="$1"
    local run_rc="$2"
    local uvm_error="$3"
    local uvm_fatal="$4"
    local sim_error="$5"

    printf '>>> RESULT: %s (run_rc=%s uvm_error=%s uvm_fatal=%s sim_error=%s)\n' \
        "${result}" "${run_rc}" "${uvm_error}" "${uvm_fatal}" "${sim_error}"
}

echo ">>> Compiling ${TEST_NAME} (seed=${SEED})"

set +e
vcs -full64 -sverilog -ntb_opts uvm \
    -timescale=1ns/1ps \
    -top tb_data_subsystem_uvm_top \
    -f filelist.f \
    "${VCS_DEFINE_ARGS[@]}" \
    -Mdir="${BUILD_DIR}/csrc" \
    -o "${BUILD_DIR}/simv" \
    -l "${COMPILE_LOG}"
compile_rc=$?
set -e

if [[ ${compile_rc} -ne 0 || ! -x "${BUILD_DIR}/simv" ]]; then
    print_result "FAIL" "${compile_rc}" "-" "-" "-"
    exit 1
fi

echo ">>> Running ${TEST_NAME} (seed=${SEED})"
rm -f "${RUNTIME_LOG}"

set +e
"${BUILD_DIR}/simv" \
    +UVM_TESTNAME="${TEST_NAME}" \
    +ntb_random_seed="${SEED}" \
    "${EXTRA_ARGS[@]}" \
    -l "${RUNTIME_LOG}"
run_rc=$?
set -e

uvm_error_count="$(get_uvm_count "UVM_ERROR")"
uvm_fatal_count="$(get_uvm_count "UVM_FATAL")"
sim_error_count="$(get_sim_error_count)"

if [[ ${run_rc} -ne 0 || "${uvm_error_count}" != "0" || "${uvm_fatal_count}" != "0" || "${sim_error_count}" != "0" ]]; then
    print_result "FAIL" "${run_rc}" "${uvm_error_count}" "${uvm_fatal_count}" "${sim_error_count}"
    exit 1
fi

print_result "PASS" "${run_rc}" "${uvm_error_count}" "${uvm_fatal_count}" "${sim_error_count}"
