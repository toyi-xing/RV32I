//------------------------------------------------------------------------------
// 文件      : rtl/common/data_bus_pkg.sv
// 用途      : RV32I 教学核 data-side simple request/response 总线类型定义。
//
// 规范：
//   - RTL 使用 SystemVerilog，优先采用 logic、always_comb、always_ff 风格。
//   - 本包定义 core LSU 与 data_subsystem 之间的 request/response 结构体。
//   - 第一版只支持 single outstanding、in-order completion，不需要 transaction ID。
//   - ready 保持为离散握手信号，request/response payload 使用结构体聚合。
//------------------------------------------------------------------------------

package data_bus_pkg;
    import core_pkg::*;

    // data_req_t 表示一次 load/store 请求。
    typedef struct packed {
        logic                      valid;
        logic                      write;
        logic [3:0]                be;
        logic [core_pkg::XLEN-1:0] addr;
        logic [core_pkg::XLEN-1:0] wdata;
    } data_req_t;

    // data_resp_t 表示一次 outstanding transaction 的完成结果。
    typedef struct packed {
        logic                      valid;
        logic [core_pkg::XLEN-1:0] rdata;
        logic                      error;
    } data_resp_t;
endpackage
