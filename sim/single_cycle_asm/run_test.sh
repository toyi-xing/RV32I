#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_NAME="${1:-smoke}"

"${SCRIPT_DIR}/05_build_mem.sh" "${TEST_NAME}"
"${SCRIPT_DIR}/06_run_sim.sh" "${TEST_NAME}"
