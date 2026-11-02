// ============================================================================
// 文件名称：fat32_file_streamer.v
// 模块名称：fat32_file_streamer
// 功能描述：FAT32文件流式读取：沿簇链逐字节输出文件内容
// 目标器件：安路 EG4S20BG256
// ============================================================================
`timescale 1ns/1ps

module fat32_file_streamer #(
    parameter integer MAX_VISITED_CLUSTERS = 8192
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        file_start,
    input  wire [31:0] first_cluster,
    input  wire [31:0] file_size,
    input  wire [7:0]  sectors_per_cluster,
    input  wire [31:0] fat_start_lba,
    input  wire [31:0] data_start_lba,
    input  wire [31:0] max_cluster,
    output wire        file_busy,
    output reg         file_done,
    output reg         file_valid,
    output reg  [7:0]  file_byte,
    output reg  [31:0] file_byte_offset,
    output reg  [7:0]  fs_error,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);
    localparam ERR_NONE              = 8'h00;
    localparam ERR_SECTOR            = 8'h10;
    localparam ERR_FAT_LOOP          = 8'h23;
    localparam ERR_CLUSTER_RANGE     = 8'h24;
    localparam ERR_EARLY_EOF         = 8'h25;
    localparam ERR_VISITED_EXHAUSTED = 8'h26;

    localparam ST_IDLE       = 4'd0;
    localparam ST_DATA_REQ   = 4'd1;
    localparam ST_DATA_WAIT  = 4'd2;
    localparam ST_FAT_REQ    = 4'd3;
    localparam ST_FAT_WAIT   = 4'd4;
    localparam ST_FAT_PARSE  = 4'd5;
    localparam ST_LBA        = 4'd6;   // 由current_cluster计算数据扇区LBA
    localparam ST_FINISH     = 4'd7;

    localparam integer CHAIN_COUNT_WIDTH = $clog2(MAX_VISITED_CLUSTERS + 1);

    reg [3:0] state;
    reg [31:0] current_cluster;
    reg [31:0] next_cluster;
    reg [31:0] remaining_bytes;
    reg [7:0] sector_in_cluster;
    reg [8:0] fat_entry_offset;
    reg [7:0] fat_byte0, fat_byte1, fat_byte2, fat_byte3;
    reg [CHAIN_COUNT_WIDTH-1:0] chain_count;
    reg final_chain_check;

    assign file_busy = (state != ST_IDLE);

    // 簇号→数据扇区LBA：LBA = data_start_lba + (簇号-2)*每簇扇区数。
    //  1) 每簇扇区数由fat32_volume_scanner保证是2的幂（valid_spc），乘法用移位实现；
    //  2) 基址 data_start_lba - (2<<shift) 只依赖扫描结果，每拍寄存；
    //  3) 簇号写入current_cluster后，在ST_LBA状态计算"基址 + 簇号<<shift"，每簇多1拍。
    function [2:0] spc_to_shift;
        input [7:0] spc;
        begin
            case (spc)
                8'd2:   spc_to_shift = 3'd1;
                8'd4:   spc_to_shift = 3'd2;
                8'd8:   spc_to_shift = 3'd3;
                8'd16:  spc_to_shift = 3'd4;
                8'd32:  spc_to_shift = 3'd5;
                8'd64:  spc_to_shift = 3'd6;
                8'd128: spc_to_shift = 3'd7;
                default: spc_to_shift = 3'd0;   // 1（以及非法值，非法值扫描阶段已判错）
            endcase
        end
    endfunction

    reg [2:0]  spc_shift_r;
    reg [31:0] lba_base_r;      // data_start_lba - (2 << spc_shift)
    // 启动检查预寄存：first_cluster/file_size 由句柄查表得到，在 file_start 前至少 3 拍已稳定
    // （sd_card_bmp_v2 中 load_kick 之后要经过写请求握手才发 streamer_start）
    reg        size_zero_r;     // file_size == 0
    reg        first_bad_r;     // 首簇号越界或每簇扇区数为0

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spc_shift_r <= 3'd0;
            lba_base_r  <= 32'd0;
            size_zero_r <= 1'b1;
            first_bad_r <= 1'b1;
        end else begin
            spc_shift_r <= spc_to_shift(sectors_per_cluster);
            lba_base_r  <= data_start_lba - (32'd2 << spc_shift_r);
            size_zero_r <= (file_size == 0);
            first_bad_r <= (first_cluster < 2 || first_cluster > max_cluster ||
                            sectors_per_cluster == 0);
        end
    end

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            state <= ST_FINISH;
        end
    endtask

    task advance_to_next_cluster;
        input [31:0] cluster_value;
        begin
            chain_count <= chain_count + 1'b1;
            current_cluster <= cluster_value;
            state <= ST_LBA;        // 下一拍在ST_LBA计算LBA
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            file_done <= 1'b0;
            file_valid <= 1'b0;
            file_byte <= 8'd0;
            file_byte_offset <= 32'd0;
            fs_error <= ERR_NONE;
            sector_req <= 1'b0;
            sector_lba <= 32'd0;
            current_cluster <= 32'd0;
            next_cluster <= 32'd0;
            remaining_bytes <= 32'd0;
            sector_in_cluster <= 8'd0;
            fat_entry_offset <= 9'd0;
            fat_byte0 <= 8'd0;
            fat_byte1 <= 8'd0;
            fat_byte2 <= 8'd0;
            fat_byte3 <= 8'd0;
            chain_count <= 0;
            final_chain_check <= 1'b0;
        end else begin
            file_done <= 1'b0;
            file_valid <= 1'b0;
            sector_req <= 1'b0;

            if (state == ST_DATA_WAIT && sector_valid && remaining_bytes != 0) begin
                file_valid <= 1'b1;
                file_byte <= sector_byte;
                file_byte_offset <= file_size - remaining_bytes;
                remaining_bytes <= remaining_bytes - 1'b1;
            end

            if (state == ST_FAT_WAIT && sector_valid) begin
                if (sector_byte_index == fat_entry_offset)
                    fat_byte0 <= sector_byte;
                else if (sector_byte_index == fat_entry_offset + 1'b1)
                    fat_byte1 <= sector_byte;
                else if (sector_byte_index == fat_entry_offset + 2'd2)
                    fat_byte2 <= sector_byte;
                else if (sector_byte_index == fat_entry_offset + 2'd3)
                    fat_byte3 <= sector_byte;
            end

            case (state)
                ST_IDLE: if (file_start) begin
                    fs_error <= ERR_NONE;
                    file_byte_offset <= 32'd0;
                    remaining_bytes <= file_size;
                    sector_in_cluster <= 8'd0;
                    chain_count <= 1;
                    final_chain_check <= 1'b0;
                    if (size_zero_r) begin
                        state <= ST_FINISH;
                    end else if (first_bad_r) begin
                        finish_with_error(ERR_CLUSTER_RANGE);
                    end else begin
                        current_cluster <= first_cluster;
                        state <= ST_LBA;    // 下一拍在ST_LBA计算LBA
                    end
                end
                ST_LBA: begin
                    sector_lba <= lba_base_r + (current_cluster << spc_shift_r);
                    state <= ST_DATA_REQ;
                end
                ST_DATA_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_DATA_WAIT;
                end
                ST_DATA_WAIT: if (sector_done) begin
                    if (sector_error != 0) begin
                        finish_with_error(ERR_SECTOR);
                    end else if (remaining_bytes == 0 ||
                                 (remaining_bytes == 1 && sector_valid)) begin
                        final_chain_check <= 1'b1;
                        sector_in_cluster <= 8'd0;
                        fat_entry_offset <= {current_cluster[6:0], 2'b00};
                        sector_lba <= fat_start_lba + (current_cluster >> 7);
                        state <= ST_FAT_REQ;
                    end else if (sector_in_cluster + 1'b1 < sectors_per_cluster) begin
                        sector_in_cluster <= sector_in_cluster + 1'b1;
                        sector_lba <= sector_lba + 1'b1;
                        state <= ST_DATA_REQ;
                    end else begin
                        sector_in_cluster <= 8'd0;
                        fat_entry_offset <= {current_cluster[6:0], 2'b00};
                        sector_lba <= fat_start_lba + (current_cluster >> 7);
                        state <= ST_FAT_REQ;
                    end
                end
                ST_FAT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_FAT_WAIT;
                end
                ST_FAT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else
                        state <= ST_FAT_PARSE;
                end
                ST_FAT_PARSE: begin
                    next_cluster <= {4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0};
                    if (final_chain_check) begin
                        final_chain_check <= 1'b0;
                        if ({fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} >= 28'hffffff8)
                            state <= ST_FINISH;
                        else if ({4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} < 2 ||
                                 {4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} > max_cluster)
                            finish_with_error(ERR_CLUSTER_RANGE);
                        else
                            finish_with_error(ERR_FAT_LOOP);
                    end else if ({fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} >= 28'hffffff8) begin
                        finish_with_error(ERR_EARLY_EOF);
                    end else if ({4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} < 2 ||
                                 {4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} > max_cluster) begin
                        finish_with_error(ERR_CLUSTER_RANGE);
                    end else if (chain_count >= MAX_VISITED_CLUSTERS) begin
                        finish_with_error(ERR_VISITED_EXHAUSTED);
                    end else if ({4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0} == current_cluster) begin
                        finish_with_error(ERR_FAT_LOOP);
                    end else begin
                        advance_to_next_cluster({4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0});
                    end
                end
                ST_FINISH: begin
                    file_done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
