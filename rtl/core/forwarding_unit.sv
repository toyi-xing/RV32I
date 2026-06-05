//------------------------------------------------------------------------------
// 文件      : rtl/core/forwarding_unit.sv
// 用途      : RAW 数据前递检测 + 前递数据选择。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 检测 EX/MEM 和 MEM/WB 两级的 rd 是否与当前 EX 输入的 rs1/rs2 匹配。
//   - 内部根据 fwd_sel 选择前递数据，直接输出到 ALU 操作数。
//   - EX/MEM 优先级高于 MEM/WB（同一拍内 EX/MEM 数据更新）。
//   - rd = x0 不参与前递。
//   - EX/MEM 的 load 结果不能前递（MEM 阶段才从 DMEM 读出数据）。
//
// 功能：
//   - rs1 前递检测：比较 id_ex_rs1_addr 与 ex_mem_rd_addr、mem_wb_rd_addr。
//   - rs2 前递检测：比较 id_ex_rs2_addr 与 ex_mem_rd_addr、mem_wb_rd_addr。
//   - 当前递源无效（未命中或 rd=x0）时输出 regfile 原始数据，ALU 直接使用寄存器堆输出。
//------------------------------------------------------------------------------

`default_nettype none

module forwarding_unit (
    // 前递检测输入
    input  logic                      id_ex_valid_i,          // ID/EX 阶段指令是否有效。
    input  logic [4:0]                id_ex_rs1_addr_i,       // EX 指令的 rs1 地址。
    input  logic [4:0]                id_ex_rs2_addr_i,       // EX 指令的 rs2 地址。
    input  logic                      id_ex_uses_rs1_i,       // EX 指令是否真实使用 rs1。
    input  logic                      id_ex_uses_rs2_i,       // 同上，针对 rs2。

    input  logic                      ex_mem_valid_i,         // EX/MEM 阶段是否有有效指令。
    input  logic [4:0]                ex_mem_rd_addr_i,       // EX/MEM 指令的写回 rd。
    input  logic                      ex_mem_reg_we_i,        // EX/MEM 指令是否写 GPR。
    input  logic                      ex_mem_mem_re_i,        // EX/MEM 是否为 load（load 的 ALU 结果是访存地址，不能前递）。

    input  logic                      mem_wb_valid_i,         // MEM/WB 阶段是否有有效指令。
    input  logic [4:0]                mem_wb_rd_addr_i,       // MEM/WB 指令的写回 rd。
    input  logic                      mem_wb_reg_we_i,        // MEM/WB 指令是否写 GPR。

    // 前递数据输入
    input  logic [core_pkg::XLEN-1:0] id_ex_rs1_rdata_i,    // 原始 regfile rs1 数据（FWD_GPR 兜底）。
    input  logic [core_pkg::XLEN-1:0] id_ex_rs2_rdata_i,    // 原始 regfile rs2 数据（FWD_GPR 兜底）。
    input  core_pkg::wb_sel_e         ex_mem_wb_sel_i,      // lui，jump 指令写 rd 不是 alu 结果，是 imm 和 pc + 4，因此需要选择。
    input  logic [core_pkg::XLEN-1:0] ex_mem_alu_result_i,  // EX/MEM 的 ALU 结果（FWD_EX_MEM）。
    input  logic [core_pkg::XLEN-1:0] ex_mem_pc_plus4_i,
    input  logic [core_pkg::XLEN-1:0] ex_mem_imm_i,
    input  logic [core_pkg::XLEN-1:0] mem_wb_wdata_i,       // MEM/WB 最终写回数据（FWD_MEM_WB）。

    // 前递数据输出
    output logic [core_pkg::XLEN-1:0] rs1_fwd_o,            // rs1 前递结果，直送 EX 阶段。
    output logic [core_pkg::XLEN-1:0] rs2_fwd_o             // rs2 前递结果，直送 EX 阶段。
);

    import core_pkg::*;
    import pipeline_pkg::*;

    pipeline_pkg::fwd_sel_e fwd_rs1_sel;
    pipeline_pkg::fwd_sel_e fwd_rs2_sel;

    always_comb begin : rs1_fwd
        // detection
        fwd_rs1_sel = FWD_GPR;
        if (id_ex_valid_i && id_ex_uses_rs1_i && id_ex_rs1_addr_i != '0) begin // 写 x0 会被丢弃，算出来的"错"数不应该被 forwarding
            if (ex_mem_valid_i && id_ex_rs1_addr_i == ex_mem_rd_addr_i && ex_mem_reg_we_i && !ex_mem_mem_re_i) begin
                fwd_rs1_sel = FWD_EX_MEM;   // 更新的数优先级更高
            end else if (mem_wb_valid_i && id_ex_rs1_addr_i == mem_wb_rd_addr_i && mem_wb_reg_we_i) begin
                fwd_rs1_sel = FWD_MEM_WB;
            end
        end

        // mux
        unique case (fwd_rs1_sel)
            FWD_EX_MEM : begin
                unique case (ex_mem_wb_sel_i)
                    WB_ALU: rs1_fwd_o = ex_mem_alu_result_i;
                    // WB_MEM 属于 load-use 问题，走 stall，不走 forwarding
                    WB_PC4: rs1_fwd_o = ex_mem_pc_plus4_i;
                    WB_IMM: rs1_fwd_o = ex_mem_imm_i;
                    default:rs1_fwd_o = ex_mem_alu_result_i;
                endcase
            end
            FWD_MEM_WB : rs1_fwd_o = mem_wb_wdata_i;
            default    : rs1_fwd_o = id_ex_rs1_rdata_i;
        endcase
    end

    always_comb begin : rs2_fwd
        fwd_rs2_sel = FWD_GPR;
        if (id_ex_valid_i && id_ex_uses_rs2_i && id_ex_rs2_addr_i != '0) begin
            if (ex_mem_valid_i && id_ex_rs2_addr_i == ex_mem_rd_addr_i && ex_mem_reg_we_i && !ex_mem_mem_re_i) begin
                fwd_rs2_sel = FWD_EX_MEM;
            end else if (mem_wb_valid_i && id_ex_rs2_addr_i == mem_wb_rd_addr_i && mem_wb_reg_we_i) begin
                fwd_rs2_sel = FWD_MEM_WB;
            end
        end

        unique case (fwd_rs2_sel)
            FWD_EX_MEM : begin
                unique case (ex_mem_wb_sel_i)
                    WB_ALU: rs2_fwd_o = ex_mem_alu_result_i;
                    // WB_MEM 属于 load-use 问题，走 stall，不走 forwarding
                    WB_PC4: rs2_fwd_o = ex_mem_pc_plus4_i;
                    WB_IMM: rs2_fwd_o = ex_mem_imm_i;
                    default:rs2_fwd_o = ex_mem_alu_result_i;
                endcase
            end
            FWD_MEM_WB : rs2_fwd_o = mem_wb_wdata_i;
            default    : rs2_fwd_o = id_ex_rs2_rdata_i;
        endcase
    end


endmodule

`default_nettype wire
