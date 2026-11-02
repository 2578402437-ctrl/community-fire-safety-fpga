`timescale 1ns/1ps
// 扇区级轮换仲裁仿真
// 真实模块：fat32_file_streamer + wav_stream_player + sd_sector_adapter；
// 仲裁段由 extract_arb.py 从 sd_card_bmp_v2.v 原样抠出（arb_chunk.vh），+define+OLD_ARB 时用旧版。
// 行为级：SD卡（含FAT链）、扫描器请求方（与真实扫描器相同的"看到!busy下一拍打1拍req"握手）、
//         scaler_hold 伪随机暂停。
// 检查：
//   1. 流读器每个文件字节与期望一致、字节数正确、无fs_error、每次加载不挂死
//   2. 扫描器读到的字节与期望一致、不挂死
//   3. WAV输出样本连续（同l13编码，0=下溢静音），统计开播后静音样本数（总计/加载期间）
//   4. 每次扇区done都送给发起该次请求的owner（owner在传输中途不变）
//   5. 记录每次图片加载耗时，新旧版对比
module tb_arb_rr;
    // ---------- 参数 ----------
    localparam [31:0] FAT_LBA  = 32'd100;
    localparam [31:0] DATA_LBA = 32'd1000;
    localparam [7:0]  SPC      = 8'd8;
    localparam [31:0] BGM_LBA  = 32'd50000, BGM_N = 32'd40;
    localparam [31:0] SCAN_LBA = 32'd10, SCAN_N = 8;
`ifndef TICK
    `define TICK 25          // 每多少个rclk消费1个样本（25 = 1us，WAV约占SD带宽16%，比实板严2倍）
`endif
`ifndef HOLD_EN
    `define HOLD_EN 1
`endif

    reg clk = 0, rclk = 0, rst = 1;
    always #5  clk  = ~clk;    // 100MHz（sd_card_clk）
    always #20 rclk = ~rclk;   // 25MHz（video_clk）

    // ---------- 数据图样 ----------
    function [7:0] data_byte;
        input [31:0] lba; input [8:0] k;
        data_byte = lba[7:0] * 8'd7 + k[7:0] * 8'd13 + {7'd0, k[8]} * 8'd101;
    endfunction
    // FAT扇区：每项4字节，簇c的下一簇=c+1；IMG_CLUSTERS-1+2 为最后一簇（EOC）
    integer IMG_CLUSTERS;
    function [7:0] fat_byte;
        input [31:0] lba; input [8:0] k;
        reg [31:0] c, v;
        begin
            c = (lba - FAT_LBA) * 128 + k / 4;
            v = (c + 1 >= IMG_CLUSTERS + 2) ? 32'h0FFF_FFFF : c + 1;
            fat_byte = v >> (8 * (k % 4));
        end
    endfunction
    function [15:0] wav_sample;
        input [31:0] lba; input [8:0] k;
        wav_sample = {2'b01, 14'd0} | ((lba - BGM_LBA) * 256 + k / 2);
    endfunction

    // ---------- 行为级SD卡（每扇区约 100 + 512*8 拍 ≈ 42us）----------
    wire        sd_rd;
    wire [31:0] sd_addr;
    reg         sd_dv = 0, sd_end = 0;
    reg  [7:0]  sd_d = 0;
    integer     k;
    reg [15:0]  s;
    initial begin
        forever begin
            @(posedge clk);
            if (sd_rd && !sd_end) begin
                repeat (100) @(posedge clk);
                for (k = 0; k < 512; k = k + 1) begin
                    repeat (7) @(posedge clk);
                    if (sd_addr >= BGM_LBA) begin
                        s = wav_sample(sd_addr, k);
                        sd_d <= k[0] ? s[15:8] : s[7:0];
                    end else if (sd_addr >= FAT_LBA && sd_addr < DATA_LBA)
                        sd_d <= fat_byte(sd_addr, k);
                    else
                        sd_d <= data_byte(sd_addr, k);
                    sd_dv <= 1; @(posedge clk); sd_dv <= 0;
                end
                sd_end <= 1; @(posedge clk); sd_end <= 0;
                @(posedge clk);
            end
        end
    end

    // ---------- 仲裁段（真实RTL文本）----------
    wire        scanner_sector_req, streamer_sector_req;
    wire [31:0] scanner_sector_lba, streamer_sector_lba;
    wire        streamer_busy;
    reg         scanner_busy;
    wire        arb_sector_req;
    wire [31:0] arb_sector_lba;
    wire        arb_sector_busy, arb_sector_valid, arb_sector_done;
    wire [7:0]  arb_sector_byte, arb_sector_error;
    wire [8:0]  arb_sector_byte_index;
`ifdef OLD_ARB
    wire        scaler_hold;
`endif
`include "arb_chunk.vh"

    reg hold_r = 0;
    assign scaler_hold = hold_r;

`ifdef OLD_ARB
    wire busy_scan = sel_scan ? arb_sector_busy : 1'b1;
    wire busy_img  = sel_img  ? (arb_sector_busy | scaler_hold) : 1'b1;
    wire busy_wav  = sel_wav  ? arb_sector_busy : 1'b1;
`else
    wire busy_scan = grant_busy_scan;
    wire busy_img  = grant_busy_img | scaler_hold;
    wire busy_wav  = grant_busy_wav;
`endif

    sd_sector_adapter u_ad (.clk(clk), .rst_n(~rst), .sector_req(arb_sector_req), .sector_lba(arb_sector_lba),
        .sector_busy(arb_sector_busy), .sector_valid(arb_sector_valid), .sector_byte(arb_sector_byte),
        .sector_byte_index(arb_sector_byte_index), .sector_done(arb_sector_done), .sector_error(arb_sector_error),
        .sd_sec_read(sd_rd), .sd_sec_read_addr(sd_addr), .sd_sec_read_data_valid(sd_dv),
        .sd_sec_read_data(sd_d), .sd_sec_read_end(sd_end));

    // ---------- 图片流读器 ----------
    reg         f_start = 0;
    reg  [31:0] f_size  = 0;
    wire        f_done, f_valid;
    wire [7:0]  f_byte, f_err;
    wire [31:0] f_off;
    fat32_file_streamer u_st (
        .clk(clk), .rst_n(~rst), .file_start(f_start), .first_cluster(32'd2), .file_size(f_size),
        .sectors_per_cluster(SPC), .fat_start_lba(FAT_LBA), .data_start_lba(DATA_LBA), .max_cluster(32'd100000),
        .file_busy(streamer_busy), .file_done(f_done), .file_valid(f_valid), .file_byte(f_byte),
        .file_byte_offset(f_off), .fs_error(f_err),
        .sector_req(streamer_sector_req), .sector_lba(streamer_sector_lba),
        .sector_busy(busy_img), .sector_valid(sel_img ? arb_sector_valid : 1'b0),
        .sector_byte(arb_sector_byte), .sector_byte_index(arb_sector_byte_index),
        .sector_done(sel_img ? arb_sector_done : 1'b0), .sector_error(arb_sector_error));

    integer img_bytes = 0, img_err = 0;
    always @(posedge clk) if (f_valid) begin
        if (f_byte !== data_byte(DATA_LBA + f_off / 512, f_off % 512)) begin
            img_err = img_err + 1;
            if (img_err < 6) $display("[IMG_ERR] t=%0t off=%0d got=%h exp=%h", $time, f_off, f_byte,
                                      data_byte(DATA_LBA + f_off / 512, f_off % 512));
        end
        img_bytes = img_bytes + 1;
    end

    // ---------- 行为级扫描器（握手与 fat32_volume_scanner 相同）----------
    reg        sc_req = 0;
    reg [31:0] sc_lba = 0;
    reg        sc_go  = 0;
    integer    sc_err = 0, sc_bytes = 0, sc_sectors = 0;
    assign scanner_sector_req = sc_req;
    assign scanner_sector_lba = sc_lba;
    initial scanner_busy = 0;
    always @(posedge clk) begin
        if (sel_scan && arb_sector_valid) begin
            if (arb_sector_byte !== data_byte(sc_lba, arb_sector_byte_index)) sc_err = sc_err + 1;
            sc_bytes = sc_bytes + 1;
        end
    end
    task do_scan;
        integer n, w;
        begin
            scanner_busy = 1;
            for (n = 0; n < SCAN_N; n = n + 1) begin
                @(posedge clk); sc_lba <= SCAN_LBA + n;
                @(posedge clk);
                while (busy_scan) @(posedge clk);       // ST_*_REQ: if (!sector_busy)
                sc_req <= 1'b1;
                @(posedge clk); sc_req <= 1'b0;                          // 下一拍打1拍请求
                w = 0;
                while (!(sel_scan && arb_sector_done)) begin
                    @(posedge clk); w = w + 1;
                    if (w > 2000000) begin $display("[HANG] scanner t=%0t", $time); $finish; end
                end
                sc_sectors = sc_sectors + 1;
            end
            @(posedge clk);
            scanner_busy = 0;
        end
    endtask

    // ---------- WAV（换曲/循环控制照抄 sd_card_bmp_v2，单曲目）----------
    reg  play_en = 0, wav_go = 0;
    wire wav_end_wr, wav_idle_wr;
    always @(posedge clk or posedge rst) begin
        if (rst) play_en <= 1'b0;
        else if (!play_en) begin
            if (wav_go && wav_idle_wr) play_en <= 1'b1;
        end else if (wav_end_wr) play_en <= 1'b0;
    end
    reg [5:0] tc = 0; wire tick = (tc == `TICK - 1);
    always @(posedge rclk) tc <= tick ? 0 : tc + 1;
    wire signed [15:0] so; wire sv, act;
    wav_stream_player u_wav (
        .wr_clk(clk), .wr_rst_n(~rst), .play_enable(play_en),
        .start_lba(BGM_LBA), .total_sectors(BGM_N),
        .sector_req(wav_sector_req), .sector_lba(wav_sector_lba), .sector_busy(busy_wav),
        .sector_valid(sel_wav ? arb_sector_valid : 1'b0),
        .sector_byte(arb_sector_byte), .sector_byte_index(arb_sector_byte_index),
        .sector_done(sel_wav ? arb_sector_done : 1'b0), .sector_error(arb_sector_error),
        .stream_end_wr(wav_end_wr), .stream_idle_wr(wav_idle_wr),
        .rd_clk(rclk), .rd_rst_n(~rst), .sample_tick(tick), .sample_out(so), .sample_valid(sv),
        .sample_ready(1'b1), .sample_counter(), .stream_active(act), .stream_end(), .buffer_low());

    // 样本序列检查（同l13）：开播后不得出现0；循环时序号回0
    reg         started = 0;
    reg  [13:0] exp_off = 0;
    reg         in_load = 0;
    integer seq_err = 0, silent = 0, silent_load = 0, loops = 0, samples = 0;
    always @(posedge rclk) if (sv) begin
        if (so == 0) begin
            if (started) begin silent = silent + 1; if (in_load) silent_load = silent_load + 1; end
        end else if (!started && so[13:0] == 0) begin
            started <= 1; exp_off <= 1; samples = samples + 1;
        end else if (so[13:0] == exp_off) begin
            exp_off <= exp_off + 1; samples = samples + 1;
        end else if (so[13:0] == 0 && exp_off == BGM_N * 256) begin
            exp_off <= 1; loops = loops + 1; samples = samples + 1;
        end else begin
            seq_err = seq_err + 1;
            if (seq_err < 6) $display("[SEQ_ERR] t=%0t exp=%0d got=%0d", $time, exp_off, so[13:0]);
        end
    end

    // ---------- 检查4：done 必须送给发起请求的 owner ----------
    reg [1:0] acc_owner; reg acc_v = 0;
    integer own_err = 0, acc_n = 0, acc_img = 0, acc_wav = 0, acc_scan = 0;
    always @(posedge clk) begin
        if (arb_sector_req && !arb_sector_busy) begin
            acc_owner <= bus_owner; acc_v <= 1; acc_n = acc_n + 1;
            if (bus_owner == OWN_IMG) acc_img = acc_img + 1;
            if (bus_owner == OWN_WAV) acc_wav = acc_wav + 1;
            if (bus_owner == OWN_SCAN) acc_scan = acc_scan + 1;
        end
        if (arb_sector_done) begin
            if (!acc_v || acc_owner != bus_owner) begin
                own_err = own_err + 1;
                $display("[OWN_ERR] t=%0t done owner=%0d acc_owner=%0d", $time, bus_owner, acc_owner);
            end
            acc_v <= 0;
        end
    end

    // ---------- scaler_hold 伪随机 ----------
    reg [15:0] lfsr = 16'hACE1;
    integer hold_cnt = 0;
    always @(posedge clk) begin
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        if (hold_cnt > 0) hold_cnt = hold_cnt - 1;
        else if (`HOLD_EN && streamer_busy && lfsr[7:0] == 8'h5A) begin
            hold_r <= ~hold_r;
            hold_cnt = hold_r ? 3000 + lfsr[15:4] : 500 + lfsr[11:2];   // 暂停 0.5~4us / 放行 30~70us 量级
        end
    end

    // ---------- 激励 ----------
    integer L, t0, w2, exp_bytes;
    integer t_load [0:4];
    initial begin
        IMG_CLUSTERS = 25;                       // 200扇区（约8.4ms，WAV缓冲只有约4ms）
        #200 rst = 0;
        #1000;
        do_scan;                                 // 开机扫描（WAV未开播）
        wav_go = 1;
        #(6_000_000);                            // 先让WAV稳定播放
        for (L = 0; L < 5; L = L + 1) begin
            exp_bytes = (L == 2) ? 200 * 512 - 77 : 200 * 512;   // 第3次末扇区不满
            f_size = exp_bytes;
            img_bytes = 0;
            in_load = 1;
            @(posedge clk); f_start <= 1; @(posedge clk); f_start <= 0;
            t0 = $time; w2 = 0;
            if (L == 3) begin
                #(2_000_000);
                do_scan;                         // 加载途中重扫（扫描器优先，测试抢占安全）
            end
            while (!f_done) begin
                @(posedge clk); w2 = w2 + 1;
                if (w2 > 6_000_000) begin $display("[HANG] streamer load %0d t=%0t", L, $time); $finish; end
            end
            t_load[L] = $time - t0;
            @(posedge clk);
            in_load = 0;
            if (f_err != 0) begin img_err = img_err + 1; $display("[FS_ERR] load %0d err=%h", L, f_err); end
            if (img_bytes != exp_bytes) begin img_err = img_err + 1; $display("[CNT_ERR] load %0d bytes=%0d exp=%0d", L, img_bytes, exp_bytes); end
            $display("load %0d: %0d us", L, t_load[L] / 1000);
            #(L == 1 ? 1_000_000 : 3_000_000);   // 第2、3次间隔很短，测试WAV缓冲未回满就再加载
        end
        do_scan;                                 // 空闲时重扫
        #(3_000_000);
        $display("==== RESULT ====");
        $display("accepted=%0d img=%0d wav=%0d scan=%0d", acc_n, acc_img, acc_wav, acc_scan);
        $display("img_err=%0d sc_err=%0d sc_bytes=%0d own_err=%0d seq_err=%0d", img_err, sc_err, sc_bytes, own_err, seq_err);
        $display("samples=%0d loops=%0d silent=%0d silent_in_load=%0d", samples, loops, silent, silent_load);
        if (img_err == 0 && sc_err == 0 && sc_bytes == 3 * SCAN_N * 512 && own_err == 0 && seq_err == 0 &&
            silent == 0 && samples > 0)
            $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
