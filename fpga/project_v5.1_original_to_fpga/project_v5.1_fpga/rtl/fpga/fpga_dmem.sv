`default_nettype none

module fpga_dmem #(
    parameter int unsigned ADDR_WIDTH = core_pkg::DMEM_ADDR_WIDTH
) (
    input  logic                          clk_i,
    input  logic                          we_i,
    input  logic [3:0]                    be_i,
    input  logic [core_pkg::XLEN-1:0]     addr_i,
    input  logic [core_pkg::XLEN-1:0]     wdata_i,
    output logic [core_pkg::XLEN-1:0]     rdata_o
);
    import core_pkg::*;

    localparam int unsigned DEPTH = 1 << ADDR_WIDTH;

    logic [ADDR_WIDTH-1:0] word_addr;

    assign word_addr = ADDR_WIDTH'((addr_i - DMEM_BASE) >> 2);

    altsyncram u_dmem_ram (
        .clock0         (~clk_i),   // M9K RAM一般是 同步读
        .address_a      (word_addr),
        .data_a         (wdata_i),
        .wren_a         (we_i),
        .byteena_a      (be_i),
        .q_a            (rdata_o),

        .wren_b         (1'b0),
        .rden_a         (1'b1),
        .rden_b         (1'b1),
        .data_b         (1'b0),
        .address_b      (1'b0),
        .clock1         (1'b1),
        .clocken0       (1'b1),
        .clocken1       (1'b1),
        .clocken2       (1'b1),
        .clocken3       (1'b1),
        .aclr0          (1'b0),
        .aclr1          (1'b0),
        .byteena_b      (1'b1),
        .addressstall_a (1'b0),
        .addressstall_b (1'b0),
        .q_b            (),
        .eccstatus      ()
    );

    defparam
        u_dmem_ram.operation_mode = "SINGLE_PORT",
        u_dmem_ram.width_a = core_pkg::XLEN,
        u_dmem_ram.widthad_a = ADDR_WIDTH,
        u_dmem_ram.numwords_a = DEPTH,
        u_dmem_ram.outdata_reg_a = "UNREGISTERED",
        u_dmem_ram.address_aclr_a = "NONE",
        u_dmem_ram.outdata_aclr_a = "NONE",
        u_dmem_ram.indata_aclr_a = "NONE",
        u_dmem_ram.wrcontrol_aclr_a = "NONE",
        u_dmem_ram.byteena_aclr_a = "NONE",
        u_dmem_ram.width_byteena_a = 4,
        u_dmem_ram.byte_size = 8,
        u_dmem_ram.ram_block_type = "M9K",
        u_dmem_ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
        u_dmem_ram.init_file = "../mem/current_dmem.mif",
        u_dmem_ram.init_file_layout = "PORT_A",
        u_dmem_ram.maximum_depth = 0,
        u_dmem_ram.intended_device_family = "Cyclone IV E",
        u_dmem_ram.lpm_type = "altsyncram";

endmodule

`default_nettype wire
