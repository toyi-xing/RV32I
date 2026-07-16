#!/usr/bin/env bash
set -euo pipefail

#------------------------------------------------------------------------------
# 文件      : uvm/v6_0/simple_bus/sim/run_all.sh
# 用途      : v6.0 simple data bus UVM 回归入口。
#
# 规范：
#   - TESTS 中每一项均通过 run_test.sh 独立编译并运行。
#   - 单个 test 失败后继续执行剩余 test，最后以汇总结果决定脚本退出码。
#   - UVM severity 和 simulator error 从每个 test 的 runtime log 中解析；编译/启动
#     失败且未生成 runtime log 时，统计显示为 -。
#
# 功能：
#   - 逐项执行当前回归集。
#   - 打印每个 test 的 UVM Report Summary、simulator error 统计和总失败数。
#------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"

# 后续新增回归 test 时，只需在此追加 test class 名。
TESTS=(
    simple_bus_base_test
    simple_bus_smoke_test
)

SEED=1
FAIL_COUNT=0
TOTAL_ERROR=0
TOTAL_FATAL=0
TOTAL_SIM_ERROR=0
RESULT_TESTS=()
RESULT_RUN_RCS=()
RESULT_INFOS=()
RESULT_WARNINGS=()
RESULT_ERRORS=()
RESULT_FATALS=()
RESULT_SIM_ERRORS=()
RESULT_STATUS=()

get_uvm_count() {
    local log_path="$1"
    local severity="$2"

    if [[ ! -f "${log_path}" ]]; then
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
    ' "${log_path}"
}

get_sim_error_count() {
    local log_path="$1"

    if [[ ! -f "${log_path}" ]]; then
        printf '%s' '-'
        return
    fi

    # VCS 对 SystemVerilog $error（包括当前 SVA action block）的 runtime
    # diagnostic 使用 Error: 或 %Error 前缀；UVM_ERROR 由 get_uvm_count 单独统计。
    awk '
        /^(Error:|%Error)/ {
            count++
        }
        END {
            print count + 0
        }
    ' "${log_path}"
}

for test_name in "${TESTS[@]}"; do
    log_path="${LOG_DIR}/${test_name}_${SEED}.log"

    # 避免编译失败时误读上一次运行遗留的 runtime log。
    rm -f "${log_path}"

    set +e
    "${SCRIPT_DIR}/run_test.sh" "${test_name}" "${SEED}"
    run_rc=$?
    set -e

    info_count="$(get_uvm_count "${log_path}" "UVM_INFO")"
    warning_count="$(get_uvm_count "${log_path}" "UVM_WARNING")"
    error_count="$(get_uvm_count "${log_path}" "UVM_ERROR")"
    fatal_count="$(get_uvm_count "${log_path}" "UVM_FATAL")"
    sim_error_count="$(get_sim_error_count "${log_path}")"

    result="PASS"
    if [[ ${run_rc} -ne 0 || "${error_count}" != "0" || "${fatal_count}" != "0" || "${sim_error_count}" != "0" ]]; then
        result="FAIL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    if [[ "${error_count}" =~ ^[0-9]+$ ]]; then
        TOTAL_ERROR=$((TOTAL_ERROR + error_count))
    fi
    if [[ "${fatal_count}" =~ ^[0-9]+$ ]]; then
        TOTAL_FATAL=$((TOTAL_FATAL + fatal_count))
    fi
    if [[ "${sim_error_count}" =~ ^[0-9]+$ ]]; then
        TOTAL_SIM_ERROR=$((TOTAL_SIM_ERROR + sim_error_count))
    fi

    RESULT_TESTS+=("${test_name}")
    RESULT_RUN_RCS+=("${run_rc}")
    RESULT_INFOS+=("${info_count}")
    RESULT_WARNINGS+=("${warning_count}")
    RESULT_ERRORS+=("${error_count}")
    RESULT_FATALS+=("${fatal_count}")
    RESULT_SIM_ERRORS+=("${sim_error_count}")
    RESULT_STATUS+=("${result}")
done

printf '\n%-28s %6s %7s %8s %8s %8s %8s %9s %8s\n' \
    "TEST" "SEED" "RUN_RC" "UVM_INFO" "UVM_WARN" "UVM_ERROR" "UVM_FATAL" "SIM_ERROR" "RESULT"
printf '%*s\n' 99 '' | tr ' ' '-'
for i in "${!RESULT_TESTS[@]}"; do
    printf '%-28s %6s %7s %8s %8s %8s %8s %9s %8s\n' \
        "${RESULT_TESTS[i]}" "${SEED}" "${RESULT_RUN_RCS[i]}" "${RESULT_INFOS[i]}" \
        "${RESULT_WARNINGS[i]}" "${RESULT_ERRORS[i]}" "${RESULT_FATALS[i]}" \
        "${RESULT_SIM_ERRORS[i]}" "${RESULT_STATUS[i]}"
done
printf '%*s\n' 99 '' | tr ' ' '-'
printf 'Regression result: tests=%d failed=%d uvm_error=%d uvm_fatal=%d sim_error=%d\n' \
    "${#TESTS[@]}" "${FAIL_COUNT}" "${TOTAL_ERROR}" "${TOTAL_FATAL}" "${TOTAL_SIM_ERROR}"

if [[ ${FAIL_COUNT} -ne 0 ]]; then
    exit 1
fi
