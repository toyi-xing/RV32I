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
  - `uvm/v6_0/simple_bus/dut`：v6.0 最小 DUT RTL 与 ABI 快照。
  - `uvm/v6_0/simple_bus/tb`：UVM interface、class、assertion 和 harness。
  - `uvm/v6_0/simple_bus/sim`：本版本独立 filelist 和 VCS 脚本。
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
- 新增 UVM 文件默认只进入 `uvm/v6_0/simple_bus/sim/filelist.f`。
- VCS filelist 只编译本工作区 `dut/rtl` 快照，不引用根目录主线 `rtl/`，保证后续主线切换 AXI-Lite 后本环境仍可运行。
- 现有 RTL 不为了 UVM 大改接口；若需要 harness 适配，优先在 `uvm/v6_0/simple_bus/tb` 下完成。
- UVM 若发现真实 RTL bug，先修根目录主线并跑 Verilator directed regression，再同步到开发期 DUT 快照并记录；0835 完成后冻结快照。
- 每完成一个可运行节点，先跑一次最小 VCS test，再继续扩展。
- 本计划中的代码块是建议骨架；实现时可以按 VCS 报错、现有代码风格和个人理解微调，但类名、端口语义、连接方向尽量保持一致。

## 1. VCS/UVM 最小工程骨架 `执行中`

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

`dut/rtl` 已从 `c2f7d82` / `v6.0-data-side-variable-delay` 复制 `data_subsystem` 的最小编译闭包；`dut/docs/periph_register_abi.md` 保存匹配的外设 ABI。具体文件映射、开发期同步和冻结规则见 `uvm/v6_0/simple_bus/dut/README.md`。

本步骤不改现有 `rtl/`、`tb/sv`、`sim/soc_asm`、`sim/soc_c`。`tb/` 和 `sim/` 当前留空，后续 UVM 源码和脚本由本计划逐步创建。

### 1.2 新增 UVM package 文件

新增：

```text
uvm/v6_0/simple_bus/tb/simple_bus_pkg.sv
```

第一版先只 include base test，后续每新增 class 文件就追加 include。

建议骨架：

```systemverilog
package simple_bus_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    import core_pkg::*;
    import soc_pkg::*;
    import data_bus_pkg::*;

    `include "simple_bus_base_test.sv"
endpackage
```

注意：

- `uvm_macros.svh` 必须在使用 `` `uvm_component_utils`` 等宏之前 include。
- class 文件通过 package include，不在 `filelist.f` 里重复列。
- 后续 include 顺序按“被依赖者在前”维护，例如 item 在 driver/monitor 前，base test 在 smoke test 前。

### 1.3 新增空 base test

新增：

```text
uvm/v6_0/simple_bus/tb/simple_bus_base_test.sv
```

第一版只验证 UVM test 能启动。

建议骨架：

```systemverilog
class simple_bus_base_test extends uvm_test;
    `uvm_component_utils(simple_bus_base_test)

    function new(string name = "simple_bus_base_test", uvm_component parent = null);
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
simple_bus_env env;
```

### 1.4 新增最小 UVM top

新增：

```text
uvm/v6_0/simple_bus/tb/tb_data_subsystem_uvm.sv
```

第一版只提供 clock/reset、全局 timeout 和 `run_test()`。

建议骨架：

```systemverilog
`timescale 1ns/1ps
`default_nettype none

module tb_data_subsystem_uvm;
    import uvm_pkg::*;
    import simple_bus_pkg::*;

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

### 1.5 新增 VCS filelist

新增：

```text
uvm/v6_0/simple_bus/sim/filelist.f
```

第一版按顺序加入：

```text
../dut/rtl/common/core_pkg.sv
../dut/rtl/common/soc_pkg.sv
../dut/rtl/common/data_bus_pkg.sv

../tb/simple_bus_pkg.sv
../tb/tb_data_subsystem_uvm.sv
```

注意：

- 这里假设脚本从 `uvm/v6_0/simple_bus/sim` 目录执行；DUT 快照和 UVM testbench 分别使用 `../dut`、`../tb` 相对路径。
- `soc_pkg.sv`、`data_bus_pkg.sv` 都依赖 `core_pkg.sv`，因此 `core_pkg.sv` 放最前。
- 后续第 2 章新增 interface 后，`simple_bus_if.sv` 应放在 `simple_bus_pkg.sv` 前，因为 driver/monitor class 会声明 `virtual simple_bus_if vif`。

### 1.6 新增 VCS 单测脚本

新增：

```text
uvm/v6_0/simple_bus/sim/run_test.sh
```

脚本第一版建议支持：

```text
./run_test.sh [test_name] [seed] [extra_plusargs...]
```

建议骨架：

```bash
#!/usr/bin/env bash
set -euo pipefail

TEST_NAME=${1:-simple_bus_base_test}
SEED=${2:-1}
shift || true
shift || true
EXTRA_ARGS="$*"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

BUILD_DIR="build/${TEST_NAME}_${SEED}"
LOG_DIR="logs"
mkdir -p "$BUILD_DIR" "$LOG_DIR"

vcs -full64 -sverilog -ntb_opts uvm \
    -timescale=1ns/1ps \
    +incdir+../tb \
    -f filelist.f \
    -l "${LOG_DIR}/${TEST_NAME}_${SEED}_compile.log" \
    -o "${BUILD_DIR}/simv"

"${BUILD_DIR}/simv" \
    +UVM_TESTNAME="${TEST_NAME}" \
    +ntb_random_seed="${SEED}" \
    ${EXTRA_ARGS} \
    -l "${LOG_DIR}/${TEST_NAME}_${SEED}.log"
```

注意：

- 如果你的 VCS 需要先 source 环境变量，不要写死在仓库脚本里；可以在 shell 环境里提前配置。
- `EXTRA_ARGS` 只用于传 `+DMEM_DELAY=3` 这类运行期 plusarg。
- `+define+ASSERT_ON` 是 VCS 编译期选项，不能通过 simv 的运行期 `EXTRA_ARGS` 传入；第 10.3 节会把它加入 VCS 编译命令。
- 如果 VCS 对 `-ntb_opts uvm` 版本口径不同，按本机 VCS 报错调整。

上述 top 骨架从第一版开始设置全局 timeout，避免 DUT 不返回 response 时仿真永久挂住。该 timeout 是整场 test 的最后保护，不替代 driver 后续对单笔 transaction 的超时诊断。进入第 5 章实现 driver 时，应按最大配置 delay 加裕量设置 request/response 等待上限，超时后用 `uvm_fatal` 打印当前 transaction。

### 1.7 新增 VCS 回归脚本

新增：

```text
uvm/v6_0/simple_bus/sim/run_all.sh
```

第一版只调用一次 base test。

建议骨架：

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

./run_test.sh simple_bus_base_test 1
```

后续每新增一个 test，就在这里加一行。

### 1.8 更新 `.gitignore`

检查并补充 VCS/UVM 运行产物忽略规则。

至少覆盖：

```text
uvm/v6_0/simple_bus/sim/build/
uvm/v6_0/simple_bus/sim/logs/
uvm/v6_0/simple_bus/sim/csrc/
uvm/v6_0/simple_bus/sim/simv
uvm/v6_0/simple_bus/sim/simv.daidir/
uvm/v6_0/simple_bus/sim/ucli.key
uvm/v6_0/simple_bus/sim/vcs.log
uvm/v6_0/simple_bus/sim/*.vpd
uvm/v6_0/simple_bus/sim/*.fsdb
```

如果本仓库已有更通用 VCS 忽略规则，优先沿用已有风格。

### 1.9 验证节点

本章完成标准：

- `uvm/v6_0/simple_bus/sim/run_test.sh simple_bus_base_test` 可以编译并运行。
- log 中能看到 `UVM_INFO`。
- 全局 UVM timeout 已启用，test 不会因永久等待而无限运行。
- 没有引入 Verilator directed regression 依赖。
- `git status` 中只出现预期新增文件和 `.gitignore` 修改。

## 2. simple data bus interface

目标：把 simple data bus 信号集中到一个 SystemVerilog interface 中，供 driver、monitor、assertion 和 DUT harness 共用。

### 2.1 新增 interface 文件

新增：

```text
uvm/v6_0/simple_bus/tb/simple_bus_if.sv
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

    modport master (
        input  clk,
        input  rst_n,
        output req,
        input  req_ready,
        input  resp
    );

    modport slave (
        input  clk,
        input  rst_n,
        input  req,
        output req_ready,
        output resp
    );

    modport monitor (
        input clk,
        input rst_n,
        input req,
        input req_ready,
        input resp
    );

    task automatic drive_idle();
        req.valid = 1'b0;
        req.write = 1'b0;
        req.be    = 4'b0000;
        req.addr  = '0;
        req.wdata = '0;
    endtask
endinterface

`default_nettype wire
```

注意：

- 第一版为了降低 race 风险，driver 后续统一在 `negedge clk` 驱动 request，monitor 在 `posedge clk` 采样 request/response。
- 本阶段暂时不强制使用 clocking block；等基本 UVM 跑通后，如有 race 再引入 clocking block。
- `req_ready` 不是 request payload，因此独立放在 interface 中。

### 2.2 更新 filelist 顺序

修改：

```text
uvm/v6_0/simple_bus/sim/filelist.f
```

把 interface 放在 package 前：

```text
../dut/rtl/common/core_pkg.sv
../dut/rtl/common/soc_pkg.sv
../dut/rtl/common/data_bus_pkg.sv

../tb/simple_bus_if.sv
../tb/simple_bus_pkg.sv
../tb/tb_data_subsystem_uvm.sv
```

原因：后续 package 里的 driver/monitor 会声明 `virtual simple_bus_if vif`，所以 interface 类型要先被编译。

### 2.3 UVM top 例化 interface

修改：

```text
uvm/v6_0/simple_bus/tb/tb_data_subsystem_uvm.sv
```

在 clock/reset 后增加：

```systemverilog
simple_bus_if simple_bus_vif (
    .clk   (clk),
    .rst_n (rst_n)
);

initial begin
    simple_bus_vif.drive_idle();
end
```

暂时不设置 `uvm_config_db`，第 7 章接 driver/monitor 时再设置。

### 2.4 验证节点

本章完成标准：

- VCS 能编译 `simple_bus_if.sv`。
- `simple_bus_base_test` 仍能运行。
- 没有真实 bus transaction。

## 3. transaction item

目标：定义一笔 simple data bus transaction 的 UVM item。

### 3.1 新增 item 文件

新增：

```text
uvm/v6_0/simple_bus/tb/simple_bus_item.sv
```

建议骨架：

```systemverilog
class simple_bus_item extends uvm_sequence_item;
    rand bit                      write;
    rand logic [core_pkg::XLEN-1:0] addr;
    rand logic [core_pkg::XLEN-1:0] wdata;
    rand logic [3:0]              be;

    logic [core_pkg::XLEN-1:0]    rdata;
    bit                           error;
    int unsigned                  resp_delay;

    `uvm_object_utils_begin(simple_bus_item)
        `uvm_field_int(write,      UVM_ALL_ON)
        `uvm_field_int(addr,       UVM_ALL_ON)
        `uvm_field_int(wdata,      UVM_ALL_ON)
        `uvm_field_int(be,         UVM_ALL_ON)
        `uvm_field_int(rdata,      UVM_ALL_ON)
        `uvm_field_int(error,      UVM_ALL_ON)
        `uvm_field_int(resp_delay, UVM_ALL_ON)
    `uvm_object_utils_end

    constraint c_nonzero_be {
        be != 4'b0000;
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
        return $sformatf("write=%0d addr=0x%08x target=%s be=0x%0x wdata=0x%08x rdata=0x%08x error=%0d delay=%0d",
                         write, addr, target_name(), be, wdata, rdata, error, resp_delay);
    endfunction
endclass
```

注意：

- 字段宽度使用 `core_pkg::XLEN`，避免后续 XLEN 变化时到处改。
- 第一版只需要 `be != 0`，更细的 strobe 合法性放到后续 byte enable 测试。
- target 名称由地址和当前 v6.0 地址图推导，不作为 sequence 随机字段，便于 monitor、timeout 和 log 使用统一口径。
- `resp_delay` 由 monitor 填，driver 可以不填。

### 3.2 接入 package

修改：

```text
uvm/v6_0/simple_bus/tb/simple_bus_pkg.sv
```

include 顺序改为：

```systemverilog
`include "simple_bus_item.sv"
`include "simple_bus_base_test.sv"
```

### 3.3 在 base test 中临时打印 item

临时修改 `simple_bus_base_test.run_phase`：

```systemverilog
simple_bus_item tr;

phase.raise_objection(this);
tr = simple_bus_item::type_id::create("tr");
tr.write = 1'b1;
tr.addr  = core_pkg::DMEM_BASE + 32'h40;
tr.wdata = 32'h1234_5678;
tr.be    = 4'hf;
`uvm_info(get_type_name(), tr.convert2string(), UVM_LOW)
#100ns;
phase.drop_objection(this);
```

本临时代码只用于确认 item/package 编译和打印正常；第 7 章引入 env 后可以删掉。

### 3.4 验证节点

本章完成标准：

- VCS 能编译 item。
- base test 仍能运行。
- log 中能看到 item 字段打印。

## 4. sequencer 和最小 sequence

目标：让 UVM 能生成一笔或多笔 simple bus transaction。

### 4.1 新增 sequencer 文件

新增：

```text
uvm/v6_0/simple_bus/tb/simple_bus_sequencer.sv
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

### 4.2 新增 smoke sequence 文件

新增：

```text
uvm/v6_0/simple_bus/tb/simple_bus_smoke_seq.sv
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
        finish_item(tr);
    endtask
endclass
```

注意：

- sequence 只负责产生“想访问什么”，不直接碰 DUT 信号。
- read 的 `be` 当前填 `4'hf` 只是为了字段完整；DUT 读路径主要看 `write=0` 和 addr。

### 4.3 接入 package

修改 `simple_bus_pkg.sv`：

```systemverilog
`include "simple_bus_item.sv"
`include "simple_bus_sequencer.sv"
`include "simple_bus_smoke_seq.sv"
`include "simple_bus_base_test.sv"
```

### 4.4 base test 临时启动 sequence

在没有 driver 前，不建议真的启动 sequence，因为 sequence 会等 driver 取 item。

本章只要求能编译 sequencer/sequence。若要临时测试 sequence 创建，可以只做：

```systemverilog
simple_bus_smoke_seq seq;
seq = simple_bus_smoke_seq::type_id::create("seq");
`uvm_info(get_type_name(), "smoke sequence object created", UVM_LOW)
```

### 4.5 验证节点

本章完成标准：

- VCS 能编译 sequencer 和 sequence。
- base test 仍能运行。
- 暂时不要求 transaction 被 driver 消费。

## 5. driver

目标：实现一个能按 simple data bus 协议发 request、等待 ready、等待 response 的 UVM driver。

### 5.1 新增 driver 文件

新增：

```text
uvm/v6_0/simple_bus/tb/simple_bus_driver.sv
```

建议骨架：

```systemverilog
class simple_bus_driver extends uvm_driver #(simple_bus_item);
    `uvm_component_utils(simple_bus_driver)

    virtual simple_bus_if vif;
    localparam int unsigned MAX_TRANSACTION_WAIT_CYCLES = 256;

    function new(string name = "simple_bus_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual simple_bus_if)::get(this, "", "vif", vif)) begin
            `uvm_fatal(get_type_name(), "failed to get virtual simple_bus_if")
        end
    endfunction

    task run_phase(uvm_phase phase);
        simple_bus_item tr;

        drive_idle();
        wait (vif.rst_n === 1'b1);
        @(posedge vif.clk);

        forever begin
            seq_item_port.get_next_item(tr);
            drive_one(tr);
            seq_item_port.item_done();
        end
    endtask

    task automatic drive_idle();
        vif.req.valid = 1'b0;
        vif.req.write = 1'b0;
        vif.req.be    = 4'b0000;
        vif.req.addr  = '0;
        vif.req.wdata = '0;
    endtask

    task automatic drive_one(simple_bus_item tr);
        bit accepted;
        bit got_resp;
        int unsigned wait_cycles;

        `uvm_info(get_type_name(), {"drive ", tr.convert2string()}, UVM_MEDIUM)

        // 第一版固定在 negedge 驱动，posedge 采样，避免 0 wait-state 组合响应 race。
        @(negedge vif.clk);
        vif.req.valid = 1'b1;
        vif.req.write = tr.write;
        vif.req.be    = tr.be;
        vif.req.addr  = tr.addr;
        vif.req.wdata = tr.wdata;

        accepted = 1'b0;
        got_resp = 1'b0;
        wait_cycles = 0;

        while (!accepted) begin
            @(posedge vif.clk);
            accepted = vif.req.valid && vif.req_ready;
            got_resp = vif.resp.valid;
            wait_cycles++;
            if (!accepted && wait_cycles >= MAX_TRANSACTION_WAIT_CYCLES) begin
                `uvm_fatal(get_type_name(),
                    $sformatf("timeout after %0d cycles waiting for request acceptance: %s",
                              wait_cycles, tr.convert2string()))
            end
        end

        // accepted 后在下一个 negedge 撤销 valid，保证不会跨到下一个 posedge 再次 accepted。
        @(negedge vif.clk);
        drive_idle();

        if (!got_resp) begin
            wait_cycles = 0;
            do begin
                @(posedge vif.clk);
                got_resp = vif.resp.valid;
                wait_cycles++;
                if (!got_resp && wait_cycles >= MAX_TRANSACTION_WAIT_CYCLES) begin
                    `uvm_fatal(get_type_name(),
                        $sformatf("timeout after %0d cycles waiting for response: %s",
                                  wait_cycles, tr.convert2string()))
                end
            end while (!got_resp);
        end

        tr.rdata = vif.resp.rdata;
        tr.error = vif.resp.error;
        `uvm_info(get_type_name(), {"done  ", tr.convert2string()}, UVM_MEDIUM)
    endtask
endclass
```

注意：

- 当前 simple bus 是 single outstanding，driver 必须等 response 后再取下一笔 item。
- 0 wait-state 时，accepted 和 response 可能在同一个 posedge 被采样到。
- `MAX_TRANSACTION_WAIT_CYCLES` 必须大于 test 允许配置的最大 target delay，并留出少量调度裕量；当前 delay 输入为 7 bit，第一版取 256 拍。
- driver 回填 item 只是方便 sequence/debug；最终检查以 monitor/scoreboard 为准。

### 5.2 接入 package

修改 `simple_bus_pkg.sv`：

```systemverilog
`include "simple_bus_item.sv"
`include "simple_bus_sequencer.sv"
`include "simple_bus_smoke_seq.sv"
`include "simple_bus_driver.sv"
`include "simple_bus_base_test.sv"
```

### 5.3 验证节点

本章完成标准：

- driver 可以编译。
- 如果后续 env 没有设置 vif，driver 应报清楚 `uvm_fatal`。
- 还未接 agent/env 前，不要求产生真实 transaction。

## 6. monitor

目标：实现被动 monitor，把 DUT 引脚上真实发生的 request/response 重建成 transaction。

### 6.1 新增 monitor 文件

新增：

```text
uvm/v6_0/simple_bus/tb/simple_bus_monitor.sv
```

建议骨架：

```systemverilog
class simple_bus_monitor extends uvm_component;
    `uvm_component_utils(simple_bus_monitor)

    virtual simple_bus_if vif;
    uvm_analysis_port #(simple_bus_item) item_ap;

    function new(string name = "simple_bus_monitor", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        item_ap = new("item_ap", this);
        if (!uvm_config_db #(virtual simple_bus_if)::get(this, "", "vif", vif)) begin
            `uvm_fatal(get_type_name(), "failed to get virtual simple_bus_if")
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
            @(posedge vif.clk);
            cycle_cnt++;

            if (!vif.rst_n) begin
                pending = 1'b0;
                continue;
            end

            // request accepted
            if (vif.req.valid && vif.req_ready) begin
                if (pending) begin
                    `uvm_error(get_type_name(), "second request accepted before previous response")
                end

                pending_tr = simple_bus_item::type_id::create("pending_tr", this);
                pending_tr.write = vif.req.write;
                pending_tr.addr  = vif.req.addr;
                pending_tr.wdata = vif.req.wdata;
                pending_tr.be    = vif.req.be;

                pending      = 1'b1;
                accept_cycle = cycle_cnt;
            end

            // response valid
            if (vif.resp.valid) begin
                if (!pending) begin
                    `uvm_error(get_type_name(), "orphan response without pending request")
                end
                else begin
                    pending_tr.rdata      = vif.resp.rdata;
                    pending_tr.error      = vif.resp.error;
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
- 同拍 accepted+response 时，本代码先创建 `pending_tr`，再填 response，因此能输出完整 item。
- monitor 输出的是“DUT 引脚真实发生的 transaction”，scoreboard 后续只看 monitor，不直接信任 driver。

### 6.2 接入 package

修改 `simple_bus_pkg.sv`：

```systemverilog
`include "simple_bus_item.sv"
`include "simple_bus_sequencer.sv"
`include "simple_bus_smoke_seq.sv"
`include "simple_bus_driver.sv"
`include "simple_bus_monitor.sv"
`include "simple_bus_base_test.sv"
```

### 6.3 验证节点

本章完成标准：

- monitor 可以编译。
- monitor 不驱动任何 DUT 信号。
- 后续接入 DUT 后，monitor 输出的 item 应以真实引脚为准，而不是 driver item 为准。

## 7. agent 和 env

目标：把 sequencer、driver、monitor 封装成 agent，并把 agent 接入 env。

### 7.1 新增 agent 文件

新增：

```text
uvm/v6_0/simple_bus/tb/simple_bus_agent.sv
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

### 7.2 新增 env 文件

新增：

```text
uvm/v6_0/simple_bus/tb/simple_bus_env.sv
```

建议骨架：

```systemverilog
class simple_bus_env extends uvm_env;
    `uvm_component_utils(simple_bus_env)

    simple_bus_agent agent;

    function new(string name = "simple_bus_env", uvm_component parent = null);
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

### 7.3 修改 base test 例化 env

修改：

```text
uvm/v6_0/simple_bus/tb/simple_bus_base_test.sv
```

建议更新为：

```systemverilog
class simple_bus_base_test extends uvm_test;
    `uvm_component_utils(simple_bus_base_test)

    simple_bus_env env;

    function new(string name = "simple_bus_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = simple_bus_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info(get_type_name(), "base test created env only", UVM_LOW)
        #100ns;
        phase.drop_objection(this);
    endtask
endclass
```

### 7.4 修改 top 设置 virtual interface

修改：

```text
uvm/v6_0/simple_bus/tb/tb_data_subsystem_uvm.sv
```

在 `run_test()` 前设置 virtual interface：

```systemverilog
initial begin
    uvm_config_db #(virtual simple_bus_if)::set(
        null,
        "uvm_test_top.env.agent*",
        "vif",
        simple_bus_vif
    );
    run_test();
end
```

如果 driver 或 monitor 报拿不到 vif，先把路径放宽为：

```systemverilog
uvm_config_db #(virtual simple_bus_if)::set(null, "*", "vif", simple_bus_vif);
```

跑通后再收紧路径。

### 7.5 接入 package

修改 `simple_bus_pkg.sv` include 顺序：

```systemverilog
`include "simple_bus_item.sv"
`include "simple_bus_sequencer.sv"
`include "simple_bus_smoke_seq.sv"
`include "simple_bus_driver.sv"
`include "simple_bus_monitor.sv"
`include "simple_bus_agent.sv"
`include "simple_bus_env.sv"
`include "simple_bus_base_test.sv"
```

### 7.6 验证节点

本章完成标准：

- base test 能创建 env/agent/driver/monitor。
- driver/monitor 都能拿到 vif。
- 因为还没有 DUT 和 sequence，允许没有真实 bus transaction。

## 8. DUT harness 和 DMEM smoke

目标：把 `data_subsystem` 接进 UVM top，用 UVM driver 访问 DMEM，完成第一条真正的 UVM smoke。

### 8.1 更新 filelist，接入归档 DUT RTL

修改：

```text
uvm/v6_0/simple_bus/sim/filelist.f
```

建议顺序：

```text
../dut/rtl/common/core_pkg.sv
../dut/rtl/common/soc_pkg.sv
../dut/rtl/common/data_bus_pkg.sv

../dut/rtl/periph/mmio_gpio.sv
../dut/rtl/periph/mmio_uart.sv
../dut/rtl/periph/mmio_timer32.sv
../dut/rtl/mem/simple_ram.sv
../dut/rtl/soc/data_subsystem.sv

../tb/simple_bus_if.sv
../tb/simple_bus_pkg.sv
../tb/tb_data_subsystem_uvm.sv
```

### 8.2 UVM top 增加 DUT 连接信号

在 `tb_data_subsystem_uvm.sv` 中声明：

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

logic [6:0] dmem_resp_delay_cycles;
logic [6:0] gpio0_resp_delay_cycles;
logic [6:0] uart0_resp_delay_cycles;
logic [6:0] timer0_resp_delay_cycles;

logic dmem_access;
logic mmio_access;
```

并给外部输入默认值：

```systemverilog
initial begin
    gpio0_in       = 32'h0;
    uart0_rx_valid = 1'b0;
    uart0_rx_data  = 8'h00;

    dmem_resp_delay_cycles   = 7'd0;
    gpio0_resp_delay_cycles  = 7'd0;
    uart0_resp_delay_cycles  = 7'd0;
    timer0_resp_delay_cycles = 7'd0;
end
```

### 8.3 UVM top 例化 `data_subsystem`

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

    .dmem_resp_delay_cycles_i   (dmem_resp_delay_cycles),
    .gpio0_resp_delay_cycles_i  (gpio0_resp_delay_cycles),
    .uart0_resp_delay_cycles_i  (uart0_resp_delay_cycles),
    .timer0_resp_delay_cycles_i (timer0_resp_delay_cycles),

    .dmem_access_o (dmem_access),
    .mmio_access_o (mmio_access)
);
```

### 8.4 UVM top 例化 `simple_ram`

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

### 8.5 新增 smoke test 文件

新增：

```text
uvm/v6_0/simple_bus/tb/simple_bus_smoke_test.sv
```

建议骨架：

```systemverilog
class simple_bus_smoke_test extends simple_bus_base_test;
    `uvm_component_utils(simple_bus_smoke_test)

    function new(string name = "simple_bus_smoke_test", uvm_component parent = null);
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

### 8.6 接入 package

修改 `simple_bus_pkg.sv` include 顺序：

```systemverilog
`include "simple_bus_item.sv"
`include "simple_bus_sequencer.sv"
`include "simple_bus_smoke_seq.sv"
`include "simple_bus_driver.sv"
`include "simple_bus_monitor.sv"
`include "simple_bus_agent.sv"
`include "simple_bus_env.sv"
`include "simple_bus_base_test.sv"
`include "simple_bus_smoke_test.sv"
```

### 8.7 更新 run_all

`uvm/v6_0/simple_bus/sim/run_all.sh` 增加：

```bash
./run_test.sh simple_bus_smoke_test 1
```

### 8.8 验证节点

本章完成标准：

- VCS 能跑 `simple_bus_smoke_test`。
- driver 发出 DMEM write/read。
- monitor 能观察到 request/response。
- 暂时允许不检查 read data，但 log 中要能看出事务发生。

## 9. 最小 scoreboard

目标：让 UVM smoke 不只是“跑完”，而是能自动判断 DMEM 基本 read/write 是否正确。

### 9.1 新增 scoreboard 文件

新增：

```text
uvm/v6_0/simple_bus/tb/simple_bus_scoreboard.sv
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

### 9.2 env 接入 scoreboard

修改：

```text
uvm/v6_0/simple_bus/tb/simple_bus_env.sv
```

建议更新：

```systemverilog
class simple_bus_env extends uvm_env;
    `uvm_component_utils(simple_bus_env)

    simple_bus_agent      agent;
    simple_bus_scoreboard scoreboard;

    function new(string name = "simple_bus_env", uvm_component parent = null);
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

### 9.3 接入 package

修改 `simple_bus_pkg.sv` include 顺序：

```systemverilog
`include "simple_bus_item.sv"
`include "simple_bus_sequencer.sv"
`include "simple_bus_smoke_seq.sv"
`include "simple_bus_driver.sv"
`include "simple_bus_monitor.sv"
`include "simple_bus_agent.sv"
`include "simple_bus_scoreboard.sv"
`include "simple_bus_env.sv"
`include "simple_bus_base_test.sv"
`include "simple_bus_smoke_test.sv"
```

### 9.4 验证节点

本章完成标准：

- `simple_bus_smoke_test` 能自动 PASS/FAIL。
- 错误时 scoreboard 打印 addr、expected、actual。
- DMEM 基本 word write/read 通过。

## 10. 第一批 SVA

目标：接入最少量、价值最高的 simple bus 协议断言。

### 10.1 新增 assertion 文件

新增：

```text
uvm/v6_0/simple_bus/tb/simple_bus_assert.sv
```

为了第一版接入简单，建议本文件不单独成 module，而是写成 interface 内可 include 的代码片段，由 `simple_bus_if.sv` include。

建议骨架：

```systemverilog
`ifdef ASSERT_ON
    logic assert_outstanding_q;
    wire  assert_accept_fire = req.valid && req_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            assert_outstanding_q <= 1'b0;
        end
        else begin
            if (assert_accept_fire && !resp.valid) begin
                assert_outstanding_q <= 1'b1;
            end
            if (resp.valid) begin
                assert_outstanding_q <= 1'b0;
            end
        end
    end

    property p_payload_stable_when_wait;
        @(posedge clk) disable iff (!rst_n)
            (req.valid && !req_ready)
            |=> req.valid && $stable(req.write) && $stable(req.be) &&
                $stable(req.addr) && $stable(req.wdata);
    endproperty

    property p_no_second_accept_when_outstanding;
        @(posedge clk) disable iff (!rst_n)
            assert_outstanding_q |-> !assert_accept_fire;
    endproperty

    property p_no_orphan_response;
        @(posedge clk) disable iff (!rst_n)
            resp.valid |-> (assert_outstanding_q || assert_accept_fire);
    endproperty

    property p_reset_quiet;
        @(posedge clk)
            !rst_n |-> (!req.valid && !resp.valid);
    endproperty

    a_payload_stable_when_wait:
        assert property (p_payload_stable_when_wait);

    a_no_second_accept_when_outstanding:
        assert property (p_no_second_accept_when_outstanding);

    a_no_orphan_response:
        assert property (p_no_orphan_response);

    a_reset_quiet:
        assert property (p_reset_quiet);
`endif
```

### 10.2 interface 中 include assertion

修改：

```text
uvm/v6_0/simple_bus/tb/simple_bus_if.sv
```

在 `endinterface` 前加入：

```systemverilog
`include "simple_bus_assert.sv"
```

注意：

- 该 include 必须在 interface 内部。
- `simple_bus_assert.sv` 使用 interface 内已有的 `clk/rst_n/req/req_ready/resp`。

### 10.3 run_test 支持 ASSERT_ON

修改：

```text
uvm/v6_0/simple_bus/sim/run_test.sh
```

第一版可以默认打开：

```bash
ASSERT_DEFINE="+define+ASSERT_ON"

vcs -full64 -sverilog -ntb_opts uvm \
    ${ASSERT_DEFINE} \
    ...
```

如果希望可选：

```bash
ASSERT_DEFINE=${ASSERT_DEFINE:-+define+ASSERT_ON}
```

然后允许命令行环境覆盖。

### 10.4 验证节点

本章完成标准：

- `simple_bus_smoke_test` 在 SVA 打开时通过。
- 人为制造一个简单协议错误时，至少一条断言能报错。
- 断言错误不会混在 scoreboard 错误里看不清，log 中能看出 assertion 名称。

## 11. wait-state smoke

目标：让 UVM 环境覆盖 0 wait-state 和非 0 wait-state。

### 11.1 UVM top 支持 plusarg 配置 delay

修改：

```text
uvm/v6_0/simple_bus/tb/tb_data_subsystem_uvm.sv
```

把第 8 章的 delay 默认值改成 plusarg 可配置：

```systemverilog
int unsigned delay_arg;

initial begin
    dmem_resp_delay_cycles   = 7'd0;
    gpio0_resp_delay_cycles  = 7'd0;
    uart0_resp_delay_cycles  = 7'd0;
    timer0_resp_delay_cycles = 7'd0;

    if ($value$plusargs("DMEM_DELAY=%d", delay_arg)) begin
        dmem_resp_delay_cycles = delay_arg[6:0];
    end
    if ($value$plusargs("GPIO0_DELAY=%d", delay_arg)) begin
        gpio0_resp_delay_cycles = delay_arg[6:0];
    end
    if ($value$plusargs("UART0_DELAY=%d", delay_arg)) begin
        uart0_resp_delay_cycles = delay_arg[6:0];
    end
    if ($value$plusargs("TIMER0_DELAY=%d", delay_arg)) begin
        timer0_resp_delay_cycles = delay_arg[6:0];
    end
end
```

第一版只用 `DMEM_DELAY`。

### 11.2 新增 wait-state test

新增：

```text
uvm/v6_0/simple_bus/tb/simple_bus_wait_test.sv
```

第一版可以直接继承 smoke test，不改 sequence：

```systemverilog
class simple_bus_wait_test extends simple_bus_smoke_test;
    `uvm_component_utils(simple_bus_wait_test)

    function new(string name = "simple_bus_wait_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
endclass
```

原因：

- wait-state 由 top plusarg 控制，不需要 test class 先参与配置。
- 先保持 UVM class 简单，确认 driver/monitor/scoreboard 能跨 delay 工作。

### 11.3 接入 package

修改 `simple_bus_pkg.sv`，最后加入：

```systemverilog
`include "simple_bus_wait_test.sv"
```

完整顺序应类似：

```systemverilog
`include "simple_bus_item.sv"
`include "simple_bus_sequencer.sv"
`include "simple_bus_smoke_seq.sv"
`include "simple_bus_driver.sv"
`include "simple_bus_monitor.sv"
`include "simple_bus_agent.sv"
`include "simple_bus_scoreboard.sv"
`include "simple_bus_env.sv"
`include "simple_bus_base_test.sv"
`include "simple_bus_smoke_test.sv"
`include "simple_bus_wait_test.sv"
```

### 11.4 更新 run_all

修改：

```text
uvm/v6_0/simple_bus/sim/run_all.sh
```

加入固定 delay 组合：

```bash
./run_test.sh simple_bus_smoke_test 1
./run_test.sh simple_bus_wait_test  1 +DMEM_DELAY=0
./run_test.sh simple_bus_wait_test  2 +DMEM_DELAY=1
./run_test.sh simple_bus_wait_test  3 +DMEM_DELAY=3
./run_test.sh simple_bus_wait_test  4 +DMEM_DELAY=7
```

### 11.5 monitor 日志检查 delay

确认 monitor 输出的 `resp_delay`：

- `+DMEM_DELAY=0` 时，读写事务应看到 `delay=0`。
- `+DMEM_DELAY=1` 时，读写事务应看到 `delay=1`。
- `+DMEM_DELAY=3` 时，读写事务应看到 `delay=3`。
- 如果实际差 1 拍，优先检查 monitor 计数方式，再检查 `data_subsystem` delay 定义，最后统一计划和实现口径。

### 11.6 验证节点

本章完成标准：

- 0/1/3/7 delay 下 DMEM smoke 都通过。
- monitor log 能显示不同 response delay。
- scoreboard 仍能检查 read data。
- SVA 不误报。

## 12. 后续章节占位：MMIO register smoke

后续根据实际 UVM MVP 完成情况展开。

计划方向：

- GPIO OUT/OE 基本读写。
- UART TXDATA write event。
- TIMER32 MTIME/MTIMECMP/CTRL/STATUS 基本读写。
- unknown offset error。

## 13. 后续章节占位：byte enable 和 error

后续根据实际 UVM MVP 完成情况展开。

计划方向：

- DMEM byte/half/word write strobe。
- unaligned 地址是否由当前 DUT 定义处理。
- 未映射地址 error。
- 外设 unknown offset error。

## 14. 后续章节占位：side effect scoreboard

后续根据实际 UVM MVP 完成情况展开。

计划方向：

- GPIO W1C。
- UART RXDATA read-clear。
- UART IRQ_PENDING W1C。
- TIMER32 compare/pending。
- wait-state 下副作用只发生一次。

## 15. 后续章节占位：random sequence 和 coverage

后续根据实际 UVM MVP 完成情况展开。

计划方向：

- random target。
- random read/write。
- random delay。
- random legal/illegal offset。
- target x access type。
- target x delay。
- target x response。
- side effect x delay。

## 16. 后续章节占位：SoC directed 回归保持

后续根据实际 UVM MVP 完成情况展开。

计划方向：

- Verilator `sim/soc_asm/run_all.sh` 保持可运行。
- Verilator `sim/soc_c/run_all.sh` 保持可运行。
- UVM 文件不进入 Verilator 默认编译路径。
- README 说明 Verilator/VCS 分工。

## 17. 后续章节占位：文档与阶段收口

后续根据实际 UVM MVP 完成情况展开。

计划方向：

- README 当前特性同步。
- `docs/08xx/0835` 若实现口径变化再补充。
- `uvm/v6_0/simple_bus/tb` 使用说明。
- `uvm/v6_0/simple_bus/sim` 脚本说明。
- 阶段完成标准检查。
