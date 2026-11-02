`timescale 1ns/1ps
// 拨码换曲仿真：播放器 + 真实sd_sector_adapter + 行为级SD卡
// 换曲控制逻辑照抄sd_card_bmp_v2.v（sw_stable -> wav_track -> play_enable）
//
// 样本编码：高2位=曲目标签(1/2/3)，低14位=曲目内样本序号，因此0只可能是下溢静音。
// 检查项：
//   1. 所有WAV扇区请求的LBA都落在"当前wav_track"对应区间内
//   2. 输出样本在曲目内连续递增，循环时回到0
//   3. 换曲后新曲目必须从序号0开始，且出现新曲目后不再出现旧曲目样本
//   4. 拨码变化但目标曲目不变（SW1+SW3 -> SW3）时不得重播
//   5. 开播后不允许下溢静音
module tb_wav_track_switch;
    localparam [31:0] BGM_LBA = 32'd1000, BGM_N = 32'd40;
    localparam [31:0] A1_LBA  = 32'd2000, A1_N  = 32'd12;
    localparam [31:0] A2_LBA  = 32'd3000, A2_N  = 32'd12;

    reg wclk = 0, rclk = 0, rst = 1;
    always #5  wclk = ~wclk;   // 100MHz
    always #20 rclk = ~rclk;   // 25MHz

    function [1:0] lba_tag;
        input [31:0] lba;
        lba_tag = (lba >= A2_LBA) ? 2'd3 : (lba >= A1_LBA) ? 2'd2 : 2'd1;
    endfunction
    function [31:0] lba_base;
        input [31:0] lba;
        lba_base = (lba >= A2_LBA) ? A2_LBA : (lba >= A1_LBA) ? A1_LBA : BGM_LBA;
    endfunction

    // ---------- 行为级SD卡 ----------
    wire        sd_rd;
    wire [31:0] sd_addr;
    reg         sd_dv = 0, sd_end = 0;
    reg  [7:0]  sd_d = 0;
    integer     k;
    reg [15:0]  s;
    initial begin
        forever begin
            @(posedge wclk);
            if (sd_rd && !sd_end) begin
                repeat (100) @(posedge wclk);
                for (k = 0; k < 512; k = k + 1) begin
                    repeat (7) @(posedge wclk);
                    s = {lba_tag(sd_addr), 14'd0} | ((sd_addr - lba_base(sd_addr)) * 256 + k / 2);
                    sd_d  <= k[0] ? s[15:8] : s[7:0];
                    sd_dv <= 1; @(posedge wclk); sd_dv <= 0;
                end
                sd_end <= 1; @(posedge wclk); sd_end <= 0;
                @(posedge wclk);
            end
        end
    end

    wire arb_req; wire [31:0] arb_lba;
    wire arb_busy, arb_valid, arb_done; wire [7:0] arb_byte, arb_err; wire [8:0] arb_idx;
    sd_sector_adapter u_ad (.clk(wclk), .rst_n(~rst), .sector_req(arb_req), .sector_lba(arb_lba),
        .sector_busy(arb_busy), .sector_valid(arb_valid), .sector_byte(arb_byte),
        .sector_byte_index(arb_idx), .sector_done(arb_done), .sector_error(arb_err),
        .sd_sec_read(sd_rd), .sd_sec_read_addr(sd_addr), .sd_sec_read_data_valid(sd_dv),
        .sd_sec_read_data(sd_d), .sd_sec_read_end(sd_end));

    // ---------- 换曲控制（照抄sd_card_bmp_v2） ----------
    reg [2:0] sw_stable = 3'd0;
    localparam [1:0] WAV_TRK_BGM = 2'd0, WAV_TRK_ALARM1 = 2'd1, WAV_TRK_ALARM2 = 2'd2;
    wire [1:0] wav_track_req = sw_stable[2]   ? WAV_TRK_ALARM2 :
                               |sw_stable[1:0] ? WAV_TRK_ALARM1 : WAV_TRK_BGM;
    reg  [1:0] wav_track;
    wire [31:0] wav_track_lba   = (wav_track == WAV_TRK_ALARM2) ? A2_LBA :
                                  (wav_track == WAV_TRK_ALARM1) ? A1_LBA : BGM_LBA;
    wire [31:0] wav_track_total = (wav_track == WAV_TRK_ALARM2) ? A2_N :
                                  (wav_track == WAV_TRK_ALARM1) ? A1_N : BGM_N;
    wire [31:0] wav_req_total   = (wav_track_req == WAV_TRK_ALARM2) ? A2_N :
                                  (wav_track_req == WAV_TRK_ALARM1) ? A1_N : BGM_N;
    reg  play_en;
    wire wav_end_wr, wav_idle_wr;
    always @(posedge wclk or posedge rst) begin
        if (rst) begin
            play_en   <= 1'b0;
            wav_track <= WAV_TRK_BGM;
        end else if (!play_en) begin
            if (wav_idle_wr && wav_req_total != 32'd0) begin
                wav_track <= wav_track_req;
                play_en   <= 1'b1;
            end
        end else if (wav_end_wr || wav_track_req != wav_track) begin
            play_en <= 1'b0;
        end
    end

    // 只有WAV一个请求方，直接连适配器
    wire wav_req; wire [31:0] wav_lba;
    assign arb_req = wav_req;
    assign arb_lba = wav_lba;

    reg [5:0] tc = 0; wire tick = (tc == 39);   // 每1.6us消费1个样本
    always @(posedge rclk) tc <= tick ? 0 : tc + 1;

    wire signed [15:0] so; wire sv, act;
    wav_stream_player u_dut (
        .wr_clk(wclk), .wr_rst_n(~rst), .play_enable(play_en),
        .start_lba(wav_track_lba), .total_sectors(wav_track_total),
        .sector_req(wav_req), .sector_lba(wav_lba), .sector_busy(arb_busy), .sector_valid(arb_valid),
        .sector_byte(arb_byte), .sector_byte_index(arb_idx),
        .sector_done(arb_done), .sector_error(arb_err),
        .stream_end_wr(wav_end_wr), .stream_idle_wr(wav_idle_wr),
        .rd_clk(rclk), .rd_rst_n(~rst), .sample_tick(tick), .sample_out(so), .sample_valid(sv),
        .sample_ready(1'b1), .sample_counter(), .stream_active(act), .stream_end(), .buffer_low());

    // ---------- 检查1：请求LBA必须属于当前曲目 ----------
    integer lba_err = 0;
    always @(posedge wclk) if (arb_req && !arb_busy) begin
        if (wav_lba < wav_track_lba || wav_lba >= wav_track_lba + wav_track_total) begin
            lba_err = lba_err + 1;
            $display("[LBA_ERR] t=%0t lba=%0d 当前曲目=%0d", $time, wav_lba, wav_track);
        end
    end

    // ---------- 检查2~5：输出样本序列 ----------
    function [31:0] tag_total;
        input [1:0] t;
        tag_total = (t == 2'd3) ? A2_N : (t == 2'd2) ? A1_N : BGM_N;
    endfunction
    reg  [1:0]  cur_tag = 0;
    reg  [13:0] exp_off = 0;
    integer seq_err = 0, silent = 0, switches = 0;
    integer loops1 = 0, loops2 = 0, loops3 = 0;
    wire [1:0]  tag = so[15:14];
    wire [13:0] off = so[13:0];
    always @(posedge rclk) if (sv) begin
        if (so == 0) begin
            if (cur_tag != 0) silent = silent + 1;            // 开播后不应下溢
        end else if (tag == cur_tag && off == exp_off) begin
            exp_off <= off + 1;
        end else if (tag == cur_tag && off == 0 && exp_off == tag_total(tag) * 256) begin
            exp_off <= 1;                                       // 同曲目循环
            if (tag == 1) loops1 = loops1 + 1;
            if (tag == 2) loops2 = loops2 + 1;
            if (tag == 3) loops3 = loops3 + 1;
        end else if (tag != cur_tag && off == 0) begin
            cur_tag <= tag; exp_off <= 1; switches = switches + 1;
            $display("[SWITCH] t=%0t 曲目%0d -> %0d", $time, cur_tag, tag);
        end else begin
            seq_err = seq_err + 1;
            if (seq_err < 10) $display("[SEQ_ERR] t=%0t 期望曲目%0d序号%0d 实际曲目%0d序号%0d",
                                       $time, cur_tag, exp_off, tag, off);
        end
    end

    // ---------- 激励：模拟拨码 ----------
    integer loops2_before_t3;
    initial begin
        #200; rst = 0;
        #(3_000_000);  sw_stable = 3'b001;   // SW1 -> 报警1
        #(9_000_000);  sw_stable = 3'b101;   // SW1+SW3 -> 报警2（SW3优先）
        #(3_000_000);  sw_stable = 3'b100;   // 只剩SW3：目标仍是报警2，不得重播
        #(8_000_000);  sw_stable = 3'b011;   // SW1+SW2 -> 报警1
        #(3_000_000);  sw_stable = 3'b000;   // 全关 -> 背景音乐
        #(10_000_000);  // 换曲后要先播完缓冲里残留的旧曲目（本仿真加速节拍下约6.5ms）
        $display("==== 结果 ====");
        $display("换曲次数=%0d（期望5：开播+4次切换）  报警1循环=%0d  报警2循环=%0d",
                 switches, loops2, loops3);
        $display("LBA越界=%0d  序列错误=%0d  下溢静音=%0d", lba_err, seq_err, silent);
        if (switches == 5 && loops2 >= 1 && loops3 >= 1 && lba_err == 0 && seq_err == 0 && silent == 0)
            $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
