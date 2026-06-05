//------------------------------------------------------------------------------
// 文件      : rtl/core/pipe_reg.sv
// 用途      : RV32I 五级流水线寄存器模块。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 包含四组独立流水线寄存器：IF/ID、ID/EX、EX/MEM、MEM/WB。
//   - 数据内容使用 pipeline_pkg 中的 packed struct 打包传递。
//   - 每个模块负责在时钟上升沿锁存前一级的控制信号和数据通路值。
//------------------------------------------------------------------------------

`default_nettype none

// IF/ID 流水线寄存器
// 优先级：reset > flush > stall > normal advance。
module pipe_reg_if_id (
    input  logic                    clk_i,
    input  logic                    rst_n_i,

    input  pipeline_pkg::if_id_reg_t data_i,
    input  logic                    valid_i,
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
        end else if (flush_i) begin
            valid_o <= 1'b0;
            data_o  <= '0;
        end else if (stall_i) begin
            // stall 状态保持
        end else begin
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
//                第一版固定响应 memory 通常不用它处理 load-use；它更适合后续
//                memory wait、全流水线暂停这类“当前 EX 指令也不能前进”的场景。
//
// 优先级：reset > flush > stall > bubble > normal advance。
// 当前设计 EX 及之后流水不会 stall,但统一保留 stall_i 接口，供后续扩展使用。
module pipe_reg_id_ex (
    input  logic                    clk_i,
    input  logic                    rst_n_i,

    input  pipeline_pkg::id_ex_reg_t data_i,
    input  logic                    valid_i,
    input  logic                    flush_i,
    input  logic                    bubble_i,
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
        end else if (flush_i) begin
            valid_o <= 1'b0; 
            data_o  <= '0;
        end else if (stall_i) begin
            // 保持，供后续扩展使用；load-use 不应走这个分支。
        end else if (bubble_i) begin
            // 插入 invalid 空槽，避免 ID 阶段 consumer 过早进入 EX。
            valid_o <= 1'b0;  
            data_o  <= '0; 
        end else begin
            valid_o <= valid_i;
            data_o  <= data_i;
        end
    end

endmodule

// MEM/WB 和 EX/MEM 两段不需要 stall/bubble/flush：
// - GPR 只读于 ID，只写于 WB。
//   RAW 的经典场景是： ID 读 gpr 时，上一级 EX/MEM 或 MEM/WB 的目标寄存器尚未写回，ID 读到旧值。
//   这由 forwarding_unit 跨级前递 ALU 结果解决（EX/MEM→EX 或 MEM/WB→EX）， 因此不需要 stall EX/MEM 或 MEM/WB。
// - branch/JAL/JALR 在 EX 算出 redirect，走到 EX/MEM 的指令必定已是正确路径
// - store 在 MEM 阶段写 dmem，WB 只做写回选择，二者都不会产生新的控制流依赖

// EX/MEM 流水线寄存器
module pipe_reg_ex_mem (
    input  logic                      clk_i,
    input  logic                      rst_n_i,

    input  pipeline_pkg::ex_mem_reg_t  data_i,
    input  logic                      valid_i,
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
        end else if (stall_i) begin
            // 保持，供后续扩展使用
        end else begin
            valid_o <= valid_i;
            data_o  <= data_i;
        end
    end

endmodule


// MEM/WB 流水线寄存器
module pipe_reg_mem_wb (
    input  logic                      clk_i,
    input  logic                      rst_n_i,

    input  pipeline_pkg::mem_wb_reg_t  data_i,
    input  logic                      valid_i,
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
        end else if (stall_i) begin
            // 保持，供后续扩展使用
        end else begin
            valid_o <= valid_i;
            data_o  <= data_i;
        end
    end

endmodule

`default_nettype wire
