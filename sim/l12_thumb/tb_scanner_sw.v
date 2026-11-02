`timescale 1ns/1ps

// fat32_volume_scanner 识别 SW1/SW2/SW3/SW12.BMP 仿真
// 构造一张无MBR的FAT32卷：扇区0=引导扇区，根目录首扇区模拟实际卡的目录：
//   卷标、System Volume Information(2个长文件名项+短名项)、PIC1~4、SW1、SW2、SW3、SW12
module tb_scanner_sw;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  scan_start = 0;
    wire scan_busy, scan_done;
    wire [7:0] fs_error, spc;
    wire [31:0] part_lba, fat_lba, data_lba, max_cl;
    wire [3:0] res_valid, sw_valid;
    wire [31:0] r0c, r1c, r2c, r3c, r0s, r1s, r2s, r3s;
    wire [31:0] s0c, s1c, s2c, s3c, s0s, s1s, s2s, s3s;
    wire sector_req; wire [31:0] sector_lba;
    reg  sector_busy = 0, sector_valid = 0, sector_done = 0;
    reg  [7:0] sector_byte = 0; reg [8:0] sector_byte_index = 0;

    fat32_volume_scanner dut (
        .clk(clk), .rst_n(rst_n), .scan_start(scan_start), .scan_busy(scan_busy), .scan_done(scan_done),
        .fs_error(fs_error), .partition_lba(part_lba), .sectors_per_cluster(spc), .fat_start_lba(fat_lba),
        .data_start_lba(data_lba), .max_cluster(max_cl), .resource_valid(res_valid),
        .resource0_cluster(r0c), .resource1_cluster(r1c), .resource2_cluster(r2c), .resource3_cluster(r3c),
        .resource0_size(r0s), .resource1_size(r1s), .resource2_size(r2s), .resource3_size(r3s),
        .sw_valid(sw_valid), .sw0_cluster(s0c), .sw1_cluster(s1c), .sw2_cluster(s2c), .sw3_cluster(s3c),
        .sw0_size(s0s), .sw1_size(s1s), .sw2_size(s2s), .sw3_size(s3s),
        .sector_req(sector_req), .sector_lba(sector_lba), .sector_busy(sector_busy), .sector_valid(sector_valid),
        .sector_byte(sector_byte), .sector_byte_index(sector_byte_index), .sector_done(sector_done),
        .sector_error(8'd0));

    // ---------------- 磁盘镜像 ----------------
    localparam RSV = 32, FATSZ = 100, SPC = 8;
    localparam ROOT_LBA = RSV + 2*FATSZ;     // 根目录簇2
    reg [7:0] boot [0:511];
    reg [7:0] root [0:511];
    integer i, e;

    task put_name(input integer ent, input [8*11-1:0] nm, input [7:0] attr, input [31:0] cl, input [31:0] sz);
        integer k; begin
            for (k = 0; k < 11; k = k + 1) root[ent*32 + k] = nm[8*(10-k) +: 8];
            root[ent*32 + 11] = attr;
            root[ent*32 + 20] = cl[23:16]; root[ent*32 + 21] = cl[31:24];
            root[ent*32 + 26] = cl[7:0];   root[ent*32 + 27] = cl[15:8];
            root[ent*32 + 28] = sz[7:0];   root[ent*32 + 29] = sz[15:8];
            root[ent*32 + 30] = sz[23:16]; root[ent*32 + 31] = sz[31:24];
        end
    endtask

    initial begin
        for (i = 0; i < 512; i = i + 1) begin boot[i] = 0; root[i] = 0; end
        boot[0] = 8'hEB; boot[11] = 8'h00; boot[12] = 8'h02; boot[13] = SPC;
        boot[14] = RSV; boot[16] = 2; boot[32] = 8'h00; boot[33] = 8'h00; boot[34] = 8'hF0; // 总扇区
        boot[36] = FATSZ; boot[44] = 2; boot[510] = 8'h55; boot[511] = 8'hAA;
        e = 0;
        put_name(e, "NO NAME    ", 8'h08, 0, 0);                 e = e + 1;  // 卷标
        put_name(e, "Bxxxxxxxxxx", 8'h0F, 0, 0);                 e = e + 1;  // 长文件名项
        put_name(e, "Axxxxxxxxxx", 8'h0F, 0, 0);                 e = e + 1;
        put_name(e, "SYSTEM~1   ", 8'h16, 3, 0);                 e = e + 1;  // SVI目录
        put_name(e, "PIC1    BMP", 8'h20, 10, 2359350);          e = e + 1;
        put_name(e, "PIC2    BMP", 8'h20, 20, 921654);           e = e + 1;
        put_name(e, "PIC3    BMP", 8'h20, 30, 230454);           e = e + 1;
        put_name(e, "PIC4    BMP", 8'h20, 40, 921654);           e = e + 1;
        put_name(e, "SW1     BMP", 8'h20, 50, 921654);           e = e + 1;
        put_name(e, "SW2     BMP", 8'h20, 60, 921655);           e = e + 1;
        put_name(e, "SW3     BMP", 8'h20, 70, 921656);           e = e + 1;
        put_name(e, "SW12    BMP", 8'h20, 80, 921657);           e = e + 1;
    end

    // ---------------- 扇区读模型 ----------------
    integer b;
    always @(posedge clk) begin
        sector_done <= 1'b0;
        if (sector_req && !sector_busy) begin
            sector_busy <= 1'b1;
            fork begin : rd
                repeat (5) @(posedge clk);
                for (b = 0; b < 512; b = b + 1) begin
                    @(posedge clk);
                    sector_valid <= 1'b1; sector_byte_index <= b;
                    sector_byte <= (sector_lba == 0) ? boot[b] : (sector_lba == ROOT_LBA) ? root[b] : 8'h00;
                    @(posedge clk); sector_valid <= 1'b0;
                end
                @(posedge clk) sector_done <= 1'b1;
                @(posedge clk) sector_busy <= 1'b0;
            end join_none
        end
    end

    initial begin
        #50 rst_n = 1;
        #50 @(posedge clk) scan_start = 1; @(posedge clk) scan_start = 0;
        wait (scan_done); @(posedge clk);
        $display("fs_error=%h resource_valid=%b sw_valid=%b", fs_error, res_valid, sw_valid);
        $display("PIC簇: %0d %0d %0d %0d   SW簇: %0d %0d %0d %0d   SW大小: %0d %0d %0d %0d",
                 r0c, r1c, r2c, r3c, s0c, s1c, s2c, s3c, s0s, s1s, s2s, s3s);
        if (fs_error == 0 && res_valid == 4'hF && sw_valid == 4'hF &&
            s0c == 50 && s1c == 60 && s2c == 70 && s3c == 80 && r0c == 10 && r3c == 40)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $finish;
    end
    initial begin #20_000_000 $display("超时 RESULT: FAIL"); $finish; end
endmodule
