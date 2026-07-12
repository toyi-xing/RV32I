#!/usr/bin/env bash
set -euo pipefail

# v6.0 simple data bus UVM 回归入口。
# 当前只有最小 base test；后续新增 test 时在此追加独立调用。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/run_test.sh" simple_bus_base_test 1
