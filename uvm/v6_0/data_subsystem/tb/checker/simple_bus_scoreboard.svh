//------------------------------------------------------------------------------
// 文件      : uvm/v6_0/data_subsystem/tb/checker/simple_bus_scoreboard.svh
// 用途      : v6.0 data_subsystem UVM 环境的基础 DMEM/GPIO0 scoreboard。
//
// 规范：
//   - 只接收 monitor 观察到的完整 transfer，不驱动 DUT 或参与 sequence 仲裁。
//   - 当前检查 DMEM 与 GPIO0；UART0/TIMER0 由后续 reference model 覆盖，
//     response-delay 由 wrapper_scoreboard 检查。
//
// 功能：
//   - 维护 DMEM、GPIO0 OUT/OE 的参考状态，并比较可建模的读响应。
//   - 检查 DMEM/GPIO0 的 expected error 行为。
//------------------------------------------------------------------------------

class simple_bus_scoreboard extends uvm_scoreboard;

    `uvm_component_utils(simple_bus_scoreboard)

    uvm_analysis_imp #(simple_bus_transfer, simple_bus_scoreboard) tr_imp;

    // 统计信息：correct 为完整匹配，error 为已检查条件不符，partial 为仅完成部分检查，
    // skip 为当前没有 target-specific checker 的 transfer；四类计数之和必须等于 compare_count。
    int unsigned compare_count;
    int unsigned correct_count;
    int unsigned error_count;
    int unsigned partial_count;
    int unsigned skip_count;

    function new(string name = "simple_bus_scoreboard", uvm_component parent = null);
        super.new(name, parent);        
        compare_count = 0;
        correct_count = 0;
        error_count   = 0;
        partial_count = 0;
        skip_count    = 0;
        ref_model_rst();
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        tr_imp = new("bus_tr_imp", this);
    endfunction

    // analysis imp 收到 T 后回调
    function void write(simple_bus_transfer tr);
        compare_count ++;
        unique case (tr.observed_item.decode_target())
        soc_pkg::TARGET_DMEM: begin
            dmem_ref_model(tr.observed_item);
            check_dmem(tr);
        end
        soc_pkg::TARGET_GPIO0: begin
            gpio0_ref_model(tr.observed_item);
            check_gpio0(tr);
        end
        default: begin
            skip_count ++;
            `uvm_info(get_type_name(), {"skip check: unimplemented reference model item: ", tr.transfer2string("transfer")}, UVM_MEDIUM)
        end
        endcase
    endfunction

    function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        if (compare_count != correct_count + error_count + partial_count + skip_count) begin
            `uvm_fatal(get_type_name(),
                $sformatf("compare count mismatch: correct(%0d) + error(%0d) + partial(%0d) + skip(%0d) = %0d != total compare(%0d)",
                          correct_count, error_count, partial_count, skip_count,
                          correct_count + error_count + partial_count + skip_count, compare_count))
        end
    endfunction

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("simple bus check finish, result: check_num=%0d including correct_num=%0d, error_num=%0d, partial_num=%0d and skip_num=%0d",
                compare_count, correct_count, error_count, partial_count, skip_count), UVM_MEDIUM)
    endfunction

    //-----------------------------------------------------------------------
    // helper
    //-----------------------------------------------------------------------

    // 命中 dmem 时，将 core 返回的 byte 地址转化为 word 地址
    function logic[core_pkg::DMEM_ADDR_WIDTH-1:0] addr_2_dmem_word_key(logic [31:0] addr);
        return (((addr - core_pkg::DMEM_BASE) >> 2));
    endfunction

    // 利用 dmem_ref_model 的状态进行对比
    function void check_dmem(simple_bus_transfer tr);
        bit [core_pkg::DMEM_ADDR_WIDTH-1:0] word_key = addr_2_dmem_word_key(tr.observed_item.addr);
        if (tr.error) begin         // 访问 dmem 时，dut 不应 resp error
            error_count ++;
            `uvm_error(get_type_name(), {"DMEM access returned error:",tr.transfer2string()})
        end
        else if (!tr.observed_item.write) begin   // read dmem 是需要 check 返回值与 gold model 是否一样
            if (!ref_valid.exists(word_key)) begin
                partial_count ++;
                `uvm_info(get_type_name(),     // uvm 未写 dmem 就进行读取，spec 未规定这种情况，因此不做对比，但允许（如 dmem 初始化）
                    $sformatf("partial check: read a DMEM word but never write it, dmem word addr=0x%08x", word_key), UVM_MEDIUM)
            end
            else begin
                if (tr.rdata !== ref_dmem[word_key]) begin
                    error_count ++;
                    `uvm_error(get_type_name(),
                        $sformatf("DMEM read mismatch, dmem word addr=0x%08x expected=0x%08x actual=0x%08x",
                                  word_key, ref_dmem[word_key], tr.rdata))
                end
                else begin
                    correct_count ++;
                    `uvm_info(get_type_name(),
                        $sformatf("DMEM read match, dmem word addr=0x%08x expected=0x%08x actual=0x%08x",
                                  word_key, ref_dmem[word_key], tr.rdata), UVM_MEDIUM)
                end
            end
        end
        else begin
            // write 时 rdata无需做检查
            partial_count ++;
            `uvm_info(get_type_name(),
                $sformatf("partial check: DMEM write rdata is not checked, dmem word addr=0x%08x", word_key), UVM_MEDIUM)
            // write response 的 rdata 语义不在 spec 内；response/error 已在上方检查
        end
    endfunction

    function logic [11:0] addr_2_gpio0_offset(logic [core_pkg::XLEN-1:0] addr);
        logic [core_pkg::XLEN-1:0] byte_offset;
        byte_offset = addr - soc_pkg::GPIO0_BASE;
        return {byte_offset[11:2], 2'b00};
    endfunction

    // GPIO0 当前完整比较 OUT/OE read；其他已定义寄存器只检查 error。所有成功 write 的 rdata
    // 都不具语义，计入 partial；OUT/OE 的写入结果由后续 readback 比较。
    function void check_gpio0(simple_bus_transfer tr);
        logic [11:0] offset = addr_2_gpio0_offset(tr.observed_item.addr);
        if (offset >= 12'h028) begin  // 未定义的 offset，按 spec 此时应 resp error
            if (tr.error) begin
                correct_count ++;
                `uvm_info(get_type_name(),
                    $sformatf("GPIO0 unknown offset returned error as expected, offset=0x%03x addr=0x%08x",
                              offset, tr.observed_item.addr), UVM_MEDIUM)
            end else begin
                error_count ++;
                `uvm_error(get_type_name(),
                    $sformatf("GPIO0 unknown offset missing error, offset=0x%03x addr=0x%08x",
                              offset, tr.observed_item.addr))
            end
        end else begin
            if (tr.error) begin  // 已定义的 offset，按 spec 此时不会出现 resp error
                error_count ++;
                `uvm_error(get_type_name(),
                    $sformatf("GPIO0 known offset returned error, offset=0x%03x addr=0x%08x",
                              offset, tr.observed_item.addr))
            end else begin
                if (!tr.observed_item.write) begin // 只有读操作才需要对比
                    if (offset == 12'h000) begin   // 读 out 寄存器
                        if (tr.rdata == ref_gpio0_out) begin
                            correct_count ++;
                            `uvm_info(get_type_name(),
                                $sformatf("GPIO0 OUT read match, offset=0x%03x expected=0x%08x actual=0x%08x",
                                          offset, ref_gpio0_out, tr.rdata), UVM_MEDIUM)
                        end else begin
                            error_count ++;
                            `uvm_error(get_type_name(),
                                $sformatf("GPIO0 OUT read mismatch, offset=0x%03x expected=0x%08x actual=0x%08x",
                                          offset, ref_gpio0_out, tr.rdata))
                        end
                    end
                    else if (offset == 12'h008) begin   // 读 oe 寄存器
                        if (tr.rdata == ref_gpio0_oe) begin
                            correct_count ++;
                            `uvm_info(get_type_name(),
                                $sformatf("GPIO0 OE read match, offset=0x%03x expected=0x%08x actual=0x%08x",
                                          offset, ref_gpio0_oe, tr.rdata), UVM_MEDIUM)
                        end else begin
                            error_count ++;
                            `uvm_error(get_type_name(),
                                $sformatf("GPIO0 OE read mismatch, offset=0x%03x expected=0x%08x actual=0x%08x",
                                          offset, ref_gpio0_oe, tr.rdata))
                        end
                    end
                    else begin
                        // 其他寄存器读不检查
                        partial_count ++;
                        `uvm_info(get_type_name(),
                            $sformatf("partial check: read a GPIO0 register without reference model, offset=0x%03x addr=0x%08x",
                                      offset, tr.observed_item.addr), UVM_MEDIUM)
                    end
                end else begin
                    // write 只需检查 error 是否错误，rdata无需做检查
                    partial_count ++;
                    `uvm_info(get_type_name(),
                        $sformatf("partial check: GPIO0 write rdata is not checked, offset=0x%03x addr=0x%08x",
                                  offset, tr.observed_item.addr), UVM_MEDIUM)
                end
            end
        end
    endfunction

    //-----------------------------------------------------------------------
    // gold model
    //-----------------------------------------------------------------------

    function ref_model_rst();
        dmem_ref_model_rst();
        gpio0_ref_model_rst();
    endfunction

    // dmem 的 gold model
    bit [core_pkg::XLEN-1:0] ref_dmem  [logic [core_pkg::DMEM_ADDR_WIDTH-1:0]]; // 关联数组，作为 dmem 的模型参考
    bit                      ref_valid [logic [core_pkg::DMEM_ADDR_WIDTH-1:0]]; // 参考模型的 word 是否有效，可用于后续复位等行为拓展
    function dmem_ref_model_rst();
        ref_dmem.delete();
        ref_valid.delete();
    endfunction
    function void dmem_ref_model(simple_bus_item item);
        bit [core_pkg::DMEM_ADDR_WIDTH-1:0] word_key = addr_2_dmem_word_key(item.addr);
        if (item.decode_target() != soc_pkg::TARGET_DMEM) begin  // ref model 调用保护
            `uvm_fatal(get_type_name(),
                $sformatf("simple_bus_scoreboard choice wrong ref model, expect %s but choice DMEM",
                          item.target_name()))
        end else begin
            // dmem 的参考行为
            if (item.write) begin
                if (!ref_valid.exists(word_key)) begin     // 当前不考虑测试中复位导致的 write 过无效情况，只要首次 write 过就认为有效
                    ref_valid[word_key] = 1'b1;
                    ref_dmem[word_key]  = '0;
                end
                ref_dmem[word_key] [7:0]   = item.be[0] ? item.wdata[7:0]   : ref_dmem[word_key] [7:0];
                ref_dmem[word_key] [15:8]  = item.be[1] ? item.wdata[15:8]  : ref_dmem[word_key] [15:8];
                ref_dmem[word_key] [23:16] = item.be[2] ? item.wdata[23:16] : ref_dmem[word_key] [23:16];
                ref_dmem[word_key] [31:24] = item.be[3] ? item.wdata[31:24] : ref_dmem[word_key] [31:24];
            end
        end
    endfunction

    // gpio 的 gold model
    // 当前只完整建模 000 OUT 和 008 OE 两个寄存器，其他寄存器只根据 spec 建模"合法访问不 error",具体数值不比较
    logic [31:0] ref_gpio0_out, ref_gpio0_oe;
    function void gpio0_ref_model_rst();
        ref_gpio0_out = '0;
        ref_gpio0_oe  = '0;
    endfunction
    function void gpio0_ref_model(simple_bus_item item);
        logic [11:0] offset = addr_2_gpio0_offset(item.addr);
        if (item.decode_target() != soc_pkg::TARGET_GPIO0) begin  // ref model 调用保护
            `uvm_fatal(get_type_name(),
                $sformatf("simple_bus_scoreboard choice wrong ref model, expect %s but choice GPIO0",
                          item.target_name()))
        end else begin
            // gpio0 的参考行为
            if (item.write) begin
                if (offset == 12'h000) begin
                    ref_gpio0_out[7:0]   = item.be[0] ? item.wdata[7:0]   : ref_gpio0_out[7:0];
                    ref_gpio0_out[15:8]  = item.be[1] ? item.wdata[15:8]  : ref_gpio0_out[15:8];
                    ref_gpio0_out[23:16] = item.be[2] ? item.wdata[23:16] : ref_gpio0_out[23:16];
                    ref_gpio0_out[31:24] = item.be[3] ? item.wdata[31:24] : ref_gpio0_out[31:24];
                end
                if (offset == 12'h008) begin
                    ref_gpio0_oe[7:0]   = item.be[0] ? item.wdata[7:0]   : ref_gpio0_oe[7:0];
                    ref_gpio0_oe[15:8]  = item.be[1] ? item.wdata[15:8]  : ref_gpio0_oe[15:8];
                    ref_gpio0_oe[23:16] = item.be[2] ? item.wdata[23:16] : ref_gpio0_oe[23:16];
                    ref_gpio0_oe[31:24] = item.be[3] ? item.wdata[31:24] : ref_gpio0_oe[31:24];
                end
            end
        end
    endfunction

endclass
