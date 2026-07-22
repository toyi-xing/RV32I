# v6.0 wait-state 验证收口、SVA 与 UVM 入门 demo 执行计划

当前工程已经完成：

- RV32I 五级流水线主路径。
- 最小 M-mode CSR/trap、`ECALL/EBREAK/MRET` 和 Zicsr。
- SoC 地址图、GPIO0、UART0、TIMER0、machine timer/external interrupt。
- data-side simple data bus、single outstanding、MEM backpressure。
- DMEM/MMIO response delay wrapper 和 TB mailbox delay 配置。
- SoC 级 Verilator ASM/C 自检回归。

本计划根据 `docs/08xx/0830 RV32I教学核后续完善路线：从v2.0到最小完整裸机核心.md` 和 `docs/08xx/0835 wait-state验证收口、SVA与UVM入门demo规划.md` 编写，目标是新增一套独立的 VCS/SVA/UVM 验证路径，用最小范围的 simple data bus/peripheral demo 学会并沉淀 UVM 基础验证结构。

本计划会覆盖旧的 0834 执行计划。0834 已完成内容以 README、0834 文档和当前 RTL 为准。

## 0. 本阶段边界

本阶段实现：

- 保留现有 Verilator directed regression：
  - `sim/soc_asm`
  - `sim/soc_c`
  - `tb/sv/tb_rv32i_soc.sv`
  - `sw/asm`
  - `sw/c`
- 新增独立、可复现的 VCS/UVM 工作区：
  - `uvm/v6_0/data_subsystem/dut`：v6.0 最小 DUT RTL 与 ABI 快照。
  - `uvm/v6_0/data_subsystem/tb`：UVM interface、class、assertion 和 harness。
  - `uvm/v6_0/data_subsystem/sim`：本版本独立 filelist 和 VCS 脚本。
- 第一版 UVM 不实例化整颗 `rv32i_soc`，而是实例化 simple data bus harness。
- 第一版 UVM master 直接驱动 simple data bus，不使用 `.mem`、crt0、C/ASM 测试程序。
- 第一版 DUT 优先选择 `data_subsystem` 加必要 memory/peripheral 连接。
- 第一版先跑通 DMEM 基本 read/write smoke，再扩 MMIO、SVA、coverage。

本阶段不实现：

- 新 CPU/SoC 功能。
- AXI-Lite RTL 或 AXI-Lite UVM agent。
- SoC/CPU 级完整 UVM。
- ISS lockstep。
- random instruction generation。
- 替换现有 Verilator directed test。

执行原则：

- Verilator 路径和 VCS/UVM 路径并行存在，互不强制依赖。
- 新增 UVM 文件默认只进入 `uvm/v6_0/data_subsystem/sim/filelist.f`。
- VCS filelist 只编译本工作区 `dut/rtl` 快照，不引用根目录主线 `rtl/`，保证后续主线切换 AXI-Lite 后本环境仍可运行。
- 现有 RTL 不为了 UVM 大改接口；若需要 harness 适配，优先在 `uvm/v6_0/data_subsystem/tb` 下完成。
- UVM 若发现真实 RTL bug，先修根目录主线并跑 Verilator directed regression，再同步到开发期 DUT 快照并记录；0835 完成后冻结快照。
- 每完成一个可运行节点，先跑一次最小 VCS test，再继续扩展。
- 本计划中的代码块是建议骨架；实现时可以按 VCS 报错、现有代码风格和个人理解微调，但类名、端口语义、连接方向尽量保持一致。

## 1. VCS/UVM 最小工程骨架 `已完成`

目标：先建立一个能被 VCS 编译运行的空 UVM test，确认工具链、目录、filelist、脚本和 UVM 基础入口都可用。

### 1.1 建立独立工作区和 DUT 快照 `已完成`

当前工作区：

```text
uvm/
  readme.md
  v6_0/
    simple_bus/
      spec.md
      dut/
        README.md
        rtl/
          common/
          mem/
          periph/
          soc/
        docs/
      tb/
      sim/
```

`dut/rtl` 已从 `c2f7d82` / `v6.0-data-side-variable-delay` 复制 `data_subsystem` 的最小编译闭包；`dut/docs/periph_register_abi.md` 保存匹配的外设 ABI。具体文件映射、开发期同步和冻结规则见 `uvm/v6_0/data_subsystem/dut/README.md`。

本步骤不改现有 `rtl/`、`tb/sv`、`sim/soc_asm`、`sim/soc_c`。工作区建立时 `tb/` 和 `sim/` 留空，后续 UVM 源码和脚本由本计划逐步创建。

### 1.2 新增 UVM package 文件 `已完成`

新增：

```text
uvm/v6_0/data_subsystem/tb/pkg/data_subsystem_pkg.sv
```

第一版先只 include base test，后续每新增 class 文件就追加 include。

建议骨架：

```systemverilog
package data_subsystem_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    import core_pkg::*;
    import soc_pkg::*;
    import data_bus_pkg::*;

    `include "data_subsystem_base_test.svh"
endpackage
```

注意：

- `uvm_macros.svh` 必须在使用 `` `uvm_component_utils`` 等宏之前 include。
- class 文件通过 package include，不在 `filelist.f` 里重复列。
- 后续 include 顺序按“被依赖者在前”维护，例如 item 在 driver/monitor 前，base test 在 smoke test 前。

### 1.3 新增空 base test `已完成`

新增：

```text
uvm/v6_0/data_subsystem/tb/tests/data_subsystem_base_test.svh
```

第一版只验证 UVM test 能启动。

建议骨架：

```systemverilog
class data_subsystem_base_test extends uvm_test;
    `uvm_component_utils(data_subsystem_base_test)

    function new(string name = "data_subsystem_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        `uvm_info(get_type_name(), "build_phase entered", UVM_LOW)
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info(get_type_name(), "empty UVM base test is running", UVM_LOW)
        #100ns;
        phase.drop_objection(this);
    endtask
endclass
```

后续第 7 章会在本类中增加：

```systemverilog
data_subsystem_env env;
```

### 1.4 新增最小 UVM top `已完成`

新增：

```text
uvm/v6_0/data_subsystem/tb/top/tb_data_subsystem_uvm_top.sv
```

第一版只提供 clock/reset、全局 timeout 和 `run_test()`。

建议骨架：

```systemverilog
`timescale 1ns/1ps
`default_nettype none

module tb_data_subsystem_uvm_top;
    import uvm_pkg::*;
    import data_subsystem_pkg::*;

    logic clk;
    logic rst_n;

    initial begin
        clk = 1'b0;
        forever #5ns clk = ~clk;
    end

    initial begin
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
    end

    initial begin
        uvm_top.set_timeout(1ms, 1'b0);
        run_test();
    end
endmodule

`default_nettype wire
```

后续第 2 章会在这里例化 `simple_bus_if`，第 8 章会在这里例化 `data_subsystem` 和 `simple_ram`。

### 1.5 新增 VCS filelist `已完成`

新增：

```text
uvm/v6_0/data_subsystem/sim/filelist.f
```

第一版按顺序加入：

```text
+incdir+../tb/tests

../dut/rtl/common/core_pkg.sv
../dut/rtl/common/soc_pkg.sv
../dut/rtl/common/data_bus_pkg.sv

../tb/pkg/data_subsystem_pkg.sv
../tb/top/tb_data_subsystem_uvm_top.sv
```

注意：

- 这里假设脚本从 `uvm/v6_0/data_subsystem/sim` 目录执行；DUT 快照和 UVM testbench 分别使用 `../dut`、`../tb` 相对路径。
- `soc_pkg.sv`、`data_bus_pkg.sv` 都依赖 `core_pkg.sv`，因此 `core_pkg.sv` 放最前。
- 后续第 2 章新增 interface 后，`simple_bus_if.sv` 应放在 `data_subsystem_pkg.sv` 前，因为 driver/monitor class 会声明对应 modport 类型的 virtual interface。

### 1.6 新增 VCS 单测脚本 `已完成`

新增：

```text
uvm/v6_0/data_subsystem/sim/run_test.sh
```

脚本第一版建议支持：

```text
./run_test.sh [test_name] [seed] [extra_plusargs...]
```

建议骨架：

```bash
#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="${1:-data_subsystem_base_test}"
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

BUILD_DIR="build/${TEST_NAME}_${SEED}"
LOG_DIR="logs"
mkdir -p "$BUILD_DIR" "$LOG_DIR"

vcs -full64 -sverilog -ntb_opts uvm \
    -timescale=1ns/1ps \
    -top tb_data_subsystem_uvm_top \
    -f filelist.f \
    -Mdir="${BUILD_DIR}/csrc" \
    -o "${BUILD_DIR}/simv" \
    -l "${LOG_DIR}/${TEST_NAME}_${SEED}_compile.log"

"${BUILD_DIR}/simv" \
    +UVM_TESTNAME="${TEST_NAME}" \
    +ntb_random_seed="${SEED}" \
    "${EXTRA_ARGS[@]}" \
    -l "${LOG_DIR}/${TEST_NAME}_${SEED}.log"
```

注意：

- 如果你的 VCS 需要先 source 环境变量，不要写死在仓库脚本里；可以在 shell 环境里提前配置。
- `EXTRA_ARGS` 只用于传给 simv 的运行期 plusarg；第 11～16 章的 wrapper delay 主回归由
  wrapper cfg agent 驱动，不再依赖 `+DMEM_DELAY`。
- `+define+ASSERT_ON` 是 VCS 编译期选项，不能通过 simv 的运行期 `EXTRA_ARGS` 传入；第 10.3 节会把它加入 VCS 编译命令。
- 如果 VCS 对 `-ntb_opts uvm` 版本口径不同，按本机 VCS 报错调整。

上述 top 骨架从第一版开始设置全局 timeout，避免 DUT 不返回 response 时仿真永久挂住。该 timeout 是整场 test 的最后保护，不替代 driver 后续对单笔 transaction 的超时诊断。进入第 5 章实现 driver 时，应按最大配置 delay 加裕量设置 request/response 等待上限，超时后用 `uvm_fatal` 打印当前 transaction。

### 1.7 新增 VCS 回归脚本 `已完成`

新增：

```text
uvm/v6_0/data_subsystem/sim/run_all.sh
```

第一版只调用一次 base test。

建议骨架：

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

./run_test.sh data_subsystem_base_test 1
```

后续每新增一个 test，就在这里加一行。

### 1.8 更新 `.gitignore` `已完成`

检查并补充 VCS/UVM 运行产物忽略规则。

至少覆盖：

```text
uvm/v6_0/data_subsystem/sim/build/
uvm/v6_0/data_subsystem/sim/logs/
uvm/v6_0/data_subsystem/sim/csrc/
uvm/v6_0/data_subsystem/sim/simv
uvm/v6_0/data_subsystem/sim/simv.daidir/
uvm/v6_0/data_subsystem/sim/ucli.key
uvm/v6_0/data_subsystem/sim/vcs.log
uvm/v6_0/data_subsystem/sim/*.vpd
uvm/v6_0/data_subsystem/sim/*.fsdb
```

如果本仓库已有更通用 VCS 忽略规则，优先沿用已有风格。

### 1.9 验证节点 `已完成`

本章完成标准：

- `uvm/v6_0/data_subsystem/sim/run_test.sh data_subsystem_base_test` 可以编译并运行。
- log 中能看到 `UVM_INFO`。
- 全局 UVM timeout 已启用，test 不会因永久等待而无限运行。
- 没有引入 Verilator directed regression 依赖。
- `git status` 中只出现预期新增文件和 `.gitignore` 修改。

## 2. simple data bus interface `已完成`

目标：把 simple data bus 信号集中到一个 SystemVerilog interface 中，供 driver、monitor、assertion 和 DUT harness 共用。

### 2.1 新增 interface 文件 `已完成`

新增：

```text
uvm/v6_0/data_subsystem/tb/simple_bus_if.sv
```

建议骨架：

```systemverilog
`default_nettype none

interface simple_bus_if (
    input logic clk,
    input logic rst_n
);
    import core_pkg::*;
    import data_bus_pkg::*;

    data_req_t  req;
    logic       req_ready;
    data_resp_t resp;

    clocking master_drv_cb @(posedge clk);
        default input #1step output #1ns;
        input  req_ready;
        output req;
        input  resp;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1step;
        input req;
        input req_ready;
        input resp;
    endclocking

    modport master_drv (
        clocking master_drv_cb,
        input    rst_n
    );

    modport monitor (
        clocking mon_cb,
        input    rst_n
    );

    // 当前已加入 reset、X/Z 和 backpressure payload stable 等基础断言。
    // 第 10 章再补 single outstanding/no orphan response 等状态型断言。
endinterface

`default_nettype wire
```

注意：

- driver 通过 `master_drv_cb` 驱动 request、采样 ready/response；monitor 通过 `mon_cb` 被动采样，后续 class 不再直接使用裸 `posedge/negedge` 访问 bus 信号。
- `input #1step` 在时钟沿前采样稳定值，`output #1ns` 在时钟沿后驱动 request，明确避开 DUT 与 testbench 的采样/驱动 race。
- 当前 UVM 环境只实现 active master，DUT 仍通过普通 module 端口连接，因此不需要 slave modport。保留的 slave clocking block 只作为未来 slave BFM 占位，不参与当前环境。
- `drive_idle()` 属于 active driver 的行为，放在 `simple_bus_driver` 内，不放在 protocol interface 或 top 中。
- `req_ready` 不是 request payload，因此独立放在 interface 中。

### 2.2 更新 filelist 顺序 `已完成`

修改：

```text
uvm/v6_0/data_subsystem/sim/filelist.f
```

把 interface 放在 package 前：

```text
../dut/rtl/common/core_pkg.sv
../dut/rtl/common/soc_pkg.sv
../dut/rtl/common/data_bus_pkg.sv

../tb/simple_bus_if.sv
../tb/pkg/data_subsystem_pkg.sv
../tb/top/tb_data_subsystem_uvm_top.sv
```

原因：后续 package 里的 driver/monitor 会声明对应 modport 类型的 virtual interface，所以 interface 类型要先被编译。

### 2.3 UVM top 例化 interface `已完成`

修改：

```text
uvm/v6_0/data_subsystem/tb/top/tb_data_subsystem_uvm_top.sv
```

在 clock/reset 后增加：

```systemverilog
simple_bus_if simple_bus_vif (
    .clk   (clk),
    .rst_n (rst_n)
);
```

本节不从 top 驱动 request，也暂时不设置 `uvm_config_db`；第 5 章由 driver 实现 idle 驱动，第 7 章接 driver/monitor 时再设置 virtual interface。

当前 interface 已包含基础断言，但第 8 章接入 DUT 前 `req_ready/resp` 还没有真实驱动。因此这些断言应受 `ASSERT_ON` 控制，本阶段保持未定义；第 10 章接入状态型断言后再由 VCS 编译选项统一打开。

### 2.4 验证节点 `已完成`

本章完成标准：

- VCS 能编译 `simple_bus_if.sv`。
- `data_subsystem_base_test` 仍能运行。
- DUT 尚未接入时不启用 `ASSERT_ON`，不检查悬空的 slave 输出。
- 没有真实 bus transaction。

## 3. transaction item `已完成`

目标：定义一笔 simple data bus transaction 的 UVM item。

### 3.1 新增 item 文件 `已完成`

新增：

```text
uvm/v6_0/data_subsystem/tb/simple_bus_item.svh
```

建议骨架：

```systemverilog
class simple_bus_item extends uvm_sequence_item;
    rand bit                        write;
    rand logic [core_pkg::XLEN-1:0] addr;
    rand logic [core_pkg::XLEN-1:0] wdata;
    rand logic [3:0]                be;
    rand int unsigned               idle_cycles;

    logic [core_pkg::XLEN-1:0]      rdata;
    bit                             error;
    int unsigned                    resp_delay;

    `uvm_object_utils_begin(simple_bus_item)
        `uvm_field_int(write,      UVM_ALL_ON)
        `uvm_field_int(addr,       UVM_ALL_ON)
        `uvm_field_int(wdata,      UVM_ALL_ON)
        `uvm_field_int(be,         UVM_ALL_ON)
        `uvm_field_int(idle_cycles, UVM_ALL_ON)
        `uvm_field_int(rdata,      UVM_ALL_ON)
        `uvm_field_int(error,      UVM_ALL_ON)
        `uvm_field_int(resp_delay, UVM_ALL_ON)
    `uvm_object_utils_end

    constraint c_nonzero_be {
        be != 4'b0000;
    }

    constraint c_idle_cycles {
        idle_cycles inside {[0:15]};
    }

    function new(string name = "simple_bus_item");
        super.new(name);
    endfunction

    function bit is_read();
        return !write;
    endfunction

    function bit is_write();
        return write;
    endfunction

    function soc_pkg::target_e decode_target();
        if ((addr >= core_pkg::DMEM_BASE) &&
            (addr <  core_pkg::DMEM_BASE + core_pkg::DMEM_SIZE_BYTES)) begin
            return soc_pkg::TARGET_DMEM;
        end
        if ((addr >= soc_pkg::GPIO0_BASE) &&
            (addr <  soc_pkg::GPIO0_BASE + soc_pkg::GPIO0_SIZE_BYTES)) begin
            return soc_pkg::TARGET_GPIO0;
        end
        if ((addr >= soc_pkg::UART0_BASE) &&
            (addr <  soc_pkg::UART0_BASE + soc_pkg::UART0_SIZE_BYTES)) begin
            return soc_pkg::TARGET_UART0;
        end
        if ((addr >= soc_pkg::TIMER0_BASE) &&
            (addr <  soc_pkg::TIMER0_BASE + soc_pkg::TIMER0_SIZE_BYTES)) begin
            return soc_pkg::TARGET_TIMER0;
        end
        return soc_pkg::TARGET_UNDEFINED;
    endfunction

    function string target_name();
        case (decode_target())
            soc_pkg::TARGET_DMEM:      return "DMEM";
            soc_pkg::TARGET_GPIO0:     return "GPIO0";
            soc_pkg::TARGET_UART0:     return "UART0";
            soc_pkg::TARGET_TIMER0:    return "TIMER0";
            default:                   return "UNDEFINED";
        endcase
    endfunction

    function string convert2string();
        return $sformatf("write=%0d addr=0x%08x target=%s be=0x%0x wdata=0x%08x idle=%0d rdata=0x%08x error=%0d resp_delay=%0d",
                         write, addr, target_name(), be, wdata, idle_cycles,
                         rdata, error, resp_delay);
    endfunction
endclass
```

注意：

- 字段宽度使用 `core_pkg::XLEN`，避免后续 XLEN 变化时到处改。
- 第一版只需要 `be != 0`，更细的 strobe 合法性放到后续 byte enable 测试。
- `simple_bus_item` 只描述总线 transaction，不携带 CPU access size、MMIO 寄存器属性或地址分布策略。因此 item 只保留 `be != 0` 等协议级最小约束；`addr` 与 `be` 的 CPU 关联、target 选择和 offset 合法性由后续专属 sequence 施加。除非 simple bus 协议本身新增字段，否则不新增 item 子类。
- `idle_cycles` 在非首笔时表示上一笔 response 完成后、发起本笔 request 前额外保持 request idle 的完整拍数；首笔非零值表示 reset 释放后的 initial idle。sequence 决定该值，driver 只负责执行，不能自行随机。
- sequence 不在相邻 item 之间另外等待 bus clock；所有有意的 request gap 都通过 `idle_cycles` 表达，保证 stimulus 可打印、可复现。
- 第一版把随机范围限制为 `0..15`，避免无约束的 32-bit 随机值把仿真拖入超长等待；定向 sequence 仍可在不调用 randomize 时直接设置其它合理值。
- `idle_cycles` 当前只作为 sequence/driver stimulus 字段，monitor 不重建或比较该值。后续若需要验证 driver 的 gap 执行，使用独立的测试平台自检；该检查从 warm-up 后的 transaction 开始，不把 reset 释放和 driver 启动调度计入。
- target 名称由地址和当前 v6.0 地址图推导，不作为 sequence 随机字段，便于 monitor、timeout 和 log 使用统一口径。
- `resp_delay` 由 monitor 独立观测；driver 也回填原始 sequence item，供定向 dynamic-delay sequence 在 `finish_item()` 返回后自检。

### 3.2 接入 package `已完成`

修改：

```text
uvm/v6_0/data_subsystem/tb/pkg/data_subsystem_pkg.sv
```

include 顺序改为：

```systemverilog
`include "simple_bus_item.svh"
`include "data_subsystem_base_test.svh"
```

### 3.3 在 base test 中临时打印 item `已完成`

临时修改 `data_subsystem_base_test.run_phase`：

```systemverilog
simple_bus_item tr;

phase.raise_objection(this);
tr = simple_bus_item::type_id::create("tr");
tr.write = 1'b1;
tr.addr  = core_pkg::DMEM_BASE + 32'h40;
tr.wdata = 32'h1234_5678;
tr.be    = 4'hf;
tr.idle_cycles = 0;
`uvm_info(get_type_name(), tr.convert2string(), UVM_LOW)
#100ns;
phase.drop_objection(this);
```

本临时代码只用于确认 item/package 编译和打印正常；第 7 章引入 env 后可以删掉。

### 3.4 验证节点 `已完成`

本章完成标准：

- VCS 能编译 item。
- base test 仍能运行。
- log 中能看到 item 字段打印。

## 4. sequencer 和最小 sequence `已完成`

目标：让 UVM 能生成一笔或多笔 simple bus transaction。

### 4.1 新增 sequencer 文件 `已完成`

新增：

```text
uvm/v6_0/data_subsystem/tb/simple_bus_sequencer.svh
```

建议骨架：

```systemverilog
class simple_bus_sequencer extends uvm_sequencer #(simple_bus_item);
    `uvm_component_utils(simple_bus_sequencer)

    function new(string name = "simple_bus_sequencer", uvm_component parent = null);
        super.new(name, parent);
    endfunction
endclass
```

### 4.2 新增 smoke sequence 文件 `已完成`

新增：

```text
uvm/v6_0/data_subsystem/tb/simple_bus_smoke_seq.svh
```

建议骨架：

```systemverilog
class simple_bus_smoke_seq extends uvm_sequence #(simple_bus_item);
    `uvm_object_utils(simple_bus_smoke_seq)

    function new(string name = "simple_bus_smoke_seq");
        super.new(name);
    endfunction

    task body();
        simple_bus_item tr;

        send_write(core_pkg::DMEM_BASE + 32'h0000_0040, 32'h1122_3344);
        send_read (core_pkg::DMEM_BASE + 32'h0000_0040);
        send_write(core_pkg::DMEM_BASE + 32'h0000_0044, 32'ha5a5_5a5a);
        send_read (core_pkg::DMEM_BASE + 32'h0000_0044);
    endtask

    task automatic send_write(logic [core_pkg::XLEN-1:0] addr,
                              logic [core_pkg::XLEN-1:0] data);
        simple_bus_item tr;

        tr = simple_bus_item::type_id::create("write_tr");
        start_item(tr);
        tr.write = 1'b1;
        tr.addr  = addr;
        tr.wdata = data;
        tr.be    = 4'hf;
        tr.idle_cycles = 0;
        finish_item(tr);
    endtask

    task automatic send_read(logic [core_pkg::XLEN-1:0] addr);
        simple_bus_item tr;

        tr = simple_bus_item::type_id::create("read_tr");
        start_item(tr);
        tr.write = 1'b0;
        tr.addr  = addr;
        tr.wdata = '0;
        tr.be    = 4'hf;
        tr.idle_cycles = 0;
        finish_item(tr);
    endtask
endclass
```

注意：

- sequence 只负责产生“想访问什么”，不直接碰 DUT 信号。
- 基础 smoke 显式设置 `idle_cycles=0`，保持最小请求间隔；定向和随机 idle gap 由后续独立 sequence 覆盖。
- read 的 `be` 当前填 `4'hf` 只是为了字段完整；DUT 读路径主要看 `write=0` 和 addr。

### 4.3 接入 package `已完成`

修改 `data_subsystem_pkg.sv`：

```systemverilog
`include "simple_bus_item.svh"
`include "simple_bus_sequencer.svh"
`include "simple_bus_smoke_seq.svh"
`include "data_subsystem_base_test.svh"
```

### 4.4 base test 临时启动 sequence `已完成`

在没有 driver 前，不建议真的启动 sequence，因为 sequence 会等 driver 取 item。

本章只要求能编译 sequencer/sequence。若要临时测试 sequence 创建，可以只做：

```systemverilog
simple_bus_smoke_seq seq;
seq = simple_bus_smoke_seq::type_id::create("seq");
`uvm_info(get_type_name(), "smoke sequence object created", UVM_LOW)
```

### 4.5 验证节点 `已完成`

本章完成标准：

- VCS 能编译 sequencer 和 sequence。
- base test 仍能运行。
- 暂时不要求 transaction 被 driver 消费。

## 5. driver `已完成`

目标：实现一个能按 simple data bus 协议发 request、等待 ready、等待 response 的 UVM driver。

### 5.1 新增 driver 文件 `已完成`

新增：

```text
uvm/v6_0/data_subsystem/tb/simple_bus_driver.svh
```

建议骨架：

```systemverilog
class simple_bus_driver extends uvm_driver #(simple_bus_item);
    `uvm_component_utils(simple_bus_driver)

    virtual simple_bus_if.master_drv vif;
    localparam int unsigned MAX_TRANSACTION_WAIT_CYCLES = 256;

    function new(string name = "simple_bus_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual simple_bus_if.master_drv)::get(this, "", "vif", vif)) begin
            `uvm_fatal(get_type_name(), "failed to get master driver virtual interface")
        end
    endfunction

    task run_phase(uvm_phase phase);
        simple_bus_item tr;

        drive_idle();
        wait (vif.rst_n === 1'b1);
        @(vif.master_drv_cb);

        forever begin
            seq_item_port.get_next_item(tr);
            drive_one(tr);
            seq_item_port.item_done();
        end
    endtask

    task automatic drive_idle();
        vif.master_drv_cb.req <= '0;
    endtask

    task automatic drive_one(simple_bus_item tr);
        bit accepted;
        bit got_resp;
        int unsigned wait_cycles;

        `uvm_info(get_type_name(), {"drive ", tr.convert2string()}, UVM_MEDIUM)

        // 上一笔 response 完成后，按 item 要求额外保持 request idle。
        repeat (tr.idle_cycles) begin
            @(vif.master_drv_cb);
        end

        // request 由 clocking block 在采样沿后按 output skew 驱动。
        vif.master_drv_cb.req.valid <= 1'b1;
        vif.master_drv_cb.req.write <= tr.write;
        vif.master_drv_cb.req.be    <= tr.be;
        vif.master_drv_cb.req.addr  <= tr.addr;
        vif.master_drv_cb.req.wdata <= tr.wdata;

        accepted = 1'b0;
        got_resp = 1'b0;
        wait_cycles = 0;
        tr.resp_delay = 0;

        while (!accepted) begin
            @(vif.master_drv_cb);
            accepted = vif.master_drv_cb.req_ready;
            got_resp = vif.master_drv_cb.resp.valid;
            wait_cycles++;
            if (!accepted && wait_cycles >= MAX_TRANSACTION_WAIT_CYCLES) begin
                `uvm_fatal(get_type_name(),
                    $sformatf("timeout after %0d cycles waiting for request acceptance: %s",
                              wait_cycles, tr.convert2string()))
            end
        end

        // accepted 已在当前 clocking event 被采样；随后按 output skew 撤销 request。
        drive_idle();

        if (!got_resp) begin
            wait_cycles = 0;
            do begin
                @(vif.master_drv_cb);
                got_resp = vif.master_drv_cb.resp.valid;
                wait_cycles++;
                tr.resp_delay++;
                if (!got_resp && wait_cycles >= MAX_TRANSACTION_WAIT_CYCLES) begin
                    `uvm_fatal(get_type_name(),
                        $sformatf("timeout after %0d cycles waiting for response: %s",
                                  wait_cycles, tr.convert2string()))
                end
            end while (!got_resp);
        end

        tr.rdata = vif.master_drv_cb.resp.rdata;
        tr.error = vif.master_drv_cb.resp.error;
        `uvm_info(get_type_name(), {"done  ", tr.convert2string()}, UVM_MEDIUM)
    endtask
endclass
```

注意：

- 当前 simple bus 是 single outstanding，driver 必须等 response 后再取下一笔 item。
- `drive_idle()` 由 driver 独占，run phase 开始时先初始化 request，accepted 后再撤销 request。
- `idle_cycles` 是 sequence 生成的 master stimulus。driver 在取到本笔 item 后等待对应数量的完整 clocking event，再驱动 request；`idle_cycles=0` 保持现有最小时序，不额外插入空拍。
- driver 不随机 idle 间隔，否则 sequence 无法描述和复现完整 stimulus。
- driver 只通过 `master_drv_cb` 驱动/采样 bus，不再混用裸 signal 和 `posedge/negedge`，否则 clocking block 的 race 隔离会失效。
- 0 wait-state 时，accepted 和 response 可能在同一个 clocking event 被采样到。
- `MAX_TRANSACTION_WAIT_CYCLES` 必须大于 test 允许配置的最大 target delay，并留出少量调度裕量；当前 delay 输入为 7 bit，第一版取 256 拍。
- driver 回填 item 只是方便 sequence/debug；最终检查以 monitor/scoreboard 为准。

### 5.2 接入 package `已完成`

修改 `data_subsystem_pkg.sv`：

```systemverilog
`include "simple_bus_item.svh"
`include "simple_bus_sequencer.svh"
`include "simple_bus_smoke_seq.svh"
`include "simple_bus_driver.svh"
`include "data_subsystem_base_test.svh"
```

### 5.3 验证节点 `已完成`

本章完成标准：

- driver 可以编译。
- 如果后续 env 没有设置 vif，driver 应报清楚 `uvm_fatal`。
- 还未接 agent/env 前，不要求产生真实 transaction。

## 6. monitor `已完成`

目标：实现被动 monitor，把 DUT 引脚上真实发生的 request/response 重建成 transaction。

### 6.1 新增 monitor 文件 `已完成`

新增：

```text
uvm/v6_0/data_subsystem/tb/simple_bus_monitor.svh
```

建议骨架：

```systemverilog
class simple_bus_monitor extends uvm_component;
    `uvm_component_utils(simple_bus_monitor)

    virtual simple_bus_if.monitor vif;
    uvm_analysis_port #(simple_bus_item) item_ap;

    function new(string name = "simple_bus_monitor", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        item_ap = new("item_ap", this);
        if (!uvm_config_db #(virtual simple_bus_if.monitor)::get(this, "", "vif", vif)) begin
            `uvm_fatal(get_type_name(), "failed to get monitor virtual interface")
        end
    endfunction

    task run_phase(uvm_phase phase);
        simple_bus_item pending_tr;
        bit pending;
        int unsigned accept_cycle;
        int unsigned cycle_cnt;

        pending      = 1'b0;
        accept_cycle = 0;
        cycle_cnt    = 0;

        forever begin
            @(vif.mon_cb);
            cycle_cnt++;

            if (!vif.rst_n) begin
                pending        = 1'b0;
                continue;
            end

            // request accepted
            if (vif.mon_cb.req.valid && vif.mon_cb.req_ready) begin
                if (pending) begin
                    `uvm_error(get_type_name(), "second request accepted before previous response")
                end

                pending_tr = simple_bus_item::type_id::create("pending_tr", this);
                pending_tr.write = vif.mon_cb.req.write;
                pending_tr.addr  = vif.mon_cb.req.addr;
                pending_tr.wdata = vif.mon_cb.req.wdata;
                pending_tr.be    = vif.mon_cb.req.be;

                pending      = 1'b1;
                accept_cycle = cycle_cnt;
            end

            // response valid
            if (vif.mon_cb.resp.valid) begin
                if (!pending) begin
                    `uvm_error(get_type_name(), "orphan response without pending request")
                end
                else begin
                    pending_tr.rdata      = vif.mon_cb.resp.rdata;
                    pending_tr.error      = vif.mon_cb.resp.error;
                    pending_tr.resp_delay = cycle_cnt - accept_cycle;
                    item_ap.write(pending_tr);
                    `uvm_info(get_type_name(), {"mon   ", pending_tr.convert2string()}, UVM_MEDIUM)
                    pending = 1'b0;
                end
            end
        end
    endtask
endclass
```

注意：

- monitor 必须只读 interface，不能驱动任何 bus 信号。
- monitor 只通过 `mon_cb` 采样 request/response，采样时序与 driver clocking block 保持同一口径。
- 同拍 accepted+response 时，本代码先创建 `pending_tr`，再填 response，因此能输出完整 item。
- monitor 当前不统计或回填 `idle_cycles`；它只重建 DUT 引脚上已 accepted 的 request 和对应 response。driver idle-gap 的实际执行检查作为后续可选测试平台自检，不进入通用 scoreboard。
- monitor 输出的是“DUT 引脚真实发生的 transaction”，scoreboard 后续只看 monitor，不直接信任 driver。

### 6.2 接入 package `已完成`

修改 `data_subsystem_pkg.sv`：

```systemverilog
`include "simple_bus_item.svh"
`include "simple_bus_sequencer.svh"
`include "simple_bus_smoke_seq.svh"
`include "simple_bus_driver.svh"
`include "simple_bus_monitor.svh"
`include "data_subsystem_base_test.svh"
```

### 6.3 验证节点 `已完成`

本章完成标准：

- monitor 可以编译。
- monitor 不驱动任何 DUT 信号。
- 后续接入 DUT 后，monitor 输出的 item 应以真实引脚为准，而不是 driver item 为准。

## 7. agent 和 env `已完成`

目标：把 sequencer、driver、monitor 封装成 agent，并把 agent 接入 env。

### 7.1 新增 agent 文件 `已完成`

新增：

```text
uvm/v6_0/data_subsystem/tb/simple_bus_agent.svh
```

建议骨架：

```systemverilog
class simple_bus_agent extends uvm_agent;
    `uvm_component_utils(simple_bus_agent)

    simple_bus_sequencer sequencer;
    simple_bus_driver    driver;
    simple_bus_monitor   monitor;

    function new(string name = "simple_bus_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        sequencer = simple_bus_sequencer::type_id::create("sequencer", this);
        driver    = simple_bus_driver   ::type_id::create("driver",    this);
        monitor   = simple_bus_monitor  ::type_id::create("monitor",   this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction
endclass
```

第一版只支持 active agent；后续若需要 passive agent 再加 `is_active` 配置。

### 7.2 新增 env 文件 `已完成`

新增：

```text
uvm/v6_0/data_subsystem/tb/data_subsystem_env.svh
```

建议骨架：

```systemverilog
class data_subsystem_env extends uvm_env;
    `uvm_component_utils(data_subsystem_env)

    simple_bus_agent agent;

    function new(string name = "data_subsystem_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agent = simple_bus_agent::type_id::create("agent", this);
    endfunction
endclass
```

第 9 章会在 env 中增加 scoreboard，并连接：

```systemverilog
agent.monitor.item_ap.connect(scoreboard.item_export);
```

### 7.3 修改 base test 例化 env `已完成`

修改：

```text
uvm/v6_0/data_subsystem/tb/tests/data_subsystem_base_test.svh
```

建议更新为：

```systemverilog
class data_subsystem_base_test extends uvm_test;
    `uvm_component_utils(data_subsystem_base_test)

    data_subsystem_env env;

    function new(string name = "data_subsystem_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = data_subsystem_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info(get_type_name(), "base test created env only", UVM_LOW)
        #100ns;
        phase.drop_objection(this);
    endtask
endclass
```

### 7.4 修改 top 设置 virtual interface `已完成`

修改：

```text
uvm/v6_0/data_subsystem/tb/top/tb_data_subsystem_uvm_top.sv
```

在 `run_test()` 前分别设置 driver 和 monitor 使用的 virtual interface。两者使用不同 modport 类型，因此 `set/get` 的参数化类型必须完全一致：

```systemverilog
initial begin
    uvm_config_db #(virtual simple_bus_if.master_drv)::set(
        null,
        "uvm_test_top.env.agent.driver",
        "vif",
        simple_bus_vif
    );
    uvm_config_db #(virtual simple_bus_if.monitor)::set(
        null,
        "uvm_test_top.env.agent.monitor",
        "vif",
        simple_bus_vif
    );
    run_test();
end
```

如果 driver 或 monitor 报拿不到 vif，先把路径放宽为：

```systemverilog
uvm_config_db #(virtual simple_bus_if.master_drv)::set(null, "*", "vif", simple_bus_vif);
uvm_config_db #(virtual simple_bus_if.monitor)::set(null, "*", "vif", simple_bus_vif);
```

跑通后再收紧路径。即使 field name 都使用 `"vif"`，两个不同的参数化类型也不会相互替代；driver/monitor 的 `config_db::get()` 必须分别使用对应 modport 类型。

### 7.5 接入 package `已完成`

修改 `data_subsystem_pkg.sv` include 顺序：

```systemverilog
`include "simple_bus_item.svh"
`include "simple_bus_sequencer.svh"
`include "simple_bus_smoke_seq.svh"
`include "simple_bus_driver.svh"
`include "simple_bus_monitor.svh"
`include "simple_bus_agent.svh"
`include "data_subsystem_env.svh"
`include "data_subsystem_base_test.svh"
```

### 7.6 验证节点 `已完成`

本章完成标准：

- base test 能创建 env/agent/driver/monitor。
- driver/monitor 都能拿到 vif。
- 因为还没有 DUT 和 sequence，允许没有真实 bus transaction。

## 8. DUT harness 和 DMEM smoke `已完成`

目标：把 `data_subsystem` 接进 UVM top，用 UVM driver 访问 DMEM，完成第一条真正的 UVM smoke。

### 8.1 更新 filelist，接入归档 DUT RTL `已完成`

修改：

```text
uvm/v6_0/data_subsystem/sim/filelist.f
```

建议顺序：

```text
+incdir+../tb/seq
+incdir+../tb/tests

../dut/rtl/common/core_pkg.sv
../dut/rtl/common/soc_pkg.sv
../dut/rtl/common/data_bus_pkg.sv

../dut/rtl/periph/mmio_gpio.sv
../dut/rtl/periph/mmio_uart.sv
../dut/rtl/periph/mmio_timer32.sv
../dut/rtl/mem/simple_ram.sv
../dut/rtl/soc/data_subsystem.sv

../tb/interfaces/simple_bus_if.sv
../tb/interfaces/data_subsystem_cfg_if.sv
../tb/pkg/data_subsystem_pkg.sv
../tb/top/tb_data_subsystem_uvm_top.sv
```

`simple_bus_if` 是通用 bus 协议 interface；`data_subsystem_cfg_if` 只承载 v6.0 DUT 的 per-target delay 配置。两者分开，避免 simple bus agent 绑定 `data_subsystem` 的验证专用端口。

### 8.2 新增 `data_subsystem_cfg_if` `已完成`

新增：

```text
uvm/v6_0/data_subsystem/tb/interfaces/data_subsystem_cfg_if.sv
```

建议骨架：

```systemverilog
`default_nettype none

interface data_subsystem_cfg_if (
    input logic clk_i,
    input logic rst_n_i
);
    import soc_pkg::*;

    logic [6:0] dmem_resp_delay_cycles;
    logic [6:0] gpio0_resp_delay_cycles;
    logic [6:0] uart0_resp_delay_cycles;
    logic [6:0] timer0_resp_delay_cycles;

    task automatic set_target_delay(
        soc_pkg::target_e target_i,
        logic [6:0]       delay_i
    );
        case (target_i)
            TARGET_DMEM:   dmem_resp_delay_cycles   = delay_i;
            TARGET_GPIO0:  gpio0_resp_delay_cycles  = delay_i;
            TARGET_UART0:  uart0_resp_delay_cycles  = delay_i;
            TARGET_TIMER0: timer0_resp_delay_cycles = delay_i;
            default: ;
        endcase
    endtask
endinterface

`default_nettype wire
```

本 interface 不属于 simple bus 协议。调用者必须保证只在没有 outstanding transaction 时调用 `set_target_delay()`，并让配置在下一笔 request accepted 前稳定。该 task 只立即更新配置，不在内部等待 `posedge/negedge`；调用方在上一笔 `finish_item()` 返回后设置新值，再立即交付下一笔 item，配置会在下一次 request accepted 前保持稳定，同时不会引入隐含 idle 拍。第一版固定 smoke 不调用该 task，只使用 top 设置的默认值。

### 8.3 UVM top 增加 DUT 连接信号和配置 interface `已完成`

在 `tb/top/tb_data_subsystem_uvm_top.sv` 中声明：

```systemverilog
logic                      dmem_we;
logic [3:0]                dmem_be;
logic [core_pkg::XLEN-1:0] dmem_addr;
logic [core_pkg::XLEN-1:0] dmem_wdata;
logic [core_pkg::XLEN-1:0] dmem_rdata;

logic [31:0] gpio0_in;
logic [31:0] gpio0_out;
logic [31:0] gpio0_oe;

logic       uart0_tx_valid;
logic [7:0] uart0_tx_data;
logic       uart0_rx_valid;
logic [7:0] uart0_rx_data;

logic gpio0_irq;
logic uart0_irq;
logic timer0_irq;

logic dmem_access;
logic mmio_access;
```

例化 DUT 专用配置 interface：

```systemverilog
data_subsystem_cfg_if data_subsystem_cfg_vif (
    .clk_i   (clk),
    .rst_n_i (rst_n)
);
```

给外部输入和 delay 配置默认值：

```systemverilog
initial begin
    gpio0_in       = 32'h0;
    uart0_rx_valid = 1'b0;
    uart0_rx_data  = 8'h00;

    data_subsystem_cfg_vif.dmem_resp_delay_cycles   = 7'd0;
    data_subsystem_cfg_vif.gpio0_resp_delay_cycles  = 7'd0;
    data_subsystem_cfg_vif.uart0_resp_delay_cycles  = 7'd0;
    data_subsystem_cfg_vif.timer0_resp_delay_cycles = 7'd0;
end
```

在调用 `run_test()` 的同一个 initial block 中，把配置 interface 句柄交给 test；固定 smoke 可以不读取它：

```systemverilog
uvm_config_db #(virtual data_subsystem_cfg_if)::set(
    null,
    "uvm_test_top",
    "cfg_vif",
    data_subsystem_cfg_vif
);
```

### 8.4 UVM top 例化 `data_subsystem` `已完成`

建议骨架：

```systemverilog
data_subsystem u_data_subsystem (
    .clk_i       (clk),
    .rst_n_i     (rst_n),

    .core_req_ready_o (simple_bus_vif.req_ready),
    .core_req_i       (simple_bus_vif.req),
    .core_resp_o      (simple_bus_vif.resp),

    .dmem_we_o    (dmem_we),
    .dmem_be_o    (dmem_be),
    .dmem_addr_o  (dmem_addr),
    .dmem_wdata_o (dmem_wdata),
    .dmem_rdata_i (dmem_rdata),

    .gpio0_in_i  (gpio0_in),
    .gpio0_out_o (gpio0_out),
    .gpio0_oe_o  (gpio0_oe),

    .uart0_tx_valid_o (uart0_tx_valid),
    .uart0_tx_data_o  (uart0_tx_data),
    .uart0_rx_valid_i (uart0_rx_valid),
    .uart0_rx_data_i  (uart0_rx_data),

    .gpio0_irq_o  (gpio0_irq),
    .uart0_irq_o  (uart0_irq),
    .timer0_irq_o (timer0_irq),

    .dmem_resp_delay_cycles_i
        (data_subsystem_cfg_vif.dmem_resp_delay_cycles),
    .gpio0_resp_delay_cycles_i
        (data_subsystem_cfg_vif.gpio0_resp_delay_cycles),
    .uart0_resp_delay_cycles_i
        (data_subsystem_cfg_vif.uart0_resp_delay_cycles),
    .timer0_resp_delay_cycles_i
        (data_subsystem_cfg_vif.timer0_resp_delay_cycles),

    .dmem_access_o (dmem_access),
    .mmio_access_o (mmio_access)
);
```

### 8.5 UVM top 例化 `simple_ram` `已完成`

建议骨架：

```systemverilog
simple_ram u_simple_ram (
    .clk_i   (clk),
    .we_i    (dmem_we),
    .be_i    (dmem_be),
    .addr_i  (dmem_addr),
    .wdata_i (dmem_wdata),
    .rdata_o (dmem_rdata)
);
```

第一版不需要加 `+dmem=<path>`，RAM 初始值默认 0。

### 8.6 新增 smoke test 文件 `已完成`

新增：

```text
uvm/v6_0/data_subsystem/tb/data_subsystem_simple_bus_smoke_test.svh
```

建议骨架：

```systemverilog
class data_subsystem_simple_bus_smoke_test extends data_subsystem_base_test;
    `uvm_component_utils(data_subsystem_simple_bus_smoke_test)

    function new(string name = "data_subsystem_simple_bus_smoke_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        simple_bus_smoke_seq seq;

        phase.raise_objection(this);
        seq = simple_bus_smoke_seq::type_id::create("seq");
        seq.start(env.agent.sequencer);
        phase.drop_objection(this);
    endtask
endclass
```

### 8.7 接入 package `已完成`

修改 `data_subsystem_pkg.sv` include 顺序：

```systemverilog
`include "simple_bus_item.svh"
`include "simple_bus_sequencer.svh"
`include "simple_bus_smoke_seq.svh"
`include "simple_bus_driver.svh"
`include "simple_bus_monitor.svh"
`include "simple_bus_agent.svh"
`include "data_subsystem_env.svh"
`include "data_subsystem_base_test.svh"
`include "data_subsystem_simple_bus_smoke_test.svh"
```

### 8.8 更新 run_all `已完成`

`uvm/v6_0/data_subsystem/sim/run_all.sh` 增加：

```bash
./run_test.sh data_subsystem_simple_bus_smoke_test 1
```

### 8.9 验证节点 `已完成`

本章完成标准：

- VCS 能跑 `data_subsystem_simple_bus_smoke_test`。
- driver 发出 DMEM write/read。
- monitor 能观察到 request/response。
- `data_subsystem_cfg_if` 默认值为 0，普通 smoke 保持 0 wait-state。
- 暂时允许不检查 read data，但 log 中要能看出事务发生。

## 9. 最小 scoreboard `已完成`

目标：让 UVM smoke 不只是“跑完”，而是能自动判断 DMEM 基本 read/write 是否正确。

### 9.1 新增 scoreboard 文件 `已完成`

新增：

```text
uvm/v6_0/data_subsystem/tb/simple_bus_scoreboard.svh
```

建议骨架：

```systemverilog
class simple_bus_scoreboard extends uvm_component;
    `uvm_component_utils(simple_bus_scoreboard)

    uvm_analysis_imp #(simple_bus_item, simple_bus_scoreboard) item_export;

    bit [31:0] ref_mem [logic [31:0]];
    bit        ref_valid [logic [31:0]];

    function new(string name = "simple_bus_scoreboard", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        item_export = new("item_export", this);
    endfunction

    function void write(simple_bus_item item);
        if (is_dmem_addr(item.addr)) begin
            check_dmem(item);
        end
        else begin
            `uvm_info(get_type_name(), {"skip non-DMEM item: ", item.convert2string()}, UVM_MEDIUM)
        end
    endfunction

    function bit is_dmem_addr(logic [31:0] addr);
        return (addr >= core_pkg::DMEM_BASE) &&
               (addr <  core_pkg::DMEM_BASE + core_pkg::DMEM_SIZE_BYTES);
    endfunction

    function logic [31:0] word_addr(logic [31:0] addr);
        return {addr[31:2], 2'b00};
    endfunction

    function void check_dmem(simple_bus_item item);
        logic [31:0] wa;

        wa = word_addr(item.addr);

        if (item.error) begin
            `uvm_error(get_type_name(), {"DMEM access returned error: ", item.convert2string()})
            return;
        end

        if (item.write) begin
            if (item.be != 4'hf) begin
                `uvm_error(get_type_name(), {"first scoreboard only supports word write: ", item.convert2string()})
                return;
            end

            ref_mem[wa]   = item.wdata;
            ref_valid[wa] = 1'b1;
        end
        else begin
            if (ref_valid.exists(wa) && ref_valid[wa]) begin
                if (item.rdata !== ref_mem[wa]) begin
                    `uvm_error(get_type_name(),
                        $sformatf("DMEM read mismatch addr=0x%08x expected=0x%08x actual=0x%08x",
                                  wa, ref_mem[wa], item.rdata))
                end
            end
        end
    endfunction
endclass
```

注意：

- 第一版只检查 word write/read，byte enable 后续单独扩。
- 未写过的地址先不检查初值，避免和 RAM 初始化策略耦合。
- 如果 VCS 对 `ref_valid.exists(wa)` 写法有类型报错，可把 key 类型统一成 `int unsigned` 或 `logic [31:0]` 后调整。

### 9.2 env 接入 scoreboard `已完成`

修改：

```text
uvm/v6_0/data_subsystem/tb/data_subsystem_env.svh
```

建议更新：

```systemverilog
class data_subsystem_env extends uvm_env;
    `uvm_component_utils(data_subsystem_env)

    simple_bus_agent      agent;
    simple_bus_scoreboard scoreboard;

    function new(string name = "data_subsystem_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agent      = simple_bus_agent     ::type_id::create("agent",      this);
        scoreboard = simple_bus_scoreboard::type_id::create("scoreboard", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        agent.monitor.item_ap.connect(scoreboard.item_export);
    endfunction
endclass
```

### 9.3 接入 package  `已完成`

修改 `data_subsystem_pkg.sv` include 顺序：

```systemverilog
`include "simple_bus_item.svh"
`include "simple_bus_sequencer.svh"
`include "simple_bus_smoke_seq.svh"
`include "simple_bus_driver.svh"
`include "simple_bus_monitor.svh"
`include "simple_bus_agent.svh"
`include "simple_bus_scoreboard.svh"
`include "data_subsystem_env.svh"
`include "data_subsystem_base_test.svh"
`include "data_subsystem_simple_bus_smoke_test.svh"
```

### 9.4 验证节点 `已完成`

本章完成标准：

- `data_subsystem_simple_bus_smoke_test` 能自动 PASS/FAIL。
- 错误时 scoreboard 打印 addr、expected、actual。
- DMEM 基本 word write/read 通过。

## 10. 第一批状态型 SVA `已完成`

目标：把 simple bus 的基础协议断言和状态型断言统一收敛到 `tb/sva`，在 interface
作用域检查最少量、价值最高的 single-outstanding 协议不变量。

### 10.1 新增 SVA 目录和 assertion 文件 `已完成`

新增：

```text
uvm/v6_0/data_subsystem/tb/sva/simple_bus_sva.svh
```

`simple_bus_sva.svh` 不是独立 module，也不属于 `data_subsystem_pkg`。它是由
`simple_bus_if.sv` 在 interface 内部文本 include 的代码片段；预处理后其中的
property/assertion 与 interface 信号处于同一作用域，可以直接使用 `clk_i`、`rst_n_i`、
`req_i`、`req_ready_o` 和 `resp_o`。`.svh` 不作为独立源文件加入 filelist。

本文件统一保存当前已在 interface 中实现的基础断言，以及本章新增的状态型断言：

- reset quiet。
- request/response 控制和 payload 的 X/Z 检查。
- backpressure 时 request payload stable。
- single outstanding：存在未完成 request 时不能再接受第二笔 request。
- no orphan response：每个 response 都必须对应 outstanding request 或本拍刚 accepted 的
  0 wait-state request。

所有 assertion 和 assertion state 均由本文件中的 `` `ifdef ASSERT_ON `` 包住，避免关闭
断言时留下状态逻辑。第一版不在这里加入具体 MMIO 寄存器、DMEM 数据值、delay 配置等功能
检查；这些分别属于 checker/scoreboard 的职责。

建议状态型部分的骨架：

```systemverilog
`ifdef ASSERT_ON
    logic assert_outstanding_q;
    wire  assert_accept_fire = req_i.valid && req_ready_o;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            assert_outstanding_q <= 1'b0;
        end
        else begin
            if (assert_accept_fire && !resp_o.valid) begin
                assert_outstanding_q <= 1'b1;
            end
            if (resp_o.valid) begin
                assert_outstanding_q <= 1'b0;
            end
        end
    end

    property p_no_second_accept_when_outstanding;
        @(posedge clk_i) disable iff (!rst_n_i)
            assert_outstanding_q |-> !assert_accept_fire;
    endproperty

    property p_no_orphan_response;
        @(posedge clk_i) disable iff (!rst_n_i)
            resp_o.valid |-> (assert_outstanding_q || assert_accept_fire);
    endproperty
`endif
```

实现时应根据 `data_subsystem` 的 0 wait-state 同拍 accept/response 语义，复核
`assert_outstanding_q` 的更新与两个 property 的采样口径；不要机械照抄骨架。

### 10.2 interface 接入并迁移基础断言 `已完成`

修改：

```text
uvm/v6_0/data_subsystem/tb/interfaces/simple_bus_if.sv
uvm/v6_0/data_subsystem/sim/filelist.f
```

在 `simple_bus_if.sv` 的 `endinterface` 前加入：

```systemverilog
`include "simple_bus_sva.svh"
```

并把当前 interface 内已有的 reset、X/Z、backpressure payload stable assertion 从
`simple_bus_if.sv` 迁移到 `simple_bus_sva.svh`，不复制保留两份。这样 interface 只保留
总线信号、clocking block、modport 和 assertion include，所有 simple bus SVA 统一维护。

`filelist.f` 增加：

```text
+incdir+../tb/sva
```

断言应放在 interface 内，而非 `tb_data_subsystem_uvm_top.sv`：它们描述的是可复用的 simple
bus 协议，使用 interface 作用域信号；top 只负责实例化 interface、DUT 和 testbench model。
未来若要检查 `data_subsystem` 内部实现状态，再在 `tb/sva` 新增独立 assertion module 和
bind 文件，本章不提前建立。

### 10.3 ASSERT_ON 编译开关 `无需改动`

`run_test.sh` 已支持通过 shell 环境变量控制 VCS 编译宏：

```bash
ASSERT_ON=1 uvm/v6_0/data_subsystem/sim/run_test.sh data_subsystem_simple_bus_smoke_test 1
```

该变量只对本条命令生效；脚本在 `ASSERT_ON=1` 时加入 `+define+ASSERT_ON`，并使用与未开启
断言不同的 build 目录，避免 VCS 增量编译复用错误配置。普通命令不设置该变量即关闭 assertion。

本章不改变这一脚本接口；实现后分别验证关闭和开启 assertion 的编译/仿真路径。

### 10.4 SVA、UVM 与 coverage 分层 `无需改动`

- SVA 只依赖 interface 的时钟、reset 和引脚级协议状态，不 import UVM package，也不读取
  sequence item、scoreboard 或 driver 的内部状态。
- UVM driver/monitor 继续通过 virtual interface 驱动/重建 transaction；scoreboard/checker
  通过 monitor analysis port 检查数据、error、delay 和外设功能语义。
- assertion failure 通过 `$error` 进入仿真日志，`run_test.sh` 的 `SIM_ERROR` 统计将其判为
  FAIL；UVM 不需要直接调用 assertion。
- 后续 functional coverage 放在 `tb/coverage`，作为由 env 创建、订阅 monitor analysis
  port 的 UVM subscriber/collector；它采集重建后的 transaction，不替代 SVA 或 scoreboard。
- 若需要 `cover property` 统计协议场景，则与 assertion 一同放在 `tb/sva`。它与 UVM
  functional coverage 是两类覆盖，不应重复计数或相互依赖。

coverage 的具体 collector 和第一批随机激励放在第 16 章：先稳定确定性 DMEM、wrapper
delay 和 driver execution 检查，再让 coverage 报告具有可解释的输入分布；不要求等 MMIO
和全部黄金模型完成才建立覆盖框架，但每个纳入 legal traffic/coverage 的场景必须已有明确
spec 和自动检查边界。

### 10.5 验证节点 `已完成`

本章完成标准：

- `data_subsystem_simple_bus_smoke_test` 在基础和状态型 SVA 同时打开时通过。
- assertion action block 使用清晰名称和 `[SVA]` 日志前缀；故障注入仅作为可选调试，不作为本章强制完成标准。
- 关闭 `ASSERT_ON` 时不编译 assertion 状态逻辑，普通 smoke 仍可运行。
- 不新增 UVM coverage collector；coverage 保持第 16 章实现。

## 11. bus item 与 observed transfer 分层 `已完成`

目标：先把“sequence/driver 计划执行的请求”和“monitor 从 interface 观察到的完整传输”
拆成两种类型，为 wrapper 配置 agent、独立 checker 和 coverage 建立清晰的数据来源。

### 11.1 明确两种对象的职责 `已完成`

`simple_bus_item` 继续作为 sequence 与 driver 之间的 command object，只表达 master 计划：

- `write/be/addr/wdata`：计划驱动的 request payload。
- `idle_cycles`：计划在本笔 request 前插入的完整空拍数。
- 不再作为 scoreboard/coverage 的输入。
- 不保存 monitor 观察结果；driver 等到 response 后调用 `item_done()` 即可。

新增：

~~~text
uvm/v6_0/data_subsystem/tb/transaction/simple_bus_transfer.svh
~~~

`simple_bus_transfer` 只由 monitor 创建，表达 interface 上实际完成的一笔 transaction：

- 实际 accepted request 的 `write/be/addr/wdata`。
- 实际 response 的 `rdata/error`。
- monitor 实测的 `observed_idle_cycles` 和 `observed_resp_delay`，与 item 中的计划字段明确区分。
- 可保留 `accept_cycle/response_cycle` 作为日志和 off-by-one 定位信息，但 checker 不依赖
  绝对仿真拍数。
- target 仍由实际地址推导，不作为独立随机字段。

monitor 不读取 sequence item，也不把“计划值”填入 transfer。计划值与观察值是否一致由后续
driver execution checker 配对检查，不能在一个对象中混合两个来源。

### 11.2 调整 driver 输出边界 `已完成`

`simple_bus_driver` 继续完成以下行为：

- 从 sequencer 取得 `simple_bus_item`。
- 按 `idle_cycles` 驱动 request。
- 等待 accepted request 和对应 response。
- response 完成后调用 `item_done()`，保证下一笔配置或 request 不会越过 outstanding 边界。

新增一个计划流 analysis port，例如：

~~~systemverilog
uvm_analysis_port #(simple_bus_item) planned_item_ap;
~~~

driver 在开始执行 item 前发布该 item 的 clone，不能直接广播后续仍可能被修改的原对象。该
analysis port 暂时可以无人订阅，第 15 章接入 driver execution checker。

driver 的调试日志应明确是 planned/completed item；它不再承担 scoreboard 使用的“真实总线
结果”来源。

### 11.3 monitor 改为生成 transfer `已完成`

修改 `simple_bus_monitor`：

- 内部 pending 对象类型改为 `simple_bus_transfer`。
- request accepted 时锁存实际 request payload 和 accept cycle。
- response 到达时填写实际 response、`observed_idle_cycles`、`observed_resp_delay`，然后通过
  `uvm_analysis_port #(simple_bus_transfer)` 广播。
- 0 wait-state 同拍 accept/response 必须仍能生成一笔完整 transfer。
- single outstanding/no orphan 的 monitor 防御性检查继续保留；协议 invariant 仍由 SVA
  作为独立检查路径。

### 11.4 scoreboard 和 env 切换到 transfer `已完成`

`simple_bus_scoreboard` 的 analysis imp 类型改为 `simple_bus_transfer`。DMEM 参考模型和
read/write 检查只依赖 monitor transfer，不再接收 driver item。

env 连接保持一对多：

~~~text
simple_bus_monitor.transfer_ap
    -> simple_bus_scoreboard.transfer_imp
    -> 后续 wrapper delay checker
    -> 后续 driver execution checker
    -> 后续 coverage
~~~

package include 顺序中，`simple_bus_transfer.svh` 必须在 monitor、scoreboard 和 checker
之前。

### 11.5 验证节点 `已完成`

- 普通 `data_subsystem_simple_bus_smoke_test` 继续通过。
- scoreboard 仍能检查两组 DMEM word write/read。
- driver 日志显示 planned item，monitor 日志显示 observed transfer，二者类型和文案不混用。
- monitor 的首笔 initial idle 口径和后续 transaction idle 口径保持 spec 当前定义。
- `ASSERT_ON=1` 时 SVA 不误报。

## 12. response-delay wrapper 配置 agent `已完成`

目标：把 v6.0 `data_subsystem` response-delay wrapper 的配置动作做成独立 active agent，
不让 test、simple bus item 或通用 bus driver 直接操作 DUT 专用配置 interface。

### 12.1 保留并收敛 wrapper 配置 interface `无需改动`

继续使用：

~~~text
uvm/v6_0/data_subsystem/tb/interfaces/wrapper_if.sv
~~~

其中的 `wrapper_if` 仍是 wrapper cfg driver 与 DUT 四组
`*_resp_delay_cycles_i` 之间的物理连接，保留：

- `rst_resp_delay()`：所有 target delay 恢复为 0。
- `set_target_resp_delay(target, delay_cycles)`：按 target 设置 delay。
- `clk_i/rst_n_i`：供 cfg driver 在 reset 期间施加默认值，并在 reset 释放后开始
  执行普通配置命令。

该 interface 不是 simple bus 协议的一部分，不进入 `simple_bus_item` 或
`simple_bus_transfer`。文件名和 interface 类型名是否进一步加入 wrapper 前缀，可在实现时
统一，但本阶段优先保持现有接口可用，避免无功能收益的重命名扩散。

top 只负责例化该 interface、连接 DUT 并通过 `uvm_config_db` 将 virtual interface 提供给
wrapper cfg driver；`rst_resp_delay()` 由 cfg driver 调用。test、virtual sequence 和 simple
bus driver 不直接取得该 vif。

### 12.2 新增 wrapper 配置 transaction 与 sequencer `已完成`

新增目录：

~~~text
uvm/v6_0/data_subsystem/tb/agent/wrapper
~~~

新增类：

wrapper_item.svh `已完成`
wrapper_sequence.svh `已完成`
wrapper_sequencer.svh `已完成`

`wrapper_item` 至少包含：

~~~systemverilog
rand soc_pkg::target_e target;
rand logic [6:0]       delay_cycles;
~~~

基础约束：

- target 只允许 DMEM/GPIO0/UART0/TIMER0；undefined target 不配置 wrapper。
- delay 范围与 RTL 的 7 bit 输入一致，即 0～127。
- 固定值、确定性序列和随机分布由派生 sequence/test 施加，item 只保留通用合法范围。

cfg sequence 负责构造并提交 cfg item，不直接访问 virtual interface。

### 12.3 新增 wrapper cfg driver 与 agent `已完成`

新增：

~~~text
wrapper_driver.svh
wrapper_agent.svh
~~~

cfg driver：

- 从 cfg sequencer 取得 cfg item。
- `run_phase` 开始时调用 `rst_resp_delay()`，在 reset 期间将所有 target delay 置为 0；随后
  等待 reset 释放。该 reset 默认动作不是普通 cfg item。
- reset 未释放时不从 sequencer 取得或执行普通 cfg item；reset 释放后才开始处理 sequence
  提交的配置命令。
- 对手动赋值绕过 random constraint 的 `delay_cycles` 做最终合法性检查：负数（包括
  `-1` 未初始化哨兵）报 `uvm_fatal`；大于 127 时报告 `uvm_warning` 并饱和为 127。
  调用 interface 和发布 `applied_cfg_ap` 时均使用规范化后的 clone，保证 checker 记录的 expected state 与实际施加给 DUT 的值一致。
- 调用 `wrapper_if.set_target_resp_delay()` 实际驱动配置。
- 完成配置后发布 cfg item 的 clone 到 `applied_cfg_ap`，再调用 `item_done()`。
- 不驱动 simple bus request，也不等待 bus response。

`applied_cfg_ap` 表示“cfg driver 已实际执行过的计划配置”，供后续 wrapper checker 建立
expected state。发布 clone 是为了防止 sequence 复用对象导致历史配置被修改。

第一版 cfg agent 只需 sequencer + driver，不强制建立 cfg monitor。该配置通道是 TB 到 DUT
的专用控制侧带，不是待验证的 request/response 协议；wrapper checker 会通过实际 response
delay 间接验证配置是否真正生效。

### 12.4 env/top/package 接入 `已完成`

env 新增：

~~~text
wrapper_agent wrapper_agent;
~~~

top 的 config_db 路径改为 wrapper cfg driver，例如：

~~~text
uvm_test_top.env.wrapper_agent.driver
~~~

package/filelist 按依赖顺序加入新目录和 class。普通 `data_subsystem_simple_bus_smoke_test` 不启动 cfg
sequence，继续使用 cfg driver 在 reset 期间初始化的 0 delay。

### 12.5 验证节点 `已完成`

- cfg item/sequence/sequencer/driver/agent 能编译并进入 UVM topology。
- wrapper cfg driver 能将四个 target 分别配置为确定值。
- 普通 smoke 不使用 cfg agent traffic 时仍保持 0 wait-state。
- simple bus driver、monitor、scoreboard 中不出现 `wrapper_if` 依赖。

## 13. virtual sequencer 与确定性 wrapper-delay 测试 `已完成`

目标：由 virtual sequence 协调 wrapper cfg agent 和 simple bus agent，保证每笔 delay 配置
先完成、随后才发对应 bus request，并且只在没有 outstanding transaction 时切换配置。

### 13.1 新增 virtual sequencer `已完成`

新增：

~~~text
uvm/v6_0/data_subsystem/tb/virtual/data_subsystem_virtual_sequencer.svh
~~~

virtual sequencer 不驱动 interface，只保存两个 sequencer 句柄：

~~~systemverilog
simple_bus_sequencer bus_sequencer;
wrapper_sequencer wrapper_sequencer;
~~~

env 创建 virtual sequencer，并在 `connect_phase` 将两个 agent 的 sequencer 句柄赋给它。
virtual sequencer 作为跨 agent 场景的统一入口；普通只访问 bus 的 smoke 仍可直接启动在
`bus_sequencer` 上。

### 13.2 新增 virtual sequence 基类 `已完成`

新增：

~~~text
uvm/v6_0/data_subsystem/tb/seq/data_subsystem_base_virtual_sequence.svh
~~~

基类声明 `p_sequencer` 为 `data_subsystem_virtual_sequencer`，并在 `body()` 中检查 virtual sequencer 及两个物理 sequencer 句柄均已连接。派生 virtual sequence 必须先调用 `super.body()`。

基类不封装 wrapper 或 bus transaction 的启动。派生 virtual sequence 应按场景显式创建并启动
`wrapper_set_seq` 与已有的 multi-item simple bus sequence；这样跨 agent 的时序关系保持可见，且
不引入与 physical sequence 重叠的 helper。

固定 delay 场景的时序为：

~~~text
start wrapper_set_seq
    -> wrapper driver item_done
    -> start an existing multi-item bus sequence
    -> bus driver completes all items in that sequence
    -> next wrapper config
~~~

virtual sequence 不直接操作 wrapper vif，也不在 item 之间插入隐含时钟等待。同步关系由两个 driver
的 `item_done()` 和子 sequence 的 `start()` 返回建立。后续需要逐笔随机改变 delay 时，再按逐笔
配置与逐笔 bus 激励的实际需求扩展专用 sequence，不提前引入与现有 multi-item sequence 重叠的抽象。

### 13.3 新增 somoke delay virtual sequence/test `已完成`

新增：

~~~text
uvm/v6_0/data_subsystem/tb/virtual/data_subsystem_wrapper_delay_vseq.svh
uvm/v6_0/data_subsystem/tb/tests/data_subsystem_wrapper_delay_test.svh
~~~

第一版只访问 DMEM word，并在一次 test 内按以下顺序配置：

~~~text
delay 0 -> write/read
delay 3 -> write/read
delay 1 -> write/read
delay 7 -> write/read
delay 0 -> write/read
~~~

每组使用不同地址/数据，scoreboard 必须继续验证数据正确性。test 只创建并启动 virtual
sequence，不取得 `wrapper_if`。

不再把 `+DMEM_DELAY=N` 作为第 11～16 章的主验证入口。命令行固定 delay 可在以后作为
debug convenience 添加，但固定、动态和随机回归统一走 wrapper cfg agent，避免形成两套核心
配置路径。

### 13.4 package、filelist 和 run_all 接入 `已完成`

增加 `tb/transaction`、`tb/agent/wrapper` 和 `tb/virtual` include path，并按以下依赖顺序
组织 package：

~~~text
bus item/transfer
wrapper cfg item
bus/wrapper sequences and sequencers
bus/wrapper drivers and agents
virtual sequencer
scoreboard/checkers
env
virtual sequences
tests
~~~

`run_all.sh` 增加 `data_subsystem_wrapper_delay_test`。正常 smoke、SVA smoke 和 wrapper delay
test 分开保留，失败时能快速区分基础 bus、协议 invariant 和 wrapper 配置问题。

### 13.5 验证节点 `已完成`

- virtual sequence 能协调两个 sequencer，不直接访问任何 vif。
- 每次 wrapper 配置都发生在上一笔 bus response 完成之后。
- monitor 观察到的 `observed_resp_delay` 按 0/3/1/7/0 变化。
- scoreboard 在所有 delay 下仍通过。
- SVA 不出现 second outstanding、orphan response 或 payload stable 误报。

## 14. 独立 response-delay wrapper checker `已完成`

目标：建立与 bus 功能 scoreboard 并列的 checker，自动比较 wrapper cfg agent 已执行的
配置和 monitor 观察到的实际 response delay。

### 14.1 checker 输入与状态 `已完成`

新增：

~~~text
uvm/v6_0/data_subsystem/tb/checker/data_subsystem_resp_delay_wrapper_checker.svh
~~~

checker 接收两路 analysis stream：

~~~text
wrapper_agent.driver.applied_cfg_ap
    -> wrapper checker cfg input

simple_bus_monitor.transfer_ap
    -> wrapper checker transfer input
~~~

checker 为 DMEM/GPIO0/UART0/TIMER0 分别维护当前 expected delay，reset 初值均为 0。
收到 applied cfg item 时，只更新对应 target；收到 bus transfer 时，根据实际 addr 译码 target，
比较：

~~~text
expected_delay[target] == transfer.observed_resp_delay
~~~

undefined target 不经过 wrapper，期望 delay 固定为 0。

可使用两个带后缀的 `uvm_analysis_imp`，或两个 `uvm_tlm_analysis_fifo`；具体写法以 VCS
兼容性和代码可读性为准，但必须保留两路输入的来源区分。

### 14.2 独立性边界 `无需改动`

wrapper checker：

- 不信任 virtual sequence 自己计算的 actual 值。
- 不读取 simple bus item 的计划字段。
- 不驱动 cfg interface 或 simple bus。
- 只把 cfg driver 已执行的配置作为 expected，把 monitor transfer 作为 observed。
- 不检查 DMEM/MMIO 数据值；数据/error 仍由功能 scoreboard 负责。

如果 cfg driver 配错 target/value，但仍发布原 cfg item，wrapper 的实际 response delay 会与
expected 不一致，checker 能暴露该问题。single outstanding 和 virtual sequence 的顺序约束使
cfg event 与后续 transfer 可按当前 target state 关联，不需要 transaction ID。

### 14.3 env 接入与验证 `已完成`

env 创建 wrapper checker，并连接 cfg AP 与 transfer AP。确定性 wrapper delay test 必须自动
产生 match 日志或统计；mismatch 使用 `uvm_error`，打印 target、addr、expected、actual。

验证节点：

- 0/1/3/7 delay 都由 checker 自动判断，不依赖人工读 monitor log。
- 故意在本地调试时改变一个 expected 值能够看到 checker mismatch；该故障注入不进入正式
  回归和完成标准。
- scoreboard 与 wrapper checker 同时订阅同一 transfer，检查职责不重叠。
- 普通 0 delay smoke 也经过 checker，默认 expected state 为 0。

## 15. driver execution checker 与 idle-gap 定向验证 `执行中`

目标：把 UVM master 自身的“计划 item 是否如实出现在 interface”做成独立 testbench
self-checker，避免把 driver 调度错误误判为 DUT 功能错误。

### 15.1 新增 driver execution checker

新增：

~~~text
uvm/v6_0/data_subsystem/tb/checker/simple_bus_driver_execution_checker.svh
~~~

输入：

~~~text
simple_bus_driver.planned_item_ap
simple_bus_monitor.transfer_ap
~~~

checker 分别排队 planned item 和 observed transfer，并按顺序一一配对。当前总线 single
outstanding、in-order completion，因此不需要 transaction ID；若以后允许多 outstanding，
本 checker 必须重新设计关联方式。

每对对象检查：

- `write/be/addr/wdata` 计划值与实际 accepted request 完全一致。
- 非首笔 transaction 的 `item.idle_cycles` 与 `transfer.observed_idle_cycles` 完全一致。
- 首笔 initial idle 不参与严格比较，避免把 reset 释放到首笔 request 的启动约定混入普通
  transaction gap。
- 结构性缺项、仿真结束仍有未配对对象属于 testbench 错误，在 `check_phase` 明确报告。

checker 只验证 UVM stimulus 执行，不检查 rdata/error，也不把 mismatch 归因于 DUT。

### 15.2 新增确定性 idle-gap virtual sequence/test

新增：

~~~text
uvm/v6_0/data_subsystem/tb/virtual/data_subsystem_idle_gap_vseq.svh
uvm/v6_0/data_subsystem/tb/tests/data_subsystem_idle_gap_test.svh
~~~

virtual sequence 先通过 wrapper cfg agent 把 DMEM delay 设为 0，再发送一笔 warm-up
transaction；随后按 0/1/3/7/0 设置 bus item 的 `idle_cycles`。sequence 不额外使用
`@(clock)` 制造 gap，所有计划间隔只来自 item 字段。

验证节点：

- execution checker 对非首笔 transaction 精确比较，不默认允许调度造成的 +1。
- scoreboard 继续验证 DMEM 数据。
- wrapper checker 确认 delay 仍为 0。
- SVA 不误报。
- checker 的 planned/observed 队列在 test 结束时为空。

## 16. 逐笔随机 wrapper delay、idle gap 与基础 coverage

目标：在确定性路径稳定后，让每笔 transaction 都能通过两个 agent 独立随机配置
`idle_cycles` 和 wrapper delay，并建立第一版可运行 functional coverage。

### 16.1 constrained-random virtual sequence

新增：

~~~text
uvm/v6_0/data_subsystem/tb/virtual/data_subsystem_random_delay_vseq.svh
uvm/v6_0/data_subsystem/tb/tests/data_subsystem_random_delay_test.svh
~~~

第一版仍限定为合法 DMEM word traffic：

- 每组先随机一个 0～127 的 wrapper delay，再由 cfg agent 应用。
- delay 分布提高 0、1、最大值 127 和若干中间值的命中权重。
- 每笔 bus item 独立随机合法 `idle_cycles`。
- 使用 write/read pair，保证 DMEM scoreboard 有确定的 expected value。
- 每次修改 wrapper 配置前必须等上一笔 bus item `finish_item()` 返回。
- 固定 seed 回归保留；后续可增加多个 seed，但不能替代 0/1/3/7/127 定向边界。

wrapper checker 自动比较 expected/observed delay，execution checker 自动比较 planned/observed
request 和 idle gap；random sequence 本身不重复实现 checker 逻辑。

### 16.2 新增基础 functional coverage

新增目录和组件：

~~~text
uvm/v6_0/data_subsystem/tb/coverage/simple_bus_coverage.svh
~~~

`simple_bus_coverage` 订阅 monitor 的 `simple_bus_transfer`，只采样实际完成的 transaction。
第一版 coverpoints：

- op：read/write。
- observed response delay：0、1、短延迟、中间延迟、127。
- observed idle gap：0、短 gap、长 gap。
- response：OK/error。
- op x delay。
- idle gap x delay。

当前 traffic 只覆盖 DMEM，因此不以 target coverage 百分比作为本章完成门槛。后续加入 MMIO
后扩展 target、register、side effect 和 error crosses。coverage 证明场景发生过，不替代
scoreboard/SVA/checker。

env 创建 coverage subscriber，并将同一 monitor transfer AP 连接给它。VCS coverage 数据库
和报告入口在实现时按本机版本固化到 sim 脚本；`COVERAGE_ON` 若作为编译/运行配置开关，必须
像 `ASSERT_ON` 一样使用独立 build 目录，避免增量缓存串配置。

### 16.3 回归与完成标准

`run_all.sh` 保留：

- base/smoke。
- ASSERT_ON smoke。
- deterministic wrapper delay。
- deterministic idle gap。
- fixed-seed random delay/idle。

本轮 wait-state UVM 主目标完成标准：

- 功能 scoreboard、wrapper checker、driver execution checker 同时通过。
- random sequence 能逐笔切换 delay，不需要命令行 `+DMEM_DELAY`。
- SVA 在固定和随机 wait-state 下不误报。
- coverage 能生成非空报告，并命中 0/1/127 delay、read/write、0/nonzero idle gap 等基础 bins。
- 日志能区分 planned item、observed transfer、功能 mismatch、wrapper mismatch 和
  testbench execution mismatch。

## 17. 后续章节占位：MMIO register smoke

后续根据实际 UVM MVP 完成情况展开。

计划方向：

- 为 GPIO/UART/TIMER32 分别建立最小软件可见参考模型或专用 checker，不能只看日志。
- GPIO OUT/OE 基本读写。
- UART TXDATA write event。
- TIMER32 MTIME/MTIMECMP/CTRL/STATUS 基本读写。
- unknown offset error。
- 以 `dut/docs/periph_register_abi.md` 为唯一寄存器 ABI 来源。
- known-register smoke 和 unknown-offset error 使用不同定向 virtual sequence。
- wrapper cfg agent 为对应 target 配置 delay；wrapper checker 继续复用，不新增第二套 bus
  monitor。

## 18. 后续章节占位：byte enable 和 error

后续根据实际 UVM MVP 完成情况展开。

计划方向：

- 扩展 DMEM reference model，支持 byte/half/word write strobe。
- unaligned 地址是否由当前 DUT 定义处理。
- 未映射地址 error。
- 外设 unknown offset error。
- 新增 CPU-shaped byte-enable sequence：同一 `simple_bus_item` 按 access profile 施加
  `addr/be` 联合约束。byte profile 使用 `be = 4'b0001 << addr[1:0]`；halfword profile
  要求 `addr[0] == 0`，并按 `addr[1]` 选择 `4'b0011` 或 `4'b1100`；word profile 要求
  `addr[1:0] == 0` 且 `be == 4'b1111`。
- CPU-shaped sequence 与 generic bus-corner sequence 分开。后者可以产生任意非零 be 组合，
  前者模拟当前 core 实际可能发出的请求，二者预期不得混用。
- 对 MMIO，先从 ABI 中选择已定义的 word-aligned register offset，再按 access profile 生成
  byte offset。
- `RTL-001` 的 `reg+1` byte 和 `reg+2` halfword 用例应先稳定复现 error，随后进入 RTL 修复
  和回归。
- 未定义 MMIO offset、窗口外地址和当前未定义的 misaligned access 分别使用专门 negative
  virtual sequence，不混入 legal random traffic。

## 19. 后续章节占位：side effect scoreboard

后续根据实际 UVM MVP 完成情况展开。

计划方向：

- GPIO W1C。
- UART RXDATA read-clear。
- UART IRQ_PENDING W1C。
- TIMER32 compare/pending。
- wait-state 下副作用只发生一次。
- side-effect reference model 只按软件可见 ABI 建模，不复制 RTL 内部实现。

## 20. 后续章节占位：扩展 random sequence 和 coverage

后续根据 MMIO、byte/error 和 side-effect checker 的完成情况展开。

计划方向：

- random target、read/write、legal/illegal offset。
- legal traffic 初始分布建议 DMEM 50%、GPIO0 20%、UART0 15%、TIMER0 15%。
- known-register、unknown-offset、unmapped-address 使用不同 traffic bucket。
- random sequence 在 sequence/virtual sequence 层先选择 target，再约束 item 地址；target
  仍由最终 observed transfer 的地址推导。
- 扩展 coverage：target x access-profile、MMIO known/unknown x read/write、
  target x response、target x delay、target x idle gap、side effect x delay。
- coverage 只采样 monitor transfer，不以 sequence 计划值代替实际覆盖。
- 每个进入 legal random traffic 的场景必须已有明确 spec 和自动 checker/reference model。

## 21. 后续章节占位：SoC directed 回归保持

后续根据实际 UVM MVP 完成情况展开。

计划方向：

- Verilator `sim/soc_asm/run_all.sh` 保持可运行。
- Verilator `sim/soc_c/run_all.sh` 保持可运行。
- UVM 文件不进入 Verilator 默认编译路径。
- README 说明 Verilator/VCS 分工。

## 22. 后续章节占位：文档与阶段收口

后续根据实际 UVM MVP 完成情况展开。

计划方向：

- README 当前特性同步。
- `docs/08xx/0835` 若实现口径变化再补充。
- `uvm/v6_0/data_subsystem/tb` 使用说明。
- `uvm/v6_0/data_subsystem/sim` 脚本说明。
- 最终保存 v6.0 DUT RTL snapshot，并把 UVM filelist 从开发期主工程 RTL 切回归档镜像。
- 阶段完成标准检查。
