#!/usr/bin/env bash

# Resolve a test argument to the actual source basename.
#
# Accepted forms:
#   0102              -> sw/asm/0102_*.S, must match exactly one file
#   0102_alu_imm     -> sw/asm/0102_alu_imm.S
#
# The function prints only the resolved basename on stdout. Diagnostics go to
# stderr so callers can safely use command substitution.
resolve_test_name() {
    local test_dir="$1"
    local ext="$2"
    local requested="${3:-}"
    local default_name="$4"
    local test_name
    local exact_file
    local matches=()
    local match

    if [[ -n "${requested}" ]]; then
        test_name="${requested}"
    else
        test_name="${default_name}"
    fi

    if [[ "${test_name}" == *.${ext} ]]; then
        test_name="${test_name%.${ext}}"
    fi

    exact_file="${test_dir}/${test_name}.${ext}"
    if [[ -f "${exact_file}" ]]; then
        printf '%s\n' "${test_name}"
        return 0
    fi

    if [[ "${test_name}" =~ ^[0-9]{4}$ ]]; then
        shopt -s nullglob
        matches=("${test_dir}/${test_name}_"*.${ext})
        shopt -u nullglob

        case "${#matches[@]}" in
            1)
                match="$(basename "${matches[0]}")"
                printf '%s\n' "${match%.${ext}}"
                return 0
                ;;
            0)
                echo "ERROR: no ${ext} test matches prefix ${test_name} in ${test_dir}" >&2
                return 1
                ;;
            *)
                echo "ERROR: multiple ${ext} tests match prefix ${test_name} in ${test_dir}:" >&2
                for match in "${matches[@]}"; do
                    echo "  $(basename "${match}")" >&2
                done
                return 1
                ;;
        esac
    fi

    echo "ERROR: test not found: ${test_dir}/${test_name}.${ext}" >&2
    echo "       Use a full basename such as 0102_alu_imm, or a four-digit prefix such as 0102." >&2
    return 1
}
