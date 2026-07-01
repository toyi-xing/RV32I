//------------------------------------------------------------------------------
// 文件      : rtl/core/mem_stage.sv
// 用途      : RV32I 访存阶段与 data-side transaction controller。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 本模块使用单 outstanding request/response 模型管理 data-side 事务。
//   - 访存宽度统一使用 core_pkg::mem_size_e。
//   - LSU request payload 在 valid 拉高且 ready 未接受期间保持稳定。
//
// 功能：
//   - 对合法 load/store 发起 data-side request，并在 response 返回前保持 MEM wait。
//   - 对 store 生成 request write、byte enable 和按 byte lane 对齐后的写数据。
//   - 对 load 从 response rdata 中选出 byte/halfword/word，并按 mem_unsigned_i 做符号或零扩展。
//   - load/store 地址来自 EX 阶段 ALU 结果，本模块不重新计算地址。
//   - 检出 load/store address misaligned，不对齐或前级已有 exception 时不发起 data request。
//   - data response error 在 MEM completion 边界转换为 load/store access fault。
//   - store 的 byte lane 移位逻辑在某种非对齐场景下仍能产生正确结果，
//     但会被 request valid 门控屏蔽掉，不对齐的 store 不会实际写入。
//
// CSR、trap 相关功能：
//   - MEM 阶段负责识别的异常：load address misaligned、store address misaligned
//   - 检出不对齐时产生对应 exception cause（load=4, store=6）和 tval（faulting address）
//   - 接收前级已经发现的 exception，并按“先发现先保持”的规则优先输出前级 exception
//   - 如果前级已有 exception，本模块会屏蔽 data-side request，避免产生访存副作用
//------------------------------------------------------------------------------

`default_nettype none

module mem_stage (
    input  logic                          clk_i,
    input  logic                          rst_n_i,

    // 流水线输入
    input  logic                          valid_i,         // 当前 MEM 槽是否有效；用于门控访存副作用和错误上报。
    input  logic [core_pkg::XLEN-1:0]     alu_result_i,    // EX 阶段 ALU 结果，load/store 时作为 LSU 地址。
    input  logic [core_pkg::XLEN-1:0]     store_data_i,    // store 指令要写入 LSU 数据侧的原始 rs2 数据。
    input  logic                          mem_re_i,        // 当前指令是否执行 load。
    input  logic                          mem_we_i,        // 当前指令是否执行 store。
    input  core_pkg::mem_size_e           mem_size_i,      // 访存宽度：byte、halfword 或 word。
    input  logic                          mem_unsigned_i,  // load 是否零扩展；为 0 时表示符号扩展。
    // input  logic [core_pkg::XLEN-1:0]     lsu_rdata_i,     // LSU load 返回的 32 bit 原始 word 数据。

    // 流水线输出
    output logic                          valid_o,         // 送入 MEM/WB 的 valid（不必送入 data_subsystem，re 和 we 已包含该信息）
    output logic [core_pkg::XLEN-1:0]     load_data_o,     // 送往 WB 的 32 bit load 扩展结果。

    // output logic                          lsu_re_o,        // LSU load 读请求；地址不对齐或前级已有 exception 时不发起访问。
    //                                                        // simple_ram 无需读使能，但此处可以作为 WB 阶段写回判定。
    // output logic                          lsu_we_o,        // LSU store 写请求；地址不对齐或前级已有 exception 时不发起访问。
    // output logic [3:0]                    lsu_be_o,        // LSU store byte enable，如：SH x1, 0(x2) → 写 2 个字节 → be = 0011 / 1100
    // output logic [core_pkg::XLEN-1:0]     lsu_addr_o,      // LSU load/store 地址。
    // output logic [core_pkg::XLEN-1:0]     lsu_wdata_o,     // LSU 按 byte lane 对齐后的 store 数据。

    // trap 相关输入
    input  logic                          exception_valid_i,   // 前级已经发现的 exception 是否有效。
    input  core_pkg::excp_cause_e         exception_cause_i,   // 前级 exception cause。
    input  logic [core_pkg::XLEN-1:0]     exception_tval_i,    // 前级 exception tval。
    // input  logic                          lsu_access_fault_i,  // 当前有效 load/store 地址没有命中已实现 data region。

    // trap 相关输出
    output logic                          exception_valid_o,    // MEM 边界最终 exception 是否有效，包含前级透传和本级 misaligned。
    output core_pkg::excp_cause_e         exception_cause_o,    // MEM 边界最终 exception cause。
    output logic [core_pkg::XLEN-1:0]     exception_tval_o,     // MEM 边界最终 exception tval。

    // 可变延迟总线
    // 访存输出信号
    input  logic                          lsu_req_ready_i,          // data-side 可以接受本拍 request；valid && !ready 时 MEM 需要保持等待。
    output logic                          lsu_req_valid_o,          // 当前 MEM 指令需要发起真实 load/store request，指令无效或已有 exception 时不拉高。
    output logic                          lsu_req_write_o,          // LSU store 写请求；有效访存但 write_o 为 0 时表示为 load 指令
    output logic [3:0]                    lsu_req_be_o,             // LSU store byte enable，如：SH x1, 0(x2) → 写 2 个字节 → be = 0011 / 1100
    output logic [core_pkg::XLEN-1:0]     lsu_req_addr_o,           // LSU load/store 地址。
    output logic [core_pkg::XLEN-1:0]     lsu_req_wdata_o,          // LSU 按 byte lane 对齐后的 store 数据。

    // 访存反馈信号
    input  logic                          lsu_resp_valid_i,         // data-side response 有效；store/error response 不使用 rdata。
    input  logic [core_pkg::XLEN-1:0]     lsu_resp_rdata_i,         // LSU load 返回的 32 bit 原始 word 数据，仅 response OK 且当前为 load 时有意义。
    input  logic                          lsu_resp_error_i,         // data response error，当前主要由未映射地址或未知 MMIO offset 产生。

    // 控制信号
    output logic                          mem_wait_o,               // 当前 MEM 指令因为 data transaction 未完成而必须 hold。

    // 可作为观察信号输出
    output logic                          mem_misaligned_o,     // 为 1 时表示当前 load/store 地址不满足访问宽度对齐要求
    output logic                          load_misaligned_o,    // 当前有效 load 访问地址不满足访问宽度对齐要求。
    output logic                          store_misaligned_o,   // 当前有效 store 访问地址不满足访问宽度对齐要求。
    output logic                          mem_access_fault_o,   // response error 转换出的 load/store access fault。
    output logic                          load_access_fault_o,  // 当前有效 load 的 response error。
    output logic                          store_access_fault_o, // 当前有效 store 的 response error。
    output logic                          transaction_complete_o,   // 当前 data transaction 本拍完成
    output logic                          mem_complete_o            // 当前指令的 MEM 边界本拍可完成
);
    import core_pkg::*;

    assign valid_o = valid_i & mem_complete_o;
    // 按地址偏移右移并低位对齐后取出的原始 load 数据，尚未做符号/零扩展。
    // 仅当正确的 load 指令返回结果有意义
    wire [XLEN-1:0] load_raw = (lsu_resp_rdata_i >> {alu_result_i[1:0], 3'b000}) &
                               (mem_size_i == MEM_WORD ? 32'hffffffff :
                               (mem_size_i == MEM_HALF ? 32'h0000ffff : 32'h000000ff));
    assign load_data_o       =  mem_size_i == MEM_WORD ? load_raw :
                               (mem_size_i == MEM_HALF ? {{16{~mem_unsigned_i & load_raw[15]}}, load_raw[15:0]} :
                               (mem_size_i == MEM_BYTE ? {{24{~mem_unsigned_i & load_raw[ 7]}}, load_raw[ 7:0]} : '0));

    // 未对齐异常（EXCEPTION_CAUSE_LOAD_ADDR_MISALIGNED, EXCEPTION_CAUSE_STORE_ADDR_MISALIGNED）
    wire misa_lw            = valid_i && (mem_re_i || mem_we_i) && (mem_size_i == MEM_WORD) && (|alu_result_i[1:0]);
    wire misa_lh            = valid_i && (mem_re_i || mem_we_i) && (mem_size_i == MEM_HALF) && (alu_result_i[0]);
    assign mem_misaligned_o = valid_i && misa_lw || misa_lh;

    assign load_misaligned_o    = valid_i & mem_misaligned_o & mem_re_i;
    assign store_misaligned_o   = valid_i & mem_misaligned_o & mem_we_i;

    // 访问错误异常（EXCEPTION_CAUSE_LOAD_ACCESS_FAULT, EXCEPTION_CAUSE_STORE_ACCESS_FAULT）。
    // lsu_resp_valid_i 由 data-side 协议保证只对应已接受的当前事务，支持的错误类型查看 data_subsystem.sv。
    assign load_access_fault_o  = valid_i & (lsu_resp_valid_i & lsu_resp_error_i) & mem_re_i;
    assign store_access_fault_o = valid_i & (lsu_resp_valid_i & lsu_resp_error_i) & mem_we_i;
    assign mem_access_fault_o   = load_access_fault_o | store_access_fault_o;

    assign exception_valid_o    = exception_valid_i | mem_misaligned_o | mem_access_fault_o;
    assign exception_cause_o    = exception_valid_i    ? exception_cause_i                  :
                                  load_misaligned_o    ? EXCEPTION_CAUSE_LOAD_ADDR_MISALIGNED    :
                                  store_misaligned_o   ? EXCEPTION_CAUSE_STORE_ADDR_MISALIGNED   :
                                  load_access_fault_o  ? EXCEPTION_CAUSE_LOAD_ACCESS_FAULT       :
                                  store_access_fault_o ? EXCEPTION_CAUSE_STORE_ACCESS_FAULT      :
                                  EXCEPTION_CAUSE_ILLEGAL_INSTR;             // 默认值设为非法指令，此处无实意
    assign exception_tval_o     = exception_valid_i    ? exception_tval_i :
                                  mem_misaligned_o     ? alu_result_i     :
                                  mem_access_fault_o   ? alu_result_i     : '0;

    wire  mem_access = valid_i & ~exception_valid_i & ~mem_misaligned_o & (mem_re_i | mem_we_i); // 本拍指令需要且可以访存
    // 保证访存副作用最多一次（即一个访存指令只被接受一次），引入状态机
    logic req_outstanding_q;    // 为 1 表示当前访存请求已被接受，等待响应中。此时不应再发出访存请求。
    // 支持 0 wait-state，类似于同步单级 FIFO（支持空直通）语义。
    wire   request_accepted = lsu_req_valid_o & lsu_req_ready_i;  // 本拍被接受
    assign transaction_complete_o = lsu_resp_valid_i & (req_outstanding_q | request_accepted);   // 已被接受并响应（多拍或同拍均可）
    always_ff @(posedge clk_i or negedge rst_n_i) begin : REQ_OUTSTANDING_CTRL
        if (!rst_n_i) begin
            req_outstanding_q <= 1'b0;
        end
        else begin
            if (request_accepted) begin
                req_outstanding_q <= 1'b1;
            end
            if (transaction_complete_o) begin    // 访存结束，本指令流向 WB
                req_outstanding_q <= 1'b0;       // 下条访存未接受或不访存
            end
        end
    end

    // 访存输出信号
    assign lsu_req_valid_o  = mem_access & !req_outstanding_q;  // 需要访存且未被接受
    assign lsu_req_write_o  = lsu_req_valid_o & mem_we_i;       // 仅 lsu_req_valid_o = 1 时有意义
    assign lsu_req_be_o     =(mem_size_i == MEM_WORD ? 4'b1111 : 4'b0000) |
                             (mem_size_i == MEM_HALF ? 4'b0011 << alu_result_i[1:0] : 4'b0000) |
                             (mem_size_i == MEM_BYTE ? 4'b0001 << alu_result_i[1:0] : 4'b0000);
    assign lsu_req_addr_o   = alu_result_i;
    assign lsu_req_wdata_o  = store_data_i << {alu_result_i[1:0], 3'b000};

    assign mem_wait_o       =  mem_access & !transaction_complete_o;
    assign mem_complete_o   = !mem_access |  transaction_complete_o;    // = !mem_wait_o

endmodule

`default_nettype wire
