//------------------------------------------------------------------------------
// 文件      : rtl/core/regfile.sv
// 用途      : RV32I 的 32 项通用寄存器堆。
//
// 规范：
//   - 输入端口使用 _i 后缀，输出端口使用 _o 后缀。
//   - 写端口在时钟上升沿同步写入。
//   - 两个读端口是组合读。
//   - rst_n_i 是低有效复位。
//
// 功能：
//   - 为整数数据通路提供两个读端口和一个写端口。
//   - x0 硬连为 0：对 x0 的写入会被丢弃，读取 x0 永远返回 0。
//   - 当 BYPASS_EN=1 时，读端口检测到同拍写读同一地址（we_i && rd_addr_i == rs_addr_i）
//     时直接输出写数据 rd_wdata_i，而非存储阵列中的旧值。
//   - 读端口与写端口属于同一时钟域，写使能与读地址在 posedge 前就已经稳定，不存在时序违例。
//------------------------------------------------------------------------------

`default_nettype none

module regfile #(
    parameter bit BYPASS_EN = 0     // 同拍写读旁路；五级流水线核打开以覆盖 WB->ID 边界窗口。
) (
    input  logic                         clk_i,
    input  logic                         rst_n_i,

    input  logic [4:0]                   rs1_addr_i,
    output logic [core_pkg::XLEN-1:0]    rs1_rdata_o,

    input  logic [4:0]                   rs2_addr_i,
    output logic [core_pkg::XLEN-1:0]    rs2_rdata_o,

    input  logic                         we_i,
    input  logic [4:0]                   rd_addr_i,
    input  logic [core_pkg::XLEN-1:0]    rd_wdata_i
);
    import core_pkg::*;

    logic [XLEN-1:0] gpr_q [32];

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            for (int i = 0; i < 32; i++) begin
                gpr_q[i] <= '0;
            end
        end else begin
            if (we_i && (rd_addr_i != 5'd0)) begin
                gpr_q[rd_addr_i] <= rd_wdata_i;
            end

            gpr_q[0] <= '0;
        end
    end

    generate
        // 流水线模式：带同拍写读旁路。
        if (BYPASS_EN) begin : bypass_on
            // 当 ID 读 GPR 与 WB 写 GPR 指向同一地址时，直接输出写数据。
            always_comb begin
                if (rs1_addr_i == 5'd0) begin
                    rs1_rdata_o = '0;
                end else if (we_i && rd_addr_i == rs1_addr_i) begin
                    rs1_rdata_o = rd_wdata_i;
                end else begin
                    rs1_rdata_o = gpr_q[rs1_addr_i];
                end
            end

            always_comb begin
                if (rs2_addr_i == 5'd0) begin
                    rs2_rdata_o = '0;
                end else if (we_i && rd_addr_i == rs2_addr_i) begin
                    rs2_rdata_o = rd_wdata_i;
                end else begin
                    rs2_rdata_o = gpr_q[rs2_addr_i];
                end
            end

        // 无同拍写读旁路：纯组合读存储阵列。
        end else begin : bypass_off
            always_comb begin
                if (rs1_addr_i == 5'd0) begin
                    rs1_rdata_o = '0;
                end else begin
                    rs1_rdata_o = gpr_q[rs1_addr_i];
                end
            end

            always_comb begin
                if (rs2_addr_i == 5'd0) begin
                    rs2_rdata_o = '0;
                end else begin
                    rs2_rdata_o = gpr_q[rs2_addr_i];
                end
            end
        end
    endgenerate

endmodule

`default_nettype wire

//------------------------------------------------------------------------------
// BYPASS_EN 参数说明：
//   - BYPASS_EN=0 时，读口只看 gpr_q 数组，不看本拍写端口。
//     这种模式适合不需要 WB->ID 边界旁路的用法，也避免在组合路径里把读口和写口闭环。
//
//   - 五级流水线顶层（core_pipeline5）建议打开为 1。
//     可以把这个旁路理解成：“我这一拍正要写 x1，你这一拍也正要读 x1，那你到底是
//     读旧的 gpr_q[x1]，还是直接读我写口上的新值？”BYPASS_EN=1 选择后者。
//
//     EX/MEM -> EX 和 MEM/WB -> EX forwarding 能覆盖大多数 RAW，但覆盖不了下面这个
//     “WB 同拍写、ID 同拍读”的边界窗口：producer 和 consumer 之间恰好隔两条独立
//     指令时，producer 到达 WB 的这一拍，consumer 正好还在 ID 读 regfile。
//
//     这个窗口不是 EX/MEM -> EX 或 MEM/WB -> EX forwarding 能解决的。
//     producer 的结果之前当然已经在 EX/MEM、MEM/WB 出现过，但那几拍 consumer
//     还没到 EX，没法使用 EX 阶段的 forwarding mux。
//     等 consumer 下一拍真正进入 EX 时，producer 已经离开 MEM/WB，forwarding_unit
//     也就找不到这个 producer 了。所以 consumer 唯一不 stall 的机会，就是在自己
//     还处于 ID、producer 正处于 WB 的这一拍，直接从 WB 写口读到新值。
//     也就是说，这是 WB->ID 的“末班车”：这拍读不到 rd_wdata_i，就只能 stall 一拍，
//     等 gpr_q 真正更新后再读。
//
//       i0: addi x1, x0, 1      // producer，写 x1
//       i1: addi x5, x0, 0
//       i2: addi x6, x0, 0
//       i3: addi x2, x1, 1      // consumer，读 x1
//
//     在 i0 写回的那个时钟周期内：
//       - i0 位于 MEM/WB，wb_stage 已经组合产生 we_i/rd_addr_i/rd_wdata_i；
//       - i3 位于 ID，id_stage 正在用 rs1_addr_i 组合读取 regfile；
//       - 周期末的同一个 posedge 上，i0 写入 gpr_q[x1]，i3 的读值也被 ID/EX 锁存。
//
//     如果 regfile 读口只看 gpr_q 数组，不看本拍写端口，那么在这个 posedge 前，
//     gpr_q[x1] 仍然是旧值。于是 i3 在 ID/EX 中锁存的是旧的 rs1_rdata。
//     下一拍 i3 进入 EX 时，i0 已经离开 MEM/WB，forwarding_unit 看到的 MEM/WB 是
//     后面的 i1 或 i2，不再是 i0，因此无法再把 i0 的写回值前递给 i3。
//
//     BYPASS_EN=1 时，读口检测到 “we_i && rd_addr_i == rs_addr_i” 后直接返回
//     rd_wdata_i。这样 i3 在 ID 阶段读到的就是 i0 本拍将要写回的值，ID/EX 锁存正确，
//     下一拍进入 EX 时即使不命中 forwarding，也不会使用旧数据。
//
//     时序窗口说明（假设不加旁路）:
//       Cycle N                         | Cycle N posedge              | Cycle N+1
//       i0 在 WB，写口已给出新值          | i0 写入 gpr_q[x1]             | i3 进入 EX
//       i3 在 ID，读口仍从 gpr_q 读旧值    | i3 把旧值锁存进 ID/EX          | MEM/WB 已不是 i0
//                                       |                              | forwarding 无法命中 i0
//
//     加上旁路后，Cycle N 的读口直接输出 rd_wdata_i，i3 锁存正确值。
//
//     另一个理论做法是：ID 阶段只译码和传 rs1/rs2 地址，等指令到了 EX 再读 regfile。
//     这样确实可以避开“ID 同拍读旧值”的问题。但代价是 EX 阶段要同时做
//     “读 regfile -> forwarding mux -> operand mux -> ALU/branch compare”，EX 组合路径
//     变长，而且 ex_stage 还要感知 GPR 读口，阶段边界不如现在清楚。教学五级流水通常
//     还是让 ID 读 GPR、EX 专心执行，再用这个很小的 WB->ID 同拍旁路补上边界窗口。
//------------------------------------------------------------------------------
