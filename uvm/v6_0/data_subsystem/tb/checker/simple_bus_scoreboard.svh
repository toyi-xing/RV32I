//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/checker/simple_bus_scoreboard.svh
// 用途      : v6.0 simple data bus UVM 环境的基础 DMEM scoreboard。
//
// 规范：
//   - 只接收 monitor 观察到的完整 transfer，不驱动 DUT 或参与 sequence 仲裁。
//   - 当前只检查 DMEM 的 write/read；MMIO 由后续专用 checker 覆盖，
//     response-delay 由 wrapper_scoreboard 检查。
//
// 功能：
//   - 维护 DMEM 的参考状态，并比较已写地址的后续读响应。
//   - 检查 DMEM 访问不应返回 error。
//------------------------------------------------------------------------------

class simple_bus_scoreboard extends uvm_scoreboard;

    `uvm_component_utils(simple_bus_scoreboard)

    uvm_analysis_imp #(simple_bus_transfer, simple_bus_scoreboard) tr_imp;

    bit [core_pkg::XLEN-1:0] ref_dmem  [logic [core_pkg::DMEM_ADDR_WIDTH-1:0]];
    bit                      ref_valid [logic [core_pkg::DMEM_ADDR_WIDTH-1:0]];
    // 统计信息，用于 check/report 阶段判断测试是否真正完成。
    int unsigned compare_count;
    int unsigned correct_count;
    int unsigned error_count;
    int unsigned skip_count;

    function new(string name = "simple_bus_scoreboard", uvm_component parent = null);
        super.new(name, parent);        
        compare_count = 0;
        correct_count = 0;
        error_count   = 0;
        skip_count    = 0;
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        tr_imp = new("bus_tr_imp", this);
    endfunction

    // analysis imp 收到 T 后回调
    function void write(simple_bus_transfer tr);
        compare_count ++;
        if (is_dmem_addr(tr.observed_item.addr)) begin
            dmem_ref_model(tr.observed_item);
            check_dmem(tr);
        end
        else begin
            skip_count ++;
            `uvm_info(get_type_name(), {"skip non-DMEM item: ", tr.transfer2string("transfer")}, UVM_MEDIUM)
        end
    endfunction

    function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        if (compare_count != correct_count + error_count + skip_count) begin
            `uvm_fatal(get_type_name(),
                $sformatf("Compare count mismatch: correct(%0d) + error(%0d) + skip(%0d) = %0d != total compare(%0d)",
                          correct_count, error_count, skip_count, correct_count + error_count + skip_count, compare_count))
        end
    endfunction

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("simple bus check finish, result: check_num=%0d including correct_num=%0d, error_num=%0d and skip_num=%0d",
                compare_count,correct_count, error_count, skip_count), UVM_MEDIUM)
    endfunction

    //-----------------------------------------------------------------------
    // helper
    //-----------------------------------------------------------------------

    // 当前 gold model 只做了 dmem 因此 scoreboard 只检查落于该处的 transfer
    function bit is_dmem_addr(logic [31:0] addr);
        return (addr >= core_pkg::DMEM_BASE) &&
               (addr <  core_pkg::DMEM_BASE + core_pkg::DMEM_SIZE_BYTES);
    endfunction

    // 命中 dmem 时，将 core 返回的 byte 地址转化为 word 地址
    function logic[core_pkg::DMEM_ADDR_WIDTH-1:0] addr_2_dmem_word_addr(logic [31:0] addr);
        return {addr[core_pkg::DMEM_ADDR_WIDTH-3:2], 2'b00};
    endfunction

    // dmem 的 gold model
    function void dmem_ref_model(simple_bus_item item);
        bit [core_pkg::DMEM_ADDR_WIDTH-1:0] word_addr = addr_2_dmem_word_addr(item.addr);
        // dmem 的参考行为
        if (item.write) begin
            if (!ref_valid.exists(word_addr)) begin     // 当前不考虑测试中复位导致的 write 过无效情况，只要首次 write 过就认为有效
                ref_valid[word_addr] = 1'b1;
                ref_dmem[word_addr]  = '0;
            end
            ref_dmem[word_addr] [7:0]   = item.be[0] ? item.wdata[7:0]   : ref_dmem[word_addr] [7:0];
            ref_dmem[word_addr] [15:8]  = item.be[1] ? item.wdata[15:8]  : ref_dmem[word_addr] [15:8];
            ref_dmem[word_addr] [23:16] = item.be[2] ? item.wdata[23:16] : ref_dmem[word_addr] [23:16];
            ref_dmem[word_addr] [31:24] = item.be[3] ? item.wdata[31:24] : ref_dmem[word_addr] [31:24];
        end
    endfunction

    // 利用 dmem_ref_model 的状态进行对比
    function void check_dmem(simple_bus_transfer tr);
        bit [core_pkg::DMEM_ADDR_WIDTH-1:0] word_addr = addr_2_dmem_word_addr(tr.observed_item.addr);
        // // 第一版 uvm seq 只生成 write32、read32 的 item
        // if (tr.observed_item.be != 4'hf) begin
        //     `uvm_fatal(get_type_name(), {"first scoreboard only supports word access: ", tr.transfer2string()})
        // end
        if (tr.error) begin         // 访问 dmem 时，dut 不应 resp error
            error_count ++;
            `uvm_error(get_type_name(), {"DMEM access returned error:",tr.transfer2string()})
        end
        else if (!tr.observed_item.write) begin   // read dmem 是需要 check 返回值与 gold model 是否一样
            if (!ref_valid.exists(word_addr)) begin
                skip_count ++;
                `uvm_info(get_type_name(),     // uvm 未写 dmem 就进行读取，spec 未规定这种情况，因此不做对比，但允许（如 dmem 初始化）
                    $sformatf("read a DMEM word but never write it, dmem word addr=0x%08x", word_addr), UVM_MEDIUM)
            end
            else begin
                if (tr.rdata !== ref_dmem[word_addr]) begin
                    error_count ++;
                    `uvm_error(get_type_name(),
                        $sformatf("DMEM read mismatch, dmem word addr=0x%08x expected=0x%08x actual=0x%08x",
                                  word_addr, ref_dmem[word_addr], tr.rdata))
                end
                else begin
                    correct_count ++;
                    `uvm_info(get_type_name(),
                        $sformatf("DMEM read match, dmem word addr=0x%08x expected=0x%08x actual=0x%08x",
                                  word_addr, ref_dmem[word_addr], tr.rdata), UVM_MEDIUM)
                end
            end
        end
        else begin
            skip_count ++;
            // write response 的 rdata 语义不在 spec 内；response/error 已在上方检查
        end
    endfunction

endclass
