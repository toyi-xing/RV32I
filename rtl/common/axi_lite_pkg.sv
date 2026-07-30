//------------------------------------------------------------------------------
// 文件      : rtl/common/axi_lite_pkg.sv
// 用途      : RV32I 教学核数据侧 AXI4-Lite 公共常量与类型定义。
//
// 规范：
//   - 本包固定定义 32-bit address、32-bit data 的 AXI4-Lite 总线。
//   - master-to-slave request 与 slave-to-master response 分别使用 packed struct 聚合。
//   - AW/W/B/AR/R 保留独立 valid/ready 握手，不携带 target、delay 或验证状态。
//   - 本项目暂不做 multiple outstanding；AXI4-Lite 标准允许多笔顺序完成，当前主动限制为 single outstanding。
//   - 各 channel 以注释代码保留完整 AXI4 扩展字段，便于对照 AXI4-Lite 的简化边界。
//   - ACLK/ARESETn 保持为 module 级端口，不属于 request/response transaction struct。
//------------------------------------------------------------------------------

package axi_lite_pkg;
    parameter int unsigned AXI_LITE_ADDR_WIDTH = 32;                        // byte address 位宽。
    parameter int unsigned AXI_LITE_DATA_WIDTH = 32;                        // 单笔读写的数据位宽。
    parameter int unsigned AXI_LITE_STRB_WIDTH = AXI_LITE_DATA_WIDTH / 8;   // 写操作 byte lane 数量。
    parameter int unsigned AXI_LITE_PROT_WIDTH = 3;                         // AxPROT 属性位宽。

    typedef logic [AXI_LITE_ADDR_WIDTH-1:0] axi_lite_addr_t;                // AWADDR/ARADDR 类型。
    typedef logic [AXI_LITE_DATA_WIDTH-1:0] axi_lite_data_t;                // WDATA/RDATA 类型。
    typedef logic [AXI_LITE_STRB_WIDTH-1:0] axi_lite_strb_t;                // WSTRB 类型，每位使能一个 byte lane。
    typedef logic [AXI_LITE_PROT_WIDTH-1:0] axi_lite_prot_t;                // AWPROT/ARPROT 类型，三个 bit 各自表达一种访问属性。

    // 以下参数仅供完整 AXI4 扩展字段参考，当前 AXI4-Lite 类型不使用。
    // 如果后续升级为完整 AXI4，除取消类型注释外，还必须同步实现 burst、ID 和 outstanding 行为。
    // parameter int unsigned AXI_ID_WIDTH   = 4;                            // 暂不做：纯 AXI4-Lite 不支持 ID；完整 AXI4 的具体位宽由系统实现决定。
    // parameter int unsigned AXI_USER_WIDTH = 1;                            // 暂不做：属于完整 AXI4 可选 sideband；示例统一位宽，实际可以按 channel 分别配置。

    // AxPROT[2]：0=数据、1=指令；[1]：0=安全、1=非安全；[0]：0=非特权、1=特权。
    localparam axi_lite_prot_t AXI_PROT_UNPRIVILEGED_DATA = 3'b000;        // 安全、非特权的数据访问。
        // 当前唯一使用值，当前是 CPU data-side bus（数据访问），只有 M-mode（特权访问），没有 TrustZone 或安全域（安全访问）
    localparam axi_lite_prot_t AXI_PROT_PRIVILEGED_DATA   = 3'b001;        // 安全、特权的数据访问。

    // AXI4-Lite 不支持 exclusive access，因此不使用 EXOKAY 响应。
    typedef enum logic [1:0] {
        AXI_RESP_OKAY   = 2'b00,    // 普通访问成功。
        // AXI_RESP_EXOKAY = 2'b01,    // 暂不做：AXI4-Lite 不支持 exclusive access 和 EXOKAY。
        AXI_RESP_SLVERR = 2'b10,    // 已选中 slave，但 slave 无法完成访问。
                                    // 当前：命中已实现的 target,但 offset 未定义；APB PSLVERR 和外部 DMEM slave error。
        AXI_RESP_DECERR = 2'b11     // 地址译码未命中可访问的 slave。
                                    // 当前：未命中已实现的 target。
    } axi_lite_resp_e;

    // AW channel payload。
    typedef struct packed {
        // logic [AXI_ID_WIDTH-1:0]    id;      // 暂不做：纯 AXI4-Lite 不支持 AWID；可选 ID reflection 只用于 full AXI 互操作。
        axi_lite_addr_t                addr;    // 写访问的 byte address。
        // logic [7:0]                 len;     // 暂不做：AXI4-Lite 不支持 AWLEN；burst length 固定为 1，等价于 AWLEN=0。
        // logic [2:0]                 size;    // 暂不做：AXI4-Lite 不支持 AWSIZE；访问宽度固定为 data bus 宽度，本项目等价于 AWSIZE=2。
        // logic [1:0]                 burst;   // 暂不做：AXI4-Lite 不支持 AWBURST；单 beat 下 FIXED/INCR/WRAP 没有区别。
        // logic                       lock;    // 暂不做：AXI4-Lite 不支持 AWLOCK；访问固定为 normal，等价于 AWLOCK=0。
        // logic [3:0]                 cache;   // 暂不做：AXI4-Lite 不支持 AWCACHE；固定为 non-modifiable、non-bufferable，等价于 4'b0000。
        axi_lite_prot_t                prot;    // 写访问的保护属性，当前没有实际功能影响。
        // logic [3:0]                 qos;     // 暂不做：AXI4-Lite 不支持 AWQOS；完整 AXI4 用于服务质量标记。
        // logic [3:0]                 region;  // 暂不做：AXI4-Lite 不支持 AWREGION；完整 AXI4 用于地址区域标记。
        // logic [AXI_USER_WIDTH-1:0]  user;    // 暂不做：AWUSER 属于完整 AXI4 可选 sideband，本项目不需要自定义信息。
    } axi_lite_aw_t;

    // W channel payload。
    typedef struct packed {
        axi_lite_data_t                data;    // 写数据。
        axi_lite_strb_t                strb;    // 写操作 byte lane 使能，每 byte 有效掩码。
        // logic                       last;    // 暂不做：AXI4-Lite 不支持 WLAST；每笔只有一个 beat，固定等价于 WLAST=1。
        // logic [AXI_USER_WIDTH-1:0]  user;    // 暂不做：WUSER 属于完整 AXI4 可选 sideband，本项目不需要自定义信息。
    } axi_lite_w_t;

    // B channel payload。
    typedef struct packed {
        // logic [AXI_ID_WIDTH-1:0]    id;      // 暂不做：纯 AXI4-Lite 不支持 BID；完整 AXI4 用它关联 write response。
        axi_lite_resp_e                resp;    // 写访问完成状态。
        // logic [AXI_USER_WIDTH-1:0]  user;    // 暂不做：BUSER 属于完整 AXI4 可选 sideband，本项目不需要自定义信息。
    } axi_lite_b_t;

    // AR channel payload。
    typedef struct packed {
        // logic [AXI_ID_WIDTH-1:0]    id;      // 暂不做：纯 AXI4-Lite 不支持 ARID；可选 ID reflection 只用于 full AXI 互操作。
        axi_lite_addr_t                addr;    // 读访问的 byte address。
        // logic [7:0]                 len;     // 暂不做：AXI4-Lite 不支持 ARLEN；burst length 固定为 1，等价于 ARLEN=0。
        // logic [2:0]                 size;    // 暂不做：AXI4-Lite 不支持 ARSIZE；访问宽度固定为 data bus 宽度，本项目等价于 ARSIZE=2。
        // logic [1:0]                 burst;   // 暂不做：AXI4-Lite 不支持 ARBURST；单 beat 下 FIXED/INCR/WRAP 没有区别。
        // logic                       lock;    // 暂不做：AXI4-Lite 不支持 ARLOCK；访问固定为 normal，等价于 ARLOCK=0。
        // logic [3:0]                 cache;   // 暂不做：AXI4-Lite 不支持 ARCACHE；固定为 non-modifiable、non-bufferable，等价于 4'b0000。
        axi_lite_prot_t                prot;    // 读访问的保护属性，当前没有实际功能影响。
        // logic [3:0]                 qos;     // 暂不做：AXI4-Lite 不支持 ARQOS；完整 AXI4 用于服务质量标记。
        // logic [3:0]                 region;  // 暂不做：AXI4-Lite 不支持 ARREGION；完整 AXI4 用于地址区域标记。
        // logic [AXI_USER_WIDTH-1:0]  user;    // 暂不做：ARUSER 属于完整 AXI4 可选 sideband，本项目不需要自定义信息。
    } axi_lite_ar_t;

    // R channel payload。
    typedef struct packed {
        // logic [AXI_ID_WIDTH-1:0]    id;      // 暂不做：纯 AXI4-Lite 不支持 RID；完整 AXI4 用它关联 read response。
        axi_lite_data_t                data;    // 读数据。
        axi_lite_resp_e                resp;    // 读访问完成状态。
        // logic                       last;    // 暂不做：AXI4-Lite 不支持 RLAST；每笔只有一个 beat，固定等价于 RLAST=1。
        // logic [AXI_USER_WIDTH-1:0]  user;    // 暂不做：RUSER 属于完整 AXI4 可选 sideband，本项目不需要自定义信息。
    } axi_lite_r_t;

    // AXI-Lite master 发往 slave 的全部通道信号。
    typedef struct packed {
        logic         aw_valid;     // AW payload 有效。
        axi_lite_aw_t aw;           // AW channel payload。
        logic         w_valid;      // W payload 有效。
        axi_lite_w_t  w;            // W channel payload。
        logic         b_ready;      // master 可以接受写响应。
        logic         ar_valid;     // AR payload 有效。
        axi_lite_ar_t ar;           // AR channel payload。
        logic         r_ready;      // master 可以接受读响应。
    } axi_lite_req_t;

    // AXI-Lite slave 返回 master 的全部通道信号。
    typedef struct packed {
        logic         aw_ready;     // slave 可以接受 AW payload。
        logic         w_ready;      // slave 可以接受 W payload。
        logic         b_valid;      // B payload 有效。
        axi_lite_b_t  b;            // B channel payload。
        logic         ar_ready;     // slave 可以接受 AR payload。
        logic         r_valid;      // R payload 有效。
        axi_lite_r_t  r;            // R channel payload。
    } axi_lite_resp_t;

    localparam axi_lite_req_t  AXI_LITE_REQ_IDLE  = '0;                    // master channel 空闲默认值。
    localparam axi_lite_resp_t AXI_LITE_RESP_IDLE = '0;                    // slave channel 空闲默认值。
endpackage
