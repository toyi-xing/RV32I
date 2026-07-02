# v5.0 data-side 可变延迟 memory/MMIO、简化内部总线与 backpressure 执行计划

当前工程已经完成：

- RV32I 五级流水线主路径。
- forwarding、load-use stall、CSR-use stall 和 branch/JAL/JALR redirect。
- 最小 M-mode CSR/trap、`ECALL/EBREAK/MRET` 和 Zicsr。
- SoC 地址图、DMEM/MMIO 译码、GPIO0、UART0、TIMER0。
- machine timer interrupt 与 machine external interrupt。
- SoC 级汇编/C directed tests 和 TB mailbox 外部激励协议。

本计划根据 `docs/08xx/0830 RV32I教学核后续完善路线：从v2.0到最小完整裸机核心.md` 和 `docs/08xx/0834 可变延迟memory与MMIO、简化内部总线与backpressure规划.md` 编写，目标是把当前 LSU/data subsystem 的固定一拍响应，升级为单 outstanding 的 request/response 简化 data bus，并让 MEM wait 对流水线形成 backpressure。

本计划是具体执行清单，会覆盖旧的 0833 执行计划。0833 已完成内容以 README、0833 文档和当前 RTL 为准。

## 0. 实现边界

本阶段实现：

- 只改 data side/LSU，不改 IMEM 取指侧固定响应模型。
- core LSU 侧改为单 outstanding 简化 data bus：

```text
request:
  valid, ready, write, addr, wdata, be

response:
  valid, rdata, error
```

- 第一版不引入 `resp_ready`，CPU 在等待 response 时默认总是可接收 response。
- MEM 阶段成为 data transaction owner：
  - load/store 到 MEM 后发起 request。
  - request 未被接受或 response 未返回时保持当前 MEM 指令。
  - response OK 后 load/store 才能进入普通完成路径。
  - response error 转换为 load/store access fault。
- MEM wait 期间对 EX/ID/IF/PC 施加 backpressure，年轻指令不能越过 older memory instruction。
- misaligned 和前级已有 exception 仍在 request 前发现，不发 data request。
- unknown address / unknown MMIO offset 从固定 `access_fault` 迁移为 response `error`。
- MMIO write/read 副作用与一次成功 transaction 绑定，不能因为 valid 保持、ready 等待或 response 延迟重复发生。
- 0 wait-state 下保持现有 directed regression 行为不退化。
- data_subsystem 改为 simple data bus decoder/interconnect，DMEM/MMIO target 通过 simple slave/wrapper 返回 response。
- data request/response、busy/wait、dmem/mmio hit 等必要观察信号透出到 SoC/testbench。
- 提供 TB 可配置 wait-state 注入入口，供本阶段 smoke 和后续验证收口使用。

本阶段不实现：

- AXI-Lite 或 AXI4。
- IMEM ready/valid、取指 outstanding、取指取消。
- cache、write buffer/store buffer、store queue。
- 多 outstanding、transaction ID、乱序 response。
- bus 仲裁、多 master、DMA。
- accelerator 本体。
- UVM/SVA 完整验证平台和完整 wait-state directed 测试矩阵。
- 外设寄存器 ABI 改动。
- 真实 UART 串口、多拍串口收发器或异步 FIFO。

控制优先级口径：

```text
reset
> MEM completion 上的同步 exception / delayed access fault
> MEM completion 上的 MRET+interrupt / CSR写+interrupt / interrupt
> MEM completion 上的 MRET
> MEM response OK 后允许的 younger EX redirect
> MEM wait backpressure
> 普通 EX redirect
> load-use/CSR-use stall
> normal advance
```

关键约束：

- delayed access fault 是当前 MEM older 指令的同步异常结果，优先于 interrupt 和 younger redirect。
- MEM wait 期间 younger EX redirect 不能改变 PC。
- response OK 且无 trap/interrupt 时，younger EX redirect 才能按普通控制流生效。
- interrupt pending 可以在 memory wait 期间进入 `mip`，但只能在当前 MEM 指令 completion 边界接受。
- `FENCE` 在当前单 hart、单 outstanding、无 cache、无 write buffer 条件下继续保持 NOP。

## 1. 前置整理：ROM/RAM 仿真模型外置 `已完成`

### 1.1 目标和边界 `已完成`

0834 正式改 data-side req/resp 前，先把 `simple_rom`、`simple_ram` 从 SoC RTL 内部移到 testbench 实例化。

目标：

- `rv32i_soc` 更像可综合 SoC shell，不直接实例化带 `$readmemh` 的仿真 memory model。
- `simple_rom/simple_ram` 仍保留现有 plusarg 加载方式，测试程序和 memory image 生成流程不变。
- data_subsystem 仍负责 DMEM/MMIO 地址译码，DMEM 本体由外部端口连接。
- 不在本整理中引入 data bus req/resp、wait-state、AXI-Lite 或外设 ABI 改动。

### 1.2 `rv32i_soc.sv` 外置 IMEM/DMEM 端口 `已完成`

`rv32i_soc` 不再内部实例化 `simple_rom`，而是透出 IMEM 固定响应接口：

```systemverilog
output logic [core_pkg::XLEN-1:0] imem_addr_o;
input  logic [core_pkg::ILEN-1:0] imem_rdata_i;
```

`rv32i_soc` 同时透出 data_subsystem 到外部 DMEM model 的固定响应接口：

```systemverilog
output logic                      dmem_we_o;
output logic [3:0]                dmem_be_o;
output logic [core_pkg::XLEN-1:0] dmem_addr_o;
output logic [core_pkg::XLEN-1:0] dmem_wdata_o;
input  logic [core_pkg::XLEN-1:0] dmem_rdata_i;
```

原有 testbench 观察口 `data_*`、`dmem_access_o/mmio_access_o` 暂时保持当前语义，后续 0834 data bus 改造时再统一调整。

### 1.3 `data_subsystem.sv` 外置 DMEM 端口 `已完成`

`data_subsystem` 不再内部实例化 `simple_ram`，而是输出 DMEM model 访问端口：

```systemverilog
output logic                      dmem_we_o;
output logic [3:0]                dmem_be_o;
output logic [core_pkg::XLEN-1:0] dmem_addr_o;
output logic [core_pkg::XLEN-1:0] dmem_wdata_o;
input  logic [core_pkg::XLEN-1:0] dmem_rdata_i;
```

第一版保持现有固定响应 RAM 语义：

- DMEM write 同步写。
- DMEM read 组合返回。
- 地址仍传给 `simple_ram`，由 `simple_ram` 按 `DMEM_BASE` 转换到内部 word index。
- 未命中 DMEM 时，`dmem_addr_o` 可指向 `DMEM_BASE` 这类无副作用安全地址，避免外部 RAM model 看到无意义索引。

### 1.4 `tb_rv32i_soc.sv` 实例化 memory model `已完成`

testbench 新增两个实例：

```text
simple_rom u_simple_rom
simple_ram u_simple_ram
```

连接到 `rv32i_soc` 新增的 IMEM/DMEM 端口。`+imem=<path>` 和 `+dmem=<path>` 仍由 `simple_rom/simple_ram` 内部处理，不需要改仿真命令或软件构建流程。

TB mailbox 监听仍然可以沿用当前 `data_we && dmem_access && data_addr` 口径；整理后可以把监听条件中的写意图直接改为外置 RAM 写口 `dmem_we`，减少重复逻辑。后续 0834 req/resp 改造时，再迁移到 accepted write request 或 successful write response。

### 1.5 文档同步 `已完成`

本整理完成后至少同步：

- `rv32i_soc.sv`、`data_subsystem.sv` 头注释，不再写 SoC/data_subsystem 内部实例化 simple ROM/RAM。
- `tb/sv/tb_rv32i_soc.sv` 头注释，说明 testbench 负责实例化 IMEM/DMEM 仿真模型。
- `README.md` 顶部 ASCII 图，把 `simple_rom/simple_ram` 从 SoC 内部移到 TB/仿真环境侧。

其他文档若只是泛称当前平台有 IMEM/DMEM，不强制在本整理中大改。

## 2. 公共类型和接口命名 `rtl无变动`

### 2.1 新增或扩展 data bus 公共类型 `rtl无变动`

第一版先使用离散端口推进，不新增 data bus 结构体。

若使用结构体，建议定义：

```systemverilog
typedef struct packed {
    logic                      valid;
    logic                      write;
    logic [XLEN-1:0]           addr;
    logic [XLEN-1:0]           wdata;
    logic [3:0]                be;
} data_req_t;

typedef struct packed {
    logic                      valid;
    logic [XLEN-1:0]           rdata;
    logic                      error;
} data_resp_t;
```

结构体后续统一替换时再新增；不建议放在 `core_pkg` 或 `soc_pkg`，后续可考虑新建 `data_bus_pkg`。

执行时可根据现有代码风格选择结构体或离散信号。若选择离散信号，命名口径保持：

```text
lsu_req_valid_o
lsu_req_ready_i
lsu_req_write_o
lsu_req_addr_o
lsu_req_wdata_o
lsu_req_be_o
lsu_resp_valid_i
lsu_resp_rdata_i
lsu_resp_error_i
```

计划默认后续条目使用离散信号描述，便于逐步替换当前 `lsu_re/lsu_we/lsu_rdata/lsu_access_fault`。

### 2.2 明确 read/write 指令类型保留位置 `无变动`

response error 需要区分 load access fault 和 store access fault，因此 MEM 阶段必须在等待事务期间保留：

```text
当前指令 valid
mem_re / mem_we
mem_size / mem_unsigned
faulting addr
pc / instr / next_pc
已有 exception 信息
CSR/MRET 控制信息
```

当前这些字段已经在 `ex_mem_reg_t` 中保存，第一版不额外新增 transaction tag。

### 2.3 保留 byte enable 语义 `无变动`

`be` 继续沿用当前 `mem_stage` 生成的 byte lane 含义：

| 指令 | 对齐要求 | be |
|---|---|---|
| `LB/LBU/SB` | 无额外低位要求 | 单 bit |
| `LH/LHU/SH` | `addr[0] == 0` | 连续 2 bit |
| `LW/SW` | `addr[1:0] == 0` | `4'b1111` |

本阶段不额外加入 `size` 到 data bus。load 扩展仍由 core/MEM 根据 `mem_size/mem_unsigned/addr[1:0]` 完成。

## 3. `mem_stage` 改造为事务发起与完成判定 `已完成`

### 3.1 修改 `rtl/core/mem_stage.sv` 模块定位 `已完成`

当前 `mem_stage` 是纯组合逻辑，头注释写明固定响应。0834 后需要改成支持时序状态的 MEM transaction controller。

模块职责调整为：

- 组合检测 misaligned。
- 对有效且无前级 exception 的 load/store 发起 data request。
- 在 request accepted 后记录 outstanding 状态。
- 在 response 返回前保持 busy/wait。
- response OK 时生成最终 load_data 或 store 完成。
- response error 时生成 load/store access fault。
- 非访存、misaligned、前级 exception 仍可在当前 MEM 边界直接完成或进入 trap。

### 3.2 新增时钟/复位端口 `已完成`

`mem_stage` 需要保存 outstanding 状态，因此端口新增：

```systemverilog
input logic clk_i;
input logic rst_n_i;
```

头注释同步更新，不再写“纯组合逻辑”。

### 3.3 替换 LSU 固定响应端口 `已完成`

移除或不再使用当前固定响应端口：

```systemverilog
input  logic [XLEN-1:0] lsu_rdata_i;
input  logic            lsu_access_fault_i;
output logic            lsu_re_o;
output logic            lsu_we_o;
```

改为 request/response：

```systemverilog
output logic            lsu_req_valid_o;
input  logic            lsu_req_ready_i;
output logic            lsu_req_write_o;
output logic [3:0]      lsu_req_be_o;
output logic [XLEN-1:0] lsu_req_addr_o;
output logic [XLEN-1:0] lsu_req_wdata_o;

input  logic            lsu_resp_valid_i;
input  logic [XLEN-1:0] lsu_resp_rdata_i;
input  logic            lsu_resp_error_i;
```

`lsu_req_write_o=1` 表示 store/MMIO write，`0` 表示 load/MMIO read。

### 3.4 新增 MEM wait/complete 输出 `已完成`

新增输出给 core 控制网络：

```systemverilog
output logic mem_wait_o;      // 当前 MEM 指令因为 data transaction 未完成而必须 hold。
output logic mem_complete_o;  // 当前 MEM 边界本拍可完成；主要用于调试/观察，可选。
output logic transaction_complete_o; // 当前 data transaction 本拍返回 response，OK/error 均表示事务完成。
```

推荐语义：

```text
transaction_complete_o = data transaction 本拍完成；支持 accepted 与 response 同拍的 0 wait-state。
mem_wait_o = 有效 load/store 且尚未到达 completion 边界
mem_complete_o = 非访存直接完成，或访存 response 返回，或 request 前 exception 直接完成
```

若后续发现 `mem_complete_o` 在 core 中不需要，可只保留 `mem_wait_o`，但建议至少保留一个观察口方便 TB/wave debug。

### 3.5 misaligned 和前级 exception 不发 request `已完成`

保持现有优先级：

```text
前级 exception
> load/store misaligned
> data request / response error
```

当 `exception_valid_i=1` 或 `mem_misaligned_o=1` 时：

- `lsu_req_valid_o=0`
- 不建立 outstanding
- 不等待 response
- 当前 MEM 指令可在本边界进入 trap

### 3.6 request payload 生成 `已完成`

当前 `mem_stage` 已有 `lsu_be_o/lsu_addr_o/lsu_wdata_o` 生成逻辑，0834 保持基本算法。

请求条件建议定义为：

```text
mem_access = valid_i && !exception_valid_i && !mem_misaligned_o && (mem_re_i || mem_we_i)
```

request payload：

```text
write = mem_we_i
addr  = alu_result_i
wdata = store_data_i << {alu_result_i[1:0], 3'b000}
be    = 当前 byte enable 生成结果
```

在 `lsu_req_valid_o=1 && lsu_req_ready_i=0` 时，payload 必须保持稳定。因为 EX/MEM 会被 `mem_wait_o` hold，payload 通常自然稳定；仍建议在代码注释中明确这一点。

### 3.7 outstanding 状态机 `已完成`

为保证副作用最多一次，第一版可使用一个简单状态：

```text
req_outstanding_q
```

语义：

- `0`：当前 MEM 指令尚未有 accepted request。
- `1`：已有 request accepted，等待 response。

状态更新：

```text
reset -> 0
request accepted 且本拍未完成 -> 1
transaction complete -> 0
request accepted 与 response valid 同拍 -> 0
当前 MEM 指令被 request 前 exception/trap 处理 -> 0
```

因为第一版只允许 single outstanding，`req_outstanding_q=1` 时不允许再次拉起新的 accepted request。

实现上可以用两个独立 `if` 让 `transaction_complete` 覆盖 `request_accepted` 的置位结果，从而支持类似同步单级 FIFO 的空直通语义。

### 3.8 request valid/ready 与 wait 关系 `已完成`

推荐语义：

```text
lsu_req_valid_o = mem_access && !req_outstanding_q
request_accepted = lsu_req_valid_o && lsu_req_ready_i
transaction_complete = lsu_resp_valid_i && (req_outstanding_q || request_accepted)
```

`mem_wait_o` 应覆盖 request 等待接受和 accepted 后等待 response 两段，本质上可以写成：

```text
mem_wait_o = mem_access && !transaction_complete
```

若 data subsystem 支持 0 wait-state，可以出现 request accepted 和 response valid 同拍。该情况需要在实现中明确是否允许：

- 建议第一版允许 `ready=1` 且同拍 `resp_valid=1`，便于 0 wait-state 回归。
- 若实现上先简化为“accepted 后至少下一拍 response”，则 0 wait-state 行为会多一拍，需明确并更新验证期望；当前不推荐，因为会不必要地改变现有回归时序。
- 若支持同拍 response，状态更新应在 `request_accepted && lsu_resp_valid_i` 时保持 `req_outstanding_q=0`，不要先置 outstanding 再多等一拍。

### 3.9 load data 生成改为 response 驱动 `已完成`

`load_raw` 的输入从 `lsu_rdata_i` 改为完成 response 的 `lsu_resp_rdata_i`。

只有 `transaction_complete && !lsu_resp_error_i && mem_re_i` 时，load_data 对后续 WB 有意义。

response 未到时：

- `valid_o` 不应让该 load 进入 MEM/WB。
- `load_data_o` 可给默认值，但不应被使用。

### 3.10 delayed access fault 生成 `已完成`

response error 转换为：

```text
load  -> EXCEPTION_CAUSE_LOAD_ACCESS_FAULT
store -> EXCEPTION_CAUSE_STORE_ACCESS_FAULT
tval  -> alu_result_i
```

`exception_valid_o` 需要覆盖：

```text
前级 exception
| mem_misaligned
| (transaction_complete && lsu_resp_error_i)
```

注意：

- response error 只在 completion 边界产生。
- request wait 或 outstanding wait 期间不要提前产生 access fault。
- error response 不允许写 rd。
- 当前 RTL 中 access fault 由 `lsu_resp_valid_i && lsu_resp_error_i` 门控生成；data-side 协议要求 `lsu_resp_valid_i` 只对应当前已接受事务，因此在协议约束下等价于 `transaction_complete && lsu_resp_error_i`。后续 SVA 应检查 response 必须对应 accepted/outstanding request。

### 3.11 `valid_o` 口径 `已完成`

`valid_o` 送入 MEM/WB，应表示“当前 MEM 指令本拍可以进入下一阶段的普通 WB 生命周期”。

建议：

```text
valid_o = valid_i && !mem_wait_o
```

但 trap/MRET 的 `kill_mem_wb` 仍由 `trap_ctrl` 最终决定是否阻止写入 MEM/WB。

对于 response error，`valid_o` 可以为 1，让 trap_ctrl 在同拍看见 exception 并用 `kill_mem_wb` 阻止普通 WB；也可以由 core 用 trap kill 清掉。关键是不要让 error load 写 rd。

### 3.12 观察信号更新 `无变动`

当前 `mem_access_fault_o/load_access_fault_o/store_access_fault_o` 是固定响应观察口。0834 后语义改为：

- `mem_access_fault_o`：completion 边界 response error。
- `load_access_fault_o`：load response error。
- `store_access_fault_o`：store response error。

若保留这些端口，注释必须同步为 delayed response error，不再写“地址未定义或权限不对同拍返回”。

## 4. core 顶层接线与流水线 backpressure `已完成`

### 4.1 修改 `rtl/core/core.sv` LSU 顶层端口 `已完成`

替换当前 LSU 固定响应接口：

```systemverilog
output logic            lsu_re_o;
output logic            lsu_we_o;
output logic [3:0]      lsu_be_o;
output logic [XLEN-1:0] lsu_addr_o;
output logic [XLEN-1:0] lsu_wdata_o;
input  logic [XLEN-1:0] lsu_rdata_i;
input  logic            lsu_access_fault_i;
```

改为：

```systemverilog
output logic            lsu_req_valid_o;
input  logic            lsu_req_ready_i;
output logic            lsu_req_write_o;
output logic [3:0]      lsu_req_be_o;
output logic [XLEN-1:0] lsu_req_addr_o;
output logic [XLEN-1:0] lsu_req_wdata_o;
input  logic            lsu_resp_valid_i;
input  logic [XLEN-1:0] lsu_resp_rdata_i;
input  logic            lsu_resp_error_i;
```

注释同步说明：IMEM 仍固定响应，LSU data side 为 simple request/response。

### 4.2 接入 `mem_stage` 的 clk/rst 和新接口 `已完成`

`u_mem_stage` 实例新增：

```systemverilog
.clk_i  (clk_i),
.rst_n_i(rst_n_i),
```

并连接新 request/response 信号。

### 4.3 新增 `mem_wait` 控制信号 `已完成`

core 内部新增：

```systemverilog
wire mem_wait;
wire mem_complete; // 可选
```

`mem_wait` 来自 `mem_stage.mem_wait_o`。

### 4.4 新增 `pipeline_ctrl.sv` 统一整合 stall/flush/backpressure `已完成`

memory wait 时需要保持：

```text
PC
IF/ID
ID/EX
EX/MEM
```

不建议在 `core.sv` 顶层分散 OR 各级 stall。新增 `rtl/core/pipeline_ctrl.sv`，作为流水线控制整合层：

```text
pipeline_ctrl
  - 内部实例化 hazard_unit
  - 复用现有 late-result-use stall 与 EX redirect flush 逻辑
  - 接收 MEM wait 形成的 backpressure
  - 汇总非 trap 类 PC redirect 来源
  - 统一输出最终 PC/IF_ID/ID_EX/EX_MEM stall 和 IF_ID/ID_EX flush
```

`hazard_unit` 保持局部 hazard 检测定位，主要负责：

```text
load-use / CSR-use late-result stall
允许后的 EX redirect flush
```

`pipeline_ctrl` 新增或整合输入：

```text
mem_wait_i = mem_wait
ex_redirect_valid_i
ex_redirect_pc_i
```

第一版非 trap redirect 来源只有 EX 阶段 branch/JAL/JALR。后续如果出现 ID 阶段 redirect、预测修正或其他非 trap 类 PC redirect，可以继续收敛到 `pipeline_ctrl` 内部仲裁。

并统一输出：

```text
stall_pc_o
stall_if_id_o
stall_id_ex_o
stall_ex_mem_o
stall_mem_wb_o
flush_if_id_o
flush_id_ex_o
nontrap_redirect_valid_o
nontrap_redirect_pc_o
```

第一版输出语义：

```text
stall_mem_backpressure = mem_wait_i

stall_pc_o     = stall_late_result_use | stall_mem_backpressure
stall_if_id_o  = stall_late_result_use | stall_mem_backpressure
stall_id_ex_o  = stall_mem_backpressure
stall_ex_mem_o = stall_mem_backpressure
stall_mem_wb_o = stall_mem_backpressure

nontrap_redirect_valid_o = ex_redirect_valid_i && !mem_wait_i
nontrap_redirect_pc_o    = ex_redirect_pc_i
flush_if_id_o            = ex_redirect_valid_i && !mem_wait_i
flush_id_ex_o            = ex_redirect_valid_i && !mem_wait_i
```

`core.sv` 只连接 `pipeline_ctrl` 的最终控制输出，不在顶层重复组合这些 stall 条件。

`pipe_reg_mem_wb` 当前也接入 `stall_mem_wb_o`。它的作用不是阻止当前 MEM 指令进入 WB，而是在 MEM wait 期间保留已有 MEM/WB 槽作为 forwarding source。为避免被 hold 的 MEM/WB 重复提交，MEM/WB 需要额外输出 `commit_valid_o` 或等效信号：

```text
mem_wb_valid        = MEM/WB 槽内容有效，可作为 forwarding source。
mem_wb_commit_valid = 本拍允许 WB/commit trace 使用该槽，只提交一次。
```

`wb_stage.valid_i` 应接 `mem_wb_commit_valid` 或等效提交 valid；forwarding_unit 仍使用 `mem_wb_valid` 判断 MEM/WB 是否可作为旁路来源。

### 4.5 load-use/CSR-use 与 memory wait 的关系 `无需改动`

`hazard_unit` 仍负责：

```text
ID 阶段 consumer vs ID/EX late-result producer
```

memory wait 负责：

```text
producer 已到 MEM 且 response 未完成时，冻结整条前端/EX 路径
```

实现时不要用固定数量 bubble 处理可变延迟 load-use；load-use 只需要阻止 consumer 过早进入 EX，后续等待由 `mem_wait` 接管。

### 4.6 非 trap redirect 与 memory wait 的屏蔽 `已完成`

当前：

```systemverilog
redirect_valid = trap_redirect_valid | ex_redirect_valid;
```

0834 后需要防止 memory wait 期间 younger 非 trap redirect 越过 older MEM 指令。当前非 trap redirect 来源只有 EX 阶段 branch/JAL/JALR，后续可以在 `pipeline_ctrl` 内继续扩展其他非 trap redirect 来源。

`pipeline_ctrl` 第一版形成：

```text
nontrap_redirect_valid = ex_redirect_valid && !mem_wait
nontrap_redirect_pc    = ex_redirect_pc
```

`pipeline_ctrl` 应使用 `mem_wait` 屏蔽 EX 边界 non-trap redirect 对 PC 和 flush 的影响。这样 memory wait 期间 younger EX redirect 不会产生 flush，也不会越过 older MEM 指令改变前端状态。

core 顶层最终 PC redirect 仍保持 trap/MRET 优先：

```text
redirect_valid = trap_redirect_valid | nontrap_redirect_valid
redirect_pc    = trap_redirect_valid ? trap_redirect_pc : nontrap_redirect_pc
```

`pipeline_ctrl` 不决定 trap/MRET redirect，也不产生 trap kill；这些仍由 `trap_ctrl` 负责。

注意 response OK 同拍：

- 如果 `mem_wait` 在 response valid 当拍降为 0，则 younger EX redirect 可以在该拍生效。
- 如果同拍 trap/interrupt 被接受，trap redirect 优先，younger redirect 被 kill。

### 4.7 trap_ctrl 只在 MEM completion 边界工作 `已完成`

`trap_ctrl.mem_valid_i` 当前接 `ex_mem_valid`。0834 后如果 memory wait 期间 `ex_mem_valid=1`，但 response 未完成，不能接受 interrupt，也不能让 MRET/CSR 同拍 interrupt提前发生。

需要新增或使用一个 completion-gated valid：

```text
mem_commit_valid = ex_mem_valid && !mem_wait
```

`trap_ctrl.mem_valid_i` 应接 `mem_commit_valid` 或等效信号。

这样：

- 非访存指令 `mem_wait=0`，trap_ctrl 行为不变。
- misaligned/前级 exception `mem_wait=0`，trap_ctrl 立即处理。
- load/store 等 response 时 `mem_wait=1`，trap_ctrl 不接受 interrupt/MRET/trap。
- response error/OK 当拍 `mem_wait=0`，trap_ctrl 在 completion 边界处理。

### 4.8 CSR 写提交语义保持 `防御性改动完成`

`mem_csr_valid` 当前为：

```systemverilog
ex_mem_valid & ex_mem_data_q.csr & ~mem_exception_valid
```

0834 后建议改为 completion-gated：

```text
mem_csr_valid = mem_commit_valid && ex_mem_data_q.csr && !mem_exception_valid
```

CSR 写不应在 MEM 前面有 outstanding memory wait 时提前提交。

### 4.9 MEM/WB valid 口径 `无需改动`

`pipe_reg_mem_wb.valid_i` 当前接 `mem_valid`。0834 后 `mem_valid` 应已经由 `mem_stage` 在 completion 边界给出。

需要检查：

- memory wait 期间 MEM/WB 不接收当前 load/store。
- response OK 后 load/store 进入 MEM/WB。
- response error / exception / MRET 由 `kill_mem_wb` 阻止普通 WB。
- interrupt 不 kill 当前已完成旧指令写回，保持 0833 口径。

### 4.10 MEM/WB forwarding source 与 commit valid 分离 `已完成`

可变延迟后，ID/EX 可能被 memory wait hold 多拍。ID/EX 中保存的是 decode 时采样的 `rs*_rdata`，不会在 hold 期间重新读 GPR。

如果 MEM/WB 中的 older producer 在 memory wait 期间自然流走，而 ID/EX 中的 younger consumer 仍然等待，那么 wait 解除后 forwarding_unit 可能看不到 MEM/WB producer，只能使用 ID/EX 里保存的旧操作数。

当前实现采用：

```text
MEM/WB 在 memory wait 期间 hold，继续作为 forwarding source。
MEM/WB 额外给出 commit_valid，避免 hold 期间重复写回/重复提交。
```

具体口径：

- `pipeline_ctrl` 输出 `stall_mem_wb_o = stall_mem_backpressure`。
- `pipe_reg_mem_wb.valid_o` 保留槽有效性，供 forwarding_unit 使用。
- `pipe_reg_mem_wb.commit_valid_o` 表示本拍是否真正进入 WB/commit。
- `wb_stage.valid_i` 使用 `mem_wb_commit_valid`。
- forwarding_unit 仍使用 `mem_wb_valid`。

这个实现把“旁路来源仍有效”和“本拍执行架构提交”分开，既解决 memory wait 下 forwarding 来源过早消失的问题，也避免 MEM/WB 被 hold 时重复写 rd。

### 4.11 forwarding 的 EX/MEM load 可前递口径 `无需改动`

当前 forwarding_unit 会避免从 EX/MEM 前递 load/CSR 晚结果，转而依赖 MEM/WB。

0834 下 load 在 response OK 后才进入 MEM/WB，因此原口径基本保持。

需要检查：

- memory wait 期间 ID/EX 被 hold，consumer 不会继续执行。
- response OK 后下一拍进入 MEM/WB，consumer 解除 hold 后可从 MEM/WB forwarding 或 GPR bypass 得到 load 值。
- 不要新增从 EX/MEM 对 load response 的组合前递，除非有明确必要。

## 5. `hazard_unit` 控制语义同步 `已由4.4/4.6吸收`

0834 原计划中，这一章准备继续让 `hazard_unit` 同时处理 late-result-use stall 和已允许的 EX redirect flush。

实际实现采用了更清晰的分层：

```text
hazard_unit
  只检测 load-use / CSR-use late-result-use RAW hazard。

pipeline_ctrl
  内部实例化 hazard_unit。
  统一整合 late-result-use stall、MEM wait backpressure、non-trap redirect 和 flush。
  memory wait 期间屏蔽 younger non-trap redirect。
```

因此，第 5 章不再作为独立 RTL 步骤执行；相关设计已经并入第 4.4 和第 4.6。

已完成内容：

- `hazard_unit` 保留 late-result-use 检测主体，输出 `stall_late_result_use_o`。
- `pipeline_ctrl` 根据 `stall_late_result_use_o` 生成 PC/IF_ID stall 和 ID_EX bubble。
- `pipeline_ctrl` 根据 `mem_wait_i` 生成 PC/IF_ID/ID_EX/EX_MEM backpressure。
- `pipeline_ctrl` 根据 `ex_redirect_valid_i && !mem_wait_i` 生成当前 EX 边界 non-trap redirect 和 IF_ID/ID_EX flush。

该实现比原计划更好，因为 `hazard_unit` 保持局部 hazard 检测职责，`pipeline_ctrl` 承担流水线控制整合职责，后续新增 ID redirect、预测修正或其他 non-trap redirect 来源时，可以继续收敛到 `pipeline_ctrl`。

## 6. `pipe_reg` 注释和 stall 优先级确认 `已完成`

### 6.1 确认现有优先级是否适配 memory wait `无需改动`

当前优先级：

```text
IF/ID:  reset > kill > flush > stall > normal
ID/EX:  reset > kill > flush > stall > bubble > normal
EX/MEM: reset > kill > stall > normal
MEM/WB: reset > kill > stall > normal
```

该优先级对 0834 基本可用。

重点确认：

- kill 优先于 stall：trap/interrupt/MRET 接受时，年轻指令不能因 stall 被保留。
- flush 优先于 stall：被允许的 EX redirect 需要清掉错误路径。
- stall 优先于 bubble：memory wait 时不要插入 bubble 丢失当前年轻指令状态。

### 6.2 更新注释 `已完成`

`rtl/core/pipe_reg.sv` 中 stall 相关注释已按 0834 实际用途同步：

- `ID/EX.stall_i` 用于 memory wait backpressure。
- `EX/MEM.stall_i` 用于保持 outstanding transaction 对应的 MEM 指令。
- `MEM/WB.stall_i` 用于 memory wait 期间保持已有 MEM/WB forwarding source。
- `MEM/WB.commit_valid_o` 或等效提交 valid 用于避免被 hold 的 MEM/WB 重复 WB/commit。

## 7. data_subsystem simple data bus 骨架与最小 wait-state `已完成`

本章按当前实际实现路径推进：先在 `data_subsystem` 内完成 0 wait-state 的 simple bus 骨架，再只给 DMEM 加最小可变延迟；DMEM 跑通后，再把同一模式推广到 MMIO wrapper。这样每一步都可仿真验证，不要求一开始就拆出完整 target slave 模块。

### 7.1 修改 `rtl/soc/data_subsystem.sv` core 侧端口 `已完成`

替换当前固定响应 core 接口：

```systemverilog
input  logic                      core_re_i;
input  logic                      core_we_i;
input  logic [3:0]                core_be_i;
input  logic [XLEN-1:0]           core_addr_i;
input  logic [XLEN-1:0]           core_wdata_i;
output logic [XLEN-1:0]           core_rdata_o;
output logic                      core_access_fault_o;
```

改为：

```systemverilog
input  logic                      core_req_valid_i;
output logic                      core_req_ready_o;
input  logic                      core_req_write_i;
input  logic [3:0]                core_req_be_i;
input  logic [XLEN-1:0]           core_req_addr_i;
input  logic [XLEN-1:0]           core_req_wdata_i;
output logic                      core_resp_valid_o;
output logic [XLEN-1:0]           core_resp_rdata_o;
output logic                      core_resp_error_o;
```

旧端口不再作为真实接口使用，后续统一清理注释和顶层连接。

### 7.2 建立 accepted request 脉冲 `已完成`

使用 `core_req_valid_i && core_req_ready_o` 表示 data_subsystem 真正接受了一次 core request：

```systemverilog
req_accept_fire = core_req_valid_i & core_req_ready_o;
req_re_accept   = req_accept_fire  & !core_req_write_i;
req_we_accept   = req_accept_fire  &  core_req_write_i;
```

`req_accept_fire` 是脉冲，不是可保持 valid。后续 DMEM 写、外设访问脉冲、观察口和 response target 锁存都基于它。

### 7.3 完成 0 wait-state response mux 骨架 `已完成`

当前先保持所有 target 0 wait-state，同拍接受 request、同拍返回 response。该步骤已经完成并通过既有仿真。

已建立的关键口径：

- 组合译码 `target`，区分 `TARGET_DMEM/GPIO0/UART0/TIMER0/UNDEFINED`。
- `req_dmem_valid/req_gpio0_valid/req_uart0_valid/req_timer0_valid/req_undefined_valid` 表示各 target 的 accepted pulse。
- `resp_pending_q/resp_target_q` 用于多拍 response 时记住 response 来源。
- `resp_target = resp_pending_q ? resp_target_q : target`，支持 0 wait-state 空直通。
- 各 target 当前先用 `resp_*_valid = req_*_valid` 形成同拍 response。
- `core_resp_valid_o/core_resp_rdata_o/core_resp_error_o` 统一通过 `resp_target` mux 返回。

这个中间态的目标是让 simple bus 语义先与原固定响应行为等价，后续再逐个 target 加延迟。

### 7.4 给 DMEM 增加最小可变延迟 `已完成`

下一步只改 DMEM target，先不要同时改 GPIO/UART/TIMER。目标是验证 core 的 MEM wait/backpressure 能处理真正多拍 data response。

先在 `data_subsystem.sv` 内部实现 DMEM 小状态机即可，不急着拆文件：

```text
req_dmem_valid 当拍：
  - write：仍在 accepted 当拍写 simple_ram 一次。
  - read：锁存 dmem_rdata_i。
  - 采样 DMEM delay。
  - 若 delay=0，同拍 resp_dmem_valid。
  - 若 delay>0，进入 dmem_pending_q，counter 到期后拉高 resp_dmem_valid 一拍。
```

建议先用局部常量或 parameter 验证：

```systemverilog
localparam int unsigned DMEM_RESP_DELAY_CYCLES = 0;
```

跑通后再改成 TB/SoC 输入。

本步骤完成标准：

- `DMEM_RESP_DELAY_CYCLES=0` 时，既有仿真继续 PASS。
- `DMEM_RESP_DELAY_CYCLES>0` 时，load 能等待 response 后写回。
- store 不因为等待 response 重复写。
- `resp_pending_q` 在 DMEM 多拍等待期间保持为 1，`core_req_ready_o=0`。
- `core_resp_valid_o` 在延迟结束时只拉高一拍。

### 7.5 修正 request/response 观察口口径 `已完成`

DMEM 多拍后，request accepted 与 response valid 不再等价。观察口需要明确：

```text
dmem_access_o = req_dmem_valid
mmio_access_o = req_gpio0_valid | req_uart0_valid | req_timer0_valid
```

也就是说，`dmem_access_o/mmio_access_o` 先表示 accepted request 命中，而不是 response 返回。TB mailbox 第一版也按 accepted DMEM write request 监听。

若后续需要 response 观察，再新增或复用：

```text
data_req_fire_o
data_resp_valid_o
data_resp_error_o
```

### 7.6 增加 TB 可配置 DMEM delay 输入 `已完成`

DMEM 常量版本跑通后，把 DMEM delay 改成由 SoC/TB 驱动的输入，默认 0。

建议接口：

```systemverilog
input logic [6:0] dmem_resp_delay_cycles_i;
```

采样规则：

- `req_dmem_valid` 当拍采样当前 delay。
- 已经 pending 的 DMEM response 使用锁存的 counter，不受后续修改影响。
- TB mailbox 后续修改 delay 只影响之后的新 DMEM request。

### 7.7 处理 unknown address response `已完成`

未映射地址先保持 0 wait-state error response：

```text
resp_undefined_valid = req_undefined_valid
resp_undefined_rdata = 0
resp_undefined_error = 1
```

该路径不产生 DMEM/MMIO 副作用。后续若要验证 delayed unknown address fault，可以按 DMEM delay 状态机复制一个 `undefined_pending_q`。

### 7.8 给 MMIO 增加最小 wrapper/delay `已完成`

DMEM 多拍跑通后，再处理 MMIO。当前 GPIO/UART/TIMER32 本体接口不改，仍是固定响应 register block；先在 `data_subsystem.sv` 内部为 MMIO target 加 wrapper 逻辑：

```text
req_gpio0_valid/req_uart0_valid/req_timer0_valid 当拍：
  - 对固定响应外设打一拍 valid/re/we。
  - 同拍锁存 rdata/access_fault。
  - 根据该 target 对应的 resp_delay_cycles_i 决定同拍 response 或延迟 response。
```

重点保证：

- request valid 保持多拍时，外设访问脉冲只发生在 accepted 当拍。
- response 延迟期间不重复触发 UART TX、UART RXDATA 读清、GPIO W1C、TIMER32 写寄存器。
- unknown offset 的 `access_fault_o` 被锁存为 delayed `resp_error`。

实际实现采用每个 data target 独立 delay 配置：

```text
dmem_resp_delay_cycles_i
gpio0_resp_delay_cycles_i
uart0_resp_delay_cycles_i
timer0_resp_delay_cycles_i
```

这样可以分别覆盖 DMEM、GPIO0、UART0、TIMER0 的 wait-state 行为，同时保持固定响应外设本体接口不变。

### 7.9 后续是否拆出独立 simple slave 模块 `不拆分`

上述逻辑都可先内嵌在 `data_subsystem.sv` 中，便于逐步调试。等 DMEM/MMIO delay 都跑通后，再决定是否拆出：

```text
rtl/mem/simple_data_ram_slave.sv
rtl/soc/simple_mmio_slave_wrapper.sv
```

拆分目标是让 `data_subsystem` 最终更像 decoder/interconnect：

```text
core simple bus
-> data_subsystem decoder/interconnect
-> dmem/mmio simple slave
-> 固定响应 RAM 或外设本体
```

后续 FPGA BRAM、外部 SRAM controller、真实慢外设或 accelerator 可以直接实现 simple slave 接口，CPU 和 `data_subsystem` 主体不需要重写。

## 8. 外设寄存器块的事务副作用整理 `已完成`

### 8.1 保持外设 ABI 不变 `无需改动`

`rtl/periph/mmio_gpio.sv`、`rtl/periph/mmio_uart.sv`、`rtl/periph/mmio_timer32.sv` 的软件可见寄存器地址、位定义和读写属性不变。

本阶段只调整外设访问时序口径，不改变寄存器地址、位定义、读写属性和中断行为。

### 8.2 固定采用 wrapper 路线：外设本体仍是固定响应 register block `无需改动`

第一版不改 `mmio_gpio/mmio_uart/mmio_timer32` register block 本体接口，而是在每个外设外层加 simple slave wrapper：

```text
core simple bus
-> data_subsystem decoder/interconnect
-> periph_simple_slave wrapper
-> 固定响应外设 register block
```

wrapper 负责 request/ready/response、wait-state、rdata/error 锁存和 accepted pulse 生成。外设 register block 只在 wrapper accepted request 的一个脉冲上被访问一次。

这样既能先把 CPU backpressure 和 data bus 语义跑通，也能让后续真实慢外设或 accelerator 直接实现 simple slave 接口，而不必改变 CPU/data_subsystem 主体。

### 8.3 外设访问脉冲连接规则 `已完成`

外设 wrapper 给固定响应 register block 的 `valid_i/re_i/we_i` 必须来自该 wrapper 的 accepted pulse：

```systemverilog
periph_req_fire = req_valid_i && req_ready_o;

periph_valid = periph_req_fire;
periph_re    = periph_req_fire && !req_write_i;
periph_we    = periph_req_fire &&  req_write_i;
```

这能保证：

- ready=0 时不触发副作用。
- request valid 保持多拍时不重复触发副作用。
- response 延迟期间不重复触发副作用。

外设 wrapper 头注释需要说明：固定响应外设本体的 `valid_i` 是一次 accepted MMIO transaction 的访问脉冲，而不是可保持的 bus valid。

### 8.4 unknown offset 不产生副作用 `已完成`

当前外设一般先写寄存器，再由 `offset_illegal` 输出 access_fault。0834 需要检查所有外设：

- unknown offset 时 `access_fault_o=1`。
- unknown offset 时不写 RW/RW1C/WO。
- unknown offset read 不触发读副作用。
- unknown offset write 不触发 TX event、W1C clear 等副作用。

若现有代码已经通过 `rw_hit/wo_hit/rw1c_hit` 门控写副作用，需要确认读副作用是否也只在合法 offset 下触发。

### 8.5 UART RXDATA 读副作用采样点 `已完成`

第一版采用：

```text
request accepted 时采样读数据；
response OK 时软件认为 read 完成；
读副作用最多触发一次。
```

若外设仍固定响应、wrapper 在 accepted 当拍访问外设，则 UART RXDATA 的读清会发生在 accepted 当拍，而 response 可能稍后返回。

这种实现可以接受，但必须在文档/注释中明确为：

```text
外设寄存器访问在 wrapper accepted request 时发生；response 延迟只表示 CPU completion 延迟。
```

本阶段不做 response OK 时才清 pending 的 delayed commit 版本，避免把固定响应外设改成完整事务外设。

### 8.6 UART TX event `已完成`

写 UART TXDATA 应只在 accepted pulse 且 offset 合法时产生一个 `tx_valid_o` 脉冲。

需要重点检查：

- `tx_valid_o` 不因 response 延迟重复拉高。
- `tx_valid_o` 不因 request valid 等 ready 重复拉高。
- unknown offset 或 `be_i[0]=0` 不产生 TX event。

### 8.7 GPIO W1C 和 pending set `已完成`

GPIO 的中断 pending 硬件 set 仍按同步输入每拍运行，不受 bus wait 影响。

软件 W1C clear 只在 accepted pulse 且 offset 为 IRQ_PENDING 时执行一次。

同拍 set/clear 优先级保持当前实现：硬件 set 优先。

### 8.8 TIMER32 计数 `无需修改`

TIMER32 自增仍按 `clk_i` 运行，不因为 CPU bus wait 暂停。

写 MTIME 的“本拍不自增”、写非 MTIME 时允许自增的语义保持。

### 8.9 外设注释和手册同步 `已完成`

三个外设头注释需要统一说明：

- `valid_i` 是外设 wrapper 在 request accepted 当拍产生的一拍访问脉冲。
- 外设寄存器访问和读写副作用发生在 accepted 当拍。
- wrapper 的 response 延迟只影响 CPU 看到 completion 的时间，不会让外设重复访问。

`rtl/periph/readme.md` 若已有“外设寄存器访问为固定响应”表述，需要改为更通用的说法：

- 软件 ABI 不变。
- 在 0834 simple data bus 平台中，寄存器访问由外设 simple slave wrapper 在 accepted request 当拍提交给外设本体。
- 未知 offset 仍由各外设 `access_fault_o` 上报，并在 data_subsystem 中转换为 bus response error。

若采用 accepted pulse 访问外设，则“本拍”指 request accepted 那一拍，而不是 response 返回那一拍。

## 9. SoC 顶层接口和观察口 `执行中`

### 9.1 修改 `rtl/soc/rv32i_soc.sv` core/data_subsystem 连接 `已完成`

SoC 顶层需要连接新的 simple data bus：

```text
core.lsu_req_* <-> data_subsystem.core_req_*
core.lsu_resp_* <-> data_subsystem.core_resp_*
```

IMEM 仍保持固定响应接口，`simple_rom` 继续由 testbench 实例化并连接到 `rv32i_soc` 的 IMEM 端口。

SoC 顶层同时透出四个 data target response delay 配置输入，并连接到 `data_subsystem`：

```text
dmem_resp_delay_cycles_i
gpio0_resp_delay_cycles_i
uart0_resp_delay_cycles_i
timer0_resp_delay_cycles_i
```

四个输入分别控制 DMEM、GPIO0、UART0、TIMER0 的 response delay，默认由 testbench 置 0 时保持 0 wait-state 行为。该实现比原先单一 `mmio_resp_delay_cycles_i` 更便于定向测试分别覆盖 DMEM 与不同 MMIO target 的 backpressure 行为。

### 9.2 更新 data 观察输出 `已完成`

当前 SoC 输出：

```text
data_re_o
data_we_o
data_be_o
data_addr_o
data_wdata_o
data_rdata_o
data_access_fault_o
dmem_access_o
mmio_access_o
```

0834 后调整为兼容 testbench 的 simple data bus 观察口：

```text
data_req_valid_o
data_req_ready_o
data_req_write_o
data_req_be_o
data_req_addr_o
data_req_wdata_o
data_resp_valid_o
data_resp_rdata_o
data_resp_error_o
dmem_access_o
mmio_access_o
```

新观察口不再沿用 `data_re_o/data_we_o/data_access_fault_o` 等旧固定响应命名，避免把 request 意图、response completion 和 response error 混在一起。

### 9.3 中断连接保持不变 `无需改动`

GPIO/UART/TIMER0 中断汇总：

```text
MEIP = gpio0_irq_o | uart0_irq_o
MTIP = timer0_irq_o
```

保持不变。

memory wait 期间中断 pending 可继续进入 CSR `mip`，core 只在 MEM completion 边界接受。

### 9.4 头注释同步 `已完成`

`rv32i_soc.sv` 头注释需要从“固定响应平台集成”改为：

- IMEM 固定响应。
- data side 使用 simple request/response。
- data_subsystem 支持可配置 wait-state/backpressure。
- SoC 顶层透出 DMEM/GPIO0/UART0/TIMER0 四个 response delay 配置输入。
- data 观察口按 request/response 分组命名。
- 外设寄存器 ABI 不变。

## 10. trap/interrupt 精确语义检查点 `检查无误`

### 10.1 delayed access fault

在 `mem_stage`、`core`、`trap_ctrl` 组合后，需要确认：

```text
response error load:
  mcause = load access fault
  mepc   = faulting load PC
  mtval  = faulting address
  rd 不写

response error store:
  mcause = store access fault
  mepc   = faulting store PC
  mtval  = faulting address
  store 不产生成功副作用
```

### 10.2 interrupt 等待 completion

memory wait 期间：

- `mip` 可以反映 pending。
- `trap_ctrl` 不应接受 interrupt。
- `trap_valid_o` 不应因为 pending interrupt 拉高。

response OK 当拍：

- 若 interrupt enable/pending 满足，按 0833 规则接受 interrupt。
- 当前 load/store 已完成后再进入 interrupt。
- interrupt 不 kill 当前旧指令普通 WB。

response error 当拍：

- access fault exception 优先。
- interrupt 保持 pending，不能同拍抢先进入 handler。

### 10.3 MRET/CSR 写同拍 interrupt

0833 语义保持：

```text
CSR 写+interrupt：先提交 CSR 写，用 commit view 判断并跳到可能更新后的 mtvec。
MRET+interrupt：先恢复 mstatus，interrupt mepc 使用 MRET 原本要返回的 mepc。
```

0834 只新增一个约束：

```text
若它们前面有 older memory wait，则这些 younger 指令不能越过 older memory 指令。
```

### 10.4 younger redirect

需要在波形中能看到：

- MEM wait 时 EX 阶段 younger branch 结果可存在，但不会更新 PC。
- response OK 且无 trap/interrupt 时，younger redirect 才能生效。
- response error 或 interrupt accepted 时，younger redirect 被 kill。

## 11. simple_ram 和 memory 模型处理 `已完成`

### 11.1 `simple_ram.sv` 行为保持不变 `无需改动`

当前 `simple_ram` 是仿真 RAM 模型：

- 写同步。
- 读组合。
- 地址按 `DMEM_BASE` 映射到内部 word index。

0834 第一版不改 `simple_ram`，仍由 testbench 实例化。`simple_ram` 继续作为固定响应 DMEM model，response wait-state 由 `data_subsystem` 内部 wrapper 注入。

### 11.2 DMEM simple slave wrapper 实现方式 `已完成`

原计划建议新增：

```text
rtl/mem/simple_data_ram_slave.sv
```

职责：

- 接 simple data bus 子集。
- 连接外置 simple_ram 或后续可替换 memory model。
- 支持 TB 配置的 wait-state。
- 保存 pending response 的 rdata/error/counter。
- 后续 FPGA BRAM 同步读或外部 SRAM controller 可以收敛在该 wrapper 内替换。

实际实现没有新增独立 `rtl/mem/simple_data_ram_slave.sv`，而是在 `data_subsystem.sv` 中内嵌统一 response delay wrapper：

```text
core simple bus
-> data_subsystem 地址译码
-> 固定响应 DMEM/MMIO target accepted pulse
-> 统一 response delay wrapper
-> core response
```

该实现同时覆盖 DMEM、GPIO0、UART0、TIMER0 四个 target，并通过四个独立 delay 输入控制：

```text
dmem_resp_delay_cycles_i
gpio0_resp_delay_cycles_i
uart0_resp_delay_cycles_i
timer0_resp_delay_cycles_i
```

当前阶段不拆独立 slave 文件更适合逐步调试，也避免在 AXI-Lite、FPGA BRAM、外部 SRAM controller 或 accelerator 接入前过早固化 wrapper 接口。后续如果需要独立 SVA、随机 wait-state slave、真实同步 RAM wrapper 或 AXI-Lite bridge，再拆出 `simple_data_ram_slave` 或通用 simple slave wrapper。

### 11.3 DMEM write 副作用时机 `已完成`

当前 DMEM store 在 request accepted 当拍通过外置 `simple_ram` 写入，但 response 可以延迟返回，软件可见 completion 在 response OK。

这对单 master、单 outstanding、无异常 DMEM 命中场景可接受。

但需要保证：

- 未映射地址不会写。
- MMIO unknown offset 不会写。
- accepted 只发生一次。

当前实现满足：

- 未映射地址不会产生 DMEM 写。
- MMIO unknown offset 由外设 offset decode 和 wrapper response error 处理，不产生对应寄存器副作用。
- `req_accept_fire` 只打一拍，DMEM/MMIO accepted 副作用不会因 response delay 重复发生。

## 12. 注释和文档同步 `基本完成`

### 12.1 RTL 头注释必须同步的文件 `已完成`

已同步：

- `rtl/core/core.sv`
- `rtl/core/mem_stage.sv`
- `rtl/core/hazard_unit.sv`
- `rtl/core/pipe_reg.sv`
- `rtl/soc/data_subsystem.sv`
- `rtl/soc/rv32i_soc.sv`
- `rtl/periph/mmio_gpio.sv`
- `rtl/periph/mmio_uart.sv`
- `rtl/periph/mmio_timer32.sv`

本阶段没有新增 `rtl/mem/simple_data_ram_slave.sv` 或独立外设 simple slave wrapper，因此无对应文件头注释需要同步。

重点删除或改写以下过时口径：

```text
固定响应
没有 ready/valid backpressure
mem_stage 是纯组合逻辑
access_fault 同拍返回
valid_i 是保持的访问信号
```

### 12.2 `rtl/periph/readme.md` `已完成`

外设寄存器 ABI 不变，因此手册主体不应大改。

需要补充或检查：

- 外设手册面向软件，不写 RTL 事务实现细节。
- 说明在支持 wait-state 的平台上，寄存器读写可能不是固定周期。
- 若采用 wrapper accepted 时触发外设访问，读副作用/写副作用的软件语义仍是“一次成功访问最多一次”，不要求软件关心 accepted/response 内部时序。
- unknown offset 仍表现为 load/store access fault。

### 12.3 README 当前特性 `暂缓，定向验证无误后补充`

0834 完成后更新 README：

- 当前特性新增 data-side variable-latency / simple data bus / MEM backpressure。
- 系统架构图中 `data_subsystem: fixed DMEM/MMIO decoder` 改为 simple data bus decoder/interconnect，并体现 DMEM/MMIO simple slave wrapper。
- 项目时间戳新增 v5.1 或 v6.0，具体版本号由提交前统一决定。

本项等顶层连接和基本验证通过后再补，避免 README 提前写入尚未收口的当前特性。

### 12.4 0834 文档 `已完成`

若实现与 `docs/08xx/0834 ...` 有差异，需要在完成后说明：

- 差异点。
- 为什么实现方案更适合当前代码。
- 经确认后同步 0834 文档或在 README/plan 中记录最终口径。

当前实现与 0834 文档口径一致：wait-state 建模可以放在 `data_subsystem` 或 responder/wrapper 层，不要求每个固定响应外设本体改成多拍状态机。实际采用 `data_subsystem` 内嵌统一 wrapper，是当前阶段更小、更易调试的实现方式。

## 13. 验证平台前提性准备 `已完成`

本阶段 RTL 写完后，具体功能验证方案另行规划。这里仅列验证平台必须先具备的基础能力，保证后续能继续沿用当前软件自检方式做 0 wait-state 回归和最小固定 wait-state smoke。

阶段5 再把这些基础能力扩展为更完整的 wait-state directed test、SVA、monitor/scoreboard 和 UVM simple-bus/peripheral demo。本阶段不展开具体测试矩阵。

### 13.1 SoC testbench 端口适配 `已完成`

`tb/sv/tb_rv32i_soc.sv` 需要先适配 `rv32i_soc` 的新版端口，保证平台能编译并跑 0 wait-state 回归。

SoC data 观察口从旧固定响应命名迁移到 request/response 分组命名：

```text
data_req_valid_o
data_req_ready_o
data_req_write_o
data_req_be_o
data_req_addr_o
data_req_wdata_o
data_resp_valid_o
data_resp_rdata_o
data_resp_error_o
dmem_access
mmio_access
```

TB 内部信号建议同步改名，避免继续使用 `data_re/data_we/data_access_fault` 表达 req/resp 语义。

SoC 顶层新增四个 response delay 输入，TB 必须驱动默认值：

```text
dmem_resp_delay_cycles_i   = 0
gpio0_resp_delay_cycles_i  = 0
uart0_resp_delay_cycles_i  = 0
timer0_resp_delay_cycles_i = 0
```

默认 0 wait-state 是回归基线。未接这些输入时不应让仿真依赖 X/隐式默认值。

### 13.2 trace/monitor 最低观察能力 `已完成`

TB 至少能观察并在必要时打印 request/response 边界、MEM wait 冻结和既有 commit/trap 信息。当前实现通过 SoC 暴露的 `mem_wait_o` 直接观察流水线因 data transaction 未完成而暂停的状态，不在 TB 中反推 wait 条件。

当前最低 trace 口径：

```text
REQ accepted: data_req_valid && data_req_ready
MEM_WAIT    : mem_wait_o，并打印 req_valid/req_ready/resp_valid/addr
RESP event  : data_resp_valid
commit_valid
trap_valid
trap_cause_code
trap_tval
```

`data_resp_error` 和 `data_resp_rdata` 当前不作为默认打印项。response error 会进入 trap 路径，默认由 trap trace 观察；只有后续调试需要定位数据返回值时，再临时打开更详细的 response 打印。

data access 打印需要区分：

```text
REQ accepted
MEM_WAIT
RESP event
COMMIT
TRAP
```

不要再把 request 发出或 accepted 当成 load/store 指令提交。

### 13.3 TB mailbox 监听点迁移 `使用 dmem 输入，无需修改`

当前 TB mailbox 通过：

```text
data_we && dmem_access
```

监听测试程序写 DMEM 命令地址。

0834 后要改为基于“被接受的 DMEM write request”或“成功完成的 DMEM write response”。

推荐：

```text
data_req_valid && data_req_ready && data_req_write && dmem_access
```

因为 TB mailbox 本身是 testbench 侧的外部激励命令，监听 request accepted 更直观，也不会受 response 延迟重复触发。

若后续要验证 store access fault 不产生 TB 命令副作用，则需要改为 successful response completion，并保存 accepted request 地址/数据。当前 mailbox 地址位于 DMEM 已实现区域，不会 fault，因此第一版用 accepted request 即可。

实现时需要用 accepted request 当拍的 `data_req_addr/data_req_wdata` 判断命令，不要用 response 当拍的地址数据组合信号，除非 TB 额外锁存 accepted request payload。

### 13.4 wait-state 注入入口 `已完成`

testbench 需要能配置 wait-state，并支持软件通过现有 TB mailbox 在运行中切换延迟。

最低要求：

- SoC/data_subsystem 透出由 TB 驱动的 delay 配置输入，默认值为 0，并分发到对应 target wrapper。
- TB 通过 `RESET_RESP_DELAY_CFG` 设置四个 target 的复位默认 delay 配置。默认值为 `32'h0000_0000`，即 DMEM/GPIO0/UART0/TIMER0 全部 0 wait-state；需要临时做非 0 初始 smoke 时，可以改该 localparam。
- TB mailbox 新增或扩展命令，软件写 mailbox 后，TB 动态更新一个或多个 target 的 delay 配置。
- delay 新值只影响后续新 accepted request；已经 pending 的 response 使用 target slave `req_fire` 当拍锁存的 delay/counter，不受后续修改影响。
- DUT 侧 delay 输入保持 7 bit 具体周期数，取值范围为 0..127；TB mailbox 协议使用每 target 8 bit 配置字段，其中 bit[6:0] 是周期参数，bit[7] 是随机模式使能。

TB mailbox 的 32-bit delay 配置字定义为：

```text
bits [ 7: 0] : DMEM   delay_cfg
bits [15: 8] : GPIO0  delay_cfg
bits [23:16] : UART0  delay_cfg
bits [31:24] : TIMER0 delay_cfg

delay_cfg[7]   = 0: 固定延迟模式，DUT delay = delay_cfg[6:0]
delay_cfg[7]   = 1: 随机延迟模式，TB 为后续 transaction 生成具体 7-bit delay
delay_cfg[6:0] = 固定延迟值，或随机模式下的随机上限
```

随机模式只属于 TB 激励协议。`rv32i_soc/data_subsystem` 不直接接收 bit7，也不把 `8'hff` 当成特殊值；它们只接收 TB 已经生成好的 7-bit 具体 delay。

随机延迟建议按 transaction 更新：某 target 的 request accepted 后，若该 target 处于随机模式，TB 生成下一次该 target request 使用的 delay。这样 DUT 在 accepted 当拍采样到的是稳定值，已经 pending 的 response 不会被随机刷新影响。

随机生成应可复现并受上限约束。后续若需要更灵活的命令行控制，可以再支持：

```text
+delay_rand_seed=<n>
+delay_rand_max=<n>
```

当前阶段不强制实现 plusarg；directed test 通过 `RESET_RESP_DELAY_CFG` 和 mailbox/helper 控制 wait-state。随机模式应使用小上限，避免 directed test 偶发 timeout。

推荐 mailbox 命令语义：

```text
set_resp_delay_cfg_0({timer0_cfg, uart0_cfg, gpio0_cfg, dmem_cfg})
```

这些命令只属于 TB 验证协议，不属于 SoC 软件 ABI，也不写入 `rtl/periph/readme.md` 的通用外设手册。

本阶段不要求完整随机验证矩阵，只要求 RTL/TB 具备 directed test 可控插入固定延迟和简单随机延迟的入口。更系统的随机/组合 wait-state 覆盖应放到 0835 的验证环境中展开。

### 13.5 保留现有 PASS/FAIL 自检机制 `已完成`

现有 `TEST_STATUS_ADDR` PASS/FAIL 机制保持。

memory wait 后，测试程序仍通过写 DMEM 状态字结束仿真。testbench 只需确保对该地址的监听不会因为 request valid 保持或 response 延迟重复触发。

### 13.6 0 wait-state 兼容优先 `已完成`

验证平台前提性准备的第一目标不是新增复杂测试，而是让当前全部 0 wait-state directed regression 可以重新编译并执行。

执行顺序建议：

1. 先完成 SoC/TB 端口适配，所有 delay 输入固定为 0。
2. 再迁移 TB mailbox 监听到 accepted DMEM write request。
3. 再增加四个 delay 配置寄存变量、`RESET_RESP_DELAY_CFG` 复位默认配置和 mailbox 控制入口。
4. 最后再写最小 wait-state smoke。

### 13.7 `tb_rv32i_soc_test.h` delay 配置 helper `已完成`

`sw/include/tb_rv32i_soc_test.h` 已补充当前 TB mailbox 的 wait-state 配置协议，供 C directed test 直接调用。

新增 mailbox 地址：

```c
#define TB_RESP_DELAY_CFG0_ADDR (TB_CMD_BASE + RV32I_U32_C(0x10))
```

delay 配置字段与 TB 保持一致：

```text
bits [ 7: 0] : DMEM   delay_cfg
bits [15: 8] : GPIO0  delay_cfg
bits [23:16] : UART0  delay_cfg
bits [31:24] : TIMER0 delay_cfg

delay_cfg[7]   = 0: 固定延迟模式，DUT delay = delay_cfg[6:0]
delay_cfg[7]   = 1: 随机延迟模式，TB 为后续 transaction 生成 0..delay_cfg[6:0] 的具体 7-bit delay
delay_cfg[6:0] = 固定延迟值，或随机模式下的最大值
```

C helper 建议提供 5 个面向语义的函数。函数参数不直接暴露 packed `delay_cfg`，而是拆成随机模式开关和 7-bit 周期参数：

```c
tb_set_dmem_resp_delay(bool random_en, uint8_t cycles_or_max);
tb_set_gpio0_resp_delay(bool random_en, uint8_t cycles_or_max);
tb_set_uart0_resp_delay(bool random_en, uint8_t cycles_or_max);
tb_set_timer0_resp_delay(bool random_en, uint8_t cycles_or_max);

tb_set_resp_delay(bool dmem_random_en,   uint8_t dmem_cycles_or_max,
                  bool gpio0_random_en,  uint8_t gpio0_cycles_or_max,
                  bool uart0_random_en,  uint8_t uart0_cycles_or_max,
                  bool timer0_random_en, uint8_t timer0_cycles_or_max);
```

其中 `random_en=false` 表示固定延迟，`cycles_or_max[6:0]` 是固定周期数；`random_en=true` 表示随机延迟，`cycles_or_max[6:0]` 是随机上限，TB 生成 `0..cycles_or_max` 的具体 delay。

内部可以提供一个打包 helper，统一生成 TB mailbox 使用的 8-bit 字段：

```c
static inline uint8_t tb_pack_resp_delay_cfg(bool random_en, uint8_t cycles_or_max)
{
    return (uint8_t)((random_en ? 0x80u : 0x00u) | (cycles_or_max & 0x7fu));
}
```

四个单 target helper 需要在软件侧保存当前 32-bit 配置影子值，只更新目标 byte，不改变其他 target 配置，然后把完整 32-bit 配置写到 `TB_RESP_DELAY_CFG0_ADDR`。同时配置四个 target 的 helper 直接打包并写完整配置。

这些 helper 只属于 `tb_rv32i_soc.sv` directed-test 协议，不属于真实 SoC ABI；汇编测试若需要使用，可以直接写 `TB_RESP_DELAY_CFG0_ADDR` 和 packed config，不强制提供汇编函数。

## 14. 回归与验收顺序 `执行中`

### 14.1 0 wait-state 等价回归 `已通过`

RTL 完成后第一步只跑默认 0 wait-state。

目标：

- 现有汇编/C directed tests 继续 PASS。
- commit/trap 关键 trace 不出现明显乱序。
- UART TX、GPIO IRQ、TIMER IRQ 不重复触发。

### 14.2 更多定向测试集验证 `执行中`

本节开始为 0834 wait-state 功能补充专用 directed tests。测试仍沿用当前“软件自检 + TB mailbox 激励”的方式，不在本阶段展开完整 UVM/scoreboard。

测试程序集建议按下列顺序增加：

| 程序 | 类型 | 主要覆盖点 |
| --- | --- | --- |
| `0801_dmem_wait_basic` | ASM | 通过 `TB_RESP_DELAY_CFG0_ADDR` 配置 DMEM 固定小延迟，覆盖 `LB/LH/LW/LBU/LHU/SB/SH/SW` 的基本读写、byte enable、符号/零扩展和连续 load/store。 |
| `0802_dmem_wait_forwarding` | ASM | 覆盖 delayed load 后立即被 ALU、branch、store data 使用；确认 load-use stall + MEM wait 能让 consumer 取到正确数据。额外覆盖 MEM/WB 在 wait 期间作为 forwarding source 被保留，且 WB/commit 不重复。 |
| `0853_mmio_wait_basic` | C | 分别配置 GPIO0/UART0/TIMER0 固定小延迟，复用当前平台 helper 做寄存器读写。重点检查 MMIO read/write 在 wait 下仍只产生一次副作用：GPIO W1C 不重复清、UART TX store 不重复发送、UART RXDATA 读清只发生一次、TIMER32 写 MTIME/MTIMECMP/CTRL 语义不变。 |
| `0804_mmio_wait_access_fault` | ASM | 对 GPIO0/UART0/TIMER0 窗口内未定义 offset 做 load/store，配置对应 target 延迟，验证 delayed response error 在 MEM completion 边界转成精确 load/store access fault；faulting store 不产生副作用，fault 后 wrong-path store 被 kill。 |
| `0805_wait_interrupt_boundary` | ASM | 在 older memory transaction 等 response 期间制造 timer/GPIO/UART interrupt pending，验证 interrupt 不越过 older MEM 指令提前进入 trap；response completion 后再按 0833 精确提交语义接受中断，检查 older store/load 结果、`mepc` 和 pending 清除行为。 |
| `0856_wait_mixed_random_smoke` | C | 使用 `tb_rv32i_soc_test.h` 的随机 delay helper，给 DMEM/GPIO0/UART0/TIMER0 配置较小随机上限，执行混合 DMEM、GPIO、UART、TIMER 操作。只检查语义正确和最终 PASS，不检查固定周期统计。 |

补充原则：

- 固定延迟优先使用小值，例如 1、2、3、7，先覆盖边界再扩大；随机模式上限保持较小，避免 timeout。
- 不要求所有旧测试都在非 0 wait-state 下通过固定周期断言。尤其是 timer/GPIO 周期统计类测试，wait-state 会改变 handler 吞吐和观测窗口，只应检查语义，不应沿用 0 wait-state 的严格周期阈值。
- 访问 fault 测试优先使用“命中外设窗口但 offset 未定义”的地址，因为这类 error 会经过对应 target wrapper 延迟返回；完全未映射地址当前仍保持同拍 error response，可作为 0 wait-state error 路径补充。
- 每个测试程序应在头注释中写明使用的 delay 配置、期望覆盖的 wait-state 场景，以及哪些现象不作为 PASS/FAIL 标准。

## 15. 完成标准

本阶段完成时应满足：

- core LSU data side 已从固定响应改为 simple request/response。
- data_subsystem 能完成 simple data bus 地址译码、request 分发和 response 汇总。
- DMEM/MMIO target simple slave/wrapper 能接受 request、插入 0/N 拍等待并返回 response。
- MEM wait 能正确冻结 PC/IF/ID/EX/MEM，年轻指令不能越过 older memory instruction。
- MEM wait 期间必要的 MEM/WB forwarding source 不丢失，同时 WB/commit 不重复发生。
- 0 wait-state 下现有 regression 不退化。
- delayed response error 能产生精确 load/store access fault。
- MMIO write/read 副作用不因 wait 或 valid 保持重复发生。
- interrupt pending 在 memory wait 期间不被提前接受，只在 completion 边界按 0833 语义处理。
- 注释不再保留“固定响应/无 backpressure”的过时描述。
- testbench 已具备后续 wait-state directed tests 所需的 data bus 观察和延迟注入入口。
