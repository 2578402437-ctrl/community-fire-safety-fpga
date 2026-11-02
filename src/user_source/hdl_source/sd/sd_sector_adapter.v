// ============================================================================
// 文件名称：sd_sector_adapter.v
// 模块名称：sd_sector_adapter
// 功能描述：扇区读接口适配：FAT32模块的sector接口转sd_card_top接口
// 目标器件：安路 EG4S20BG256
// ============================================================================
`timescale 1ns/1ps

// SD卡扇区读接口适配层
// 把FAT32模块的sector_*接口，转换成官方sd_card_top的sd_sec_*接口
//
// 官方sd_card_top缺三个信号，由本层补出：
//   sector_busy       —— 请求发出到读完成之间为1
//   sector_byte_index —— 扇区内字节索引0~511，valid时自增
//   sector_error      —— 官方无错误输出，固定0
//
// sd_sec_read为电平触发：已核实sd_card_sec_read_write.v的S_WAIT_READ_WRITE
// 在sd_sec_read==1时锁存地址并进入S_CMD17；S_READ_END仅持续1周期后回到
// S_WAIT_READ_WRITE，而本层在sd_sec_read_end当拍撤销请求（下一拍生效），
// 因此不会重复触发第二次读。

module sd_sector_adapter (
    input  wire        clk,
    input  wire        rst_n,

    // === FAT32模块侧 ===
    input  wire        sector_req,
    input  wire [31:0] sector_lba,
    output wire        sector_busy,
    output wire        sector_valid,
    output wire [7:0]  sector_byte,
    output wire [8:0]  sector_byte_index,
    output wire        sector_done,
    output wire [7:0]  sector_error,

    // === 官方sd_card_top侧 ===
    output reg         sd_sec_read,
    output reg  [31:0] sd_sec_read_addr,
    input  wire        sd_sec_read_data_valid,
    input  wire [7:0]  sd_sec_read_data,
    input  wire        sd_sec_read_end
);

    reg [8:0] byte_cnt;
    reg       busy_reg;

    assign sector_busy       = busy_reg;
    assign sector_valid      = sd_sec_read_data_valid;
    assign sector_byte       = sd_sec_read_data;
    assign sector_byte_index = byte_cnt;
    assign sector_done       = sd_sec_read_end;
    assign sector_error      = 8'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sd_sec_read      <= 1'b0;
            sd_sec_read_addr <= 32'd0;
            byte_cnt         <= 9'd0;
            busy_reg         <= 1'b0;
        end else begin
            if (sector_req && !busy_reg) begin
                sd_sec_read      <= 1'b1;
                sd_sec_read_addr <= sector_lba;
                busy_reg         <= 1'b1;
                byte_cnt         <= 9'd0;
            end
            else if (sd_sec_read_end) begin
                sd_sec_read <= 1'b0;
                busy_reg    <= 1'b0;
                byte_cnt    <= 9'd0;
            end
            else if (sd_sec_read_data_valid) begin
                byte_cnt <= byte_cnt + 9'd1;
            end
        end
    end

endmodule
