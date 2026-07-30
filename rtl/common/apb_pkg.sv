//------------------------------------------------------------------------------
// 文件      : rtl/common/apb_pkg.sv
// 用途      : RV32I 教学核 APB4 外设总线公共常量与类型定义。
//
// 规范：
//   - 本包固定定义 32-bit address、32-bit data 和 4-bit byte strobe。
//   - master-to-slave request 与 slave-to-master response 分别使用 packed struct 聚合。
//   - 类型只表达 APB4 transaction，不包含具体外设 sideband、target 或验证配置。
//   - PSTRB 用于保持 CPU byte enable 到外设寄存器写入之间的逐 byte lane 语义。
//------------------------------------------------------------------------------

package apb_pkg;
    parameter int unsigned APB_ADDR_WIDTH = 32;                 // byte address 位宽。
    parameter int unsigned APB_DATA_WIDTH = 32;                 // 单笔读写的数据位宽。
    parameter int unsigned APB_STRB_WIDTH = APB_DATA_WIDTH / 8; // 写操作 byte lane 数量。
    parameter int unsigned APB_PROT_WIDTH = 3;                  // PPROT 属性位宽。

    typedef logic [APB_ADDR_WIDTH-1:0] apb_addr_t;              // PADDR 类型。
    typedef logic [APB_DATA_WIDTH-1:0] apb_data_t;              // PWDATA/PRDATA 类型。
    typedef logic [APB_STRB_WIDTH-1:0] apb_strb_t;              // PSTRB 类型，每位使能一个 byte lane。
    typedef logic [APB_PROT_WIDTH-1:0] apb_prot_t;              // PPROT 类型。

    // APB master 发往 slave 的 request/control/payload。
    typedef struct packed {
        logic       psel;       // slave select，SETUP/ACCESS 阶段保持有效。
        logic       penable;    // ACCESS phase 标志，SETUP 阶段为 0。
        logic       pwrite;     // 1 表示 write，0 表示 read。
        apb_addr_t  paddr;      // 本笔 transfer 的 byte address。
        apb_data_t  pwdata;     // write data，read 时无意义。
        apb_strb_t  pstrb;      // write byte lane enable，read 时无意义。
        apb_prot_t  pprot;      // 保护属性，编码与 AXI AxPROT 保持一致。
    } apb_req_t;

    // APB slave 返回 master 的 completion/data/error。
    typedef struct packed {
        logic      pready;      // slave 在 ACCESS phase 完成本笔 transfer。
        apb_data_t prdata;      // read data，write 时无意义。
        logic      pslverr;     // transfer completion 对应的 slave error。
    } apb_resp_t;

    localparam apb_req_t  APB_REQ_IDLE  = '0;                   // APB master 空闲默认值。
    localparam apb_resp_t APB_RESP_IDLE = '0;                   // APB slave 空闲默认值。
endpackage
