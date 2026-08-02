//------------------------------------------------------------------------------
// 文件      : rtl/bus/apb/apb_to_reg_adapter.sv
// 用途      : 将固定响应 APB4 access 转换为现有 MMIO register block 的单拍访问接口。
//             GPIO0、UART0、TIMER0 各通过一个本模块连接到 APB mux。
//
// 规范：
//   - 上游使用 apb_pkg 聚合的 APB4 request/response。
//   - 当前 register block 固定响应，因此 PREADY 保持为 1，不引入额外 wait-state。
//   - 只有 PSEL && PENABLE 的 ACCESS completion 周期才产生一次 register valid。
//   - APB SETUP phase 和未选中状态不会触发寄存器写入、读副作用或其它 side effect。
//
// 功能：
//   - APB PWRITE/PSTRB/PADDR/PWDATA 映射为 register valid/re/we/be/addr/wdata。
//   - register read data 映射为 PRDATA，register access fault 映射为 PSLVERR。
//   - 同一模块可复用于 GPIO0、UART0、TIMER0，不包含具体寄存器地址译码。
//------------------------------------------------------------------------------

`default_nettype none

module apb_to_reg_adapter (
    input  apb_pkg::apb_req_t                  apb_req_i,            // 上游 APB4 peripheral request。
    output apb_pkg::apb_resp_t                 apb_resp_o,           // 固定响应 APB4 completion。

    output logic                               reg_valid_o,          // 本拍完成一次 register access。
    output logic                               reg_re_o,             // 本拍完成一次 register read。
    output logic                               reg_we_o,             // 本拍完成一次 register write。
    output logic [apb_pkg::APB_STRB_WIDTH-1:0] reg_be_o,             // register write byte enable。
    output logic [apb_pkg::APB_ADDR_WIDTH-1:0] reg_addr_o,           // 完整 byte address。
    output logic [apb_pkg::APB_DATA_WIDTH-1:0] reg_wdata_o,          // register write data。
    input  logic [apb_pkg::APB_DATA_WIDTH-1:0] reg_rdata_i,          // register read data。
    input  logic                               reg_access_fault_i    // register offset/access type error。
);
    wire apb_access_complete;   // 固定 PREADY 下的 APB ACCESS completion。

    assign apb_access_complete = apb_req_i.psel && apb_req_i.penable;

    // register request 只在 APB completion 周期有效，SETUP 和 idle 不产生 side effect。
    assign reg_valid_o = apb_access_complete;
    assign reg_re_o    = apb_access_complete && !apb_req_i.pwrite;
    assign reg_we_o    = apb_access_complete && apb_req_i.pwrite;
    assign reg_be_o    = apb_req_i.pstrb;
    assign reg_addr_o  = apb_req_i.paddr;
    assign reg_wdata_o = apb_req_i.pwdata;

    // 当前寄存器块固定响应；PRDATA/PSLVERR 仅在 ACCESS completion 时具有事务意义。
    assign apb_resp_o.pready  = 1'b1;
    assign apb_resp_o.prdata  = reg_re_o ? reg_rdata_i : '0;
    assign apb_resp_o.pslverr = reg_valid_o && reg_access_fault_i;

endmodule

`default_nettype wire
