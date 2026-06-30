//------------------------------------------------------------------------------
// 文件      : rtl/core/pipe_reg.sv
// 用途      : RV32I 五级流水线寄存器模块。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 包含四组独立流水线寄存器：IF/ID、ID/EX、EX/MEM、MEM/WB。
//   - 数据内容使用 pipeline_pkg 中的 packed struct 打包传递。
//   - 每个模块负责在时钟上升沿锁存前一级的控制信号和数据通路值。
//
// 控制口径：
//   - flush 用于已允许的普通 non-trap redirect，清掉错误路径上的 IF/ID、ID/EX 指令。
//   - kill 用于 MEM 边界接受 trap/MRET，它比普通 flush/stall/bubble 优先级更高，
//     用来清掉 trap/MRET 之后的普通流水线路径。
//   - 对 IF/ID、ID/EX、EX/MEM 来说，kill 清掉的是 younger instruction。
//     对 MEM/WB 来说，kill 清掉的是下一拍进入 WB 的槽位，阻止当前 MEM 指令
//     作为普通指令继续进入 WB；它不取消已经在 WB 的 older instruction。
//------------------------------------------------------------------------------

`default_nettype none

// IF/ID 流水线寄存器
// 优先级：reset > kill > flush > stall > normal advance。
module pipe_reg_if_id (
    input  logic                    clk_i,
    input  logic                    rst_n_i,

    input  pipeline_pkg::if_id_reg_t data_i,
    input  logic                    valid_i,
    input  logic                     kill_i,
    input  logic                    flush_i,
    input  logic                    stall_i,

    output pipeline_pkg::if_id_reg_t data_o,
    output logic                    valid_o
);
    import core_pkg::*;
    import pipeline_pkg::*;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            valid_o <= 1'b0;
            data_o  <= '0;
        end
        else if (kill_i) begin
            valid_o <= 1'b0;
            data_o  <= '0;
        end
        else if (flush_i) begin
            valid_o <= 1'b0;
            data_o  <= '0;
        end
        else if (stall_i) begin
            // stall 状态保持
        end
        else begin
            valid_o <= valid_i;
            data_o  <= data_i;
        end
    end

endmodule


// ID/EX 流水线寄存器
//
// 控制语义：
//   - flush_i  : 清掉已经进入 ID/EX 的错误路径指令。
//   - bubble_i : 向 EX 插入一个 invalid 空槽。
//                典型用途是 load-use：PC 和 IF/ID 保持，让 consumer 留在 ID；
//                ID/EX 写入 bubble，让前面的 load 继续进入 EX/MEM、MEM/WB。
//   - stall_i  : 保持 ID/EX 当前内容。
//                load-use 不走这个分支；MEM wait backpressure 用它保持当前 ID/EX。
//
// 优先级：reset > kill > flush > stall > bubble > normal advance。
// MEM wait 时 stall_i 保持 ID/EX，避免 younger 指令越过 older MEM 指令。
module pipe_reg_id_ex (
    input  logic                    clk_i,
    input  logic                    rst_n_i,

    input  pipeline_pkg::id_ex_reg_t data_i,
    input  logic                    valid_i,
    input  logic                     kill_i,
    input  logic                    flush_i,
    input  logic                   bubble_i,
    input  logic                    stall_i,

    output pipeline_pkg::id_ex_reg_t data_o,
    output logic                    valid_o
);
    import core_pkg::*;
    import pipeline_pkg::*;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            valid_o <= 1'b0;
            data_o  <= '0;
        end
        else if (kill_i) begin
            valid_o <= 1'b0;
            data_o  <= '0;
        end
        else if (flush_i) begin
            valid_o <= 1'b0; 
            data_o  <= '0;
        end
        else if (stall_i) begin
            // MEM wait backpressure 时保持；load-use 不应走这个分支。
        end
        else if (bubble_i) begin
            // 插入 invalid 空槽，避免 ID 阶段 consumer 过早进入 EX。
            valid_o <= 1'b0;  
            data_o  <= '0; 
        end
        else begin
            valid_o <= valid_i;
            data_o  <= data_i;
        end
    end

endmodule

// EX/MEM 不需要普通 flush，但需要 trap/MRET kill：
// - branch/JAL/JALR 在 EX 算出 redirect，清 IF/ID 和 ID/EX 即可；同一拍进入
//   EX/MEM 的正是 redirect 指令本身，不应被普通 flush 清掉。
// - trap/MRET 在 MEM 边界被接受时，当前 EX 指令是 younger instruction，必须用
//   kill_i 阻止它进入 EX/MEM。
// - MEM wait 时 stall_i 保持 EX/MEM，使 outstanding transaction 对应的 MEM 指令不被覆盖。

// EX/MEM 流水线寄存器
module pipe_reg_ex_mem (
    input  logic                      clk_i,
    input  logic                      rst_n_i,

    input  pipeline_pkg::ex_mem_reg_t  data_i,
    input  logic                      valid_i,
    input  logic                       kill_i,
    input  logic                      stall_i,

    output pipeline_pkg::ex_mem_reg_t  data_o,
    output logic                      valid_o
);
    import core_pkg::*;
    import pipeline_pkg::*;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            valid_o <= 1'b0;
            data_o  <= '0;
        end
        else if (kill_i) begin
            valid_o <= 1'b0;
            data_o  <= '0;
        end
        else if (stall_i) begin
            // MEM wait backpressure 时保持。
        end
        else begin
            valid_o <= valid_i;
            data_o  <= data_i;
        end
    end

endmodule


// MEM/WB 流水线寄存器
// 优先级：reset > kill > stall > normal advance。
// 这里的 kill_i 表示当前 MEM 指令已经在 MEM 边界由 trap_ctrl 接受，
// 因此本寄存器写入 invalid bubble，不再让它作为普通 WB 指令提交。
// 当前 MEM wait 不需要 stall MEM/WB；WB 中已有 older 指令可自然提交。
module pipe_reg_mem_wb (
    input  logic                      clk_i,
    input  logic                      rst_n_i,

    input  pipeline_pkg::mem_wb_reg_t  data_i,
    input  logic                      valid_i,
    input  logic                       kill_i,
    input  logic                      stall_i,

    output pipeline_pkg::mem_wb_reg_t  data_o,
    output logic                      valid_o
);
    import core_pkg::*;
    import pipeline_pkg::*;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i) begin
            valid_o <= 1'b0;
            data_o  <= '0;
        end
        else if (kill_i) begin
            valid_o <= 1'b0;
            data_o  <= '0;
        end
        else if (stall_i) begin
            // 当前 MEM wait 不使用 MEM/WB stall；若后续接入该口，保持当前 MEM/WB 内容。
        end
        else begin
            valid_o <= valid_i;
            data_o  <= data_i;
        end
    end

endmodule

`default_nettype wire
