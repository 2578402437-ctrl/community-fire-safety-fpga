`timescale 1ns/1ps
// WAV播放器仿真：播放器 + 真实sd_sector_adapter + 行为级SD卡 + 竞争请求方
// 仲裁逻辑与sd_card_bmp_v2.v一致（IMG优先于WAV，非主人busy=1）
module tb_wav_stream_player;
    localparam [31:0] START = 32'd140000;
    localparam [31:0] TOTAL = 32'd20;
    localparam [31:0] IMG_LBA = 32'd77;

    reg wclk = 0, rclk = 0, rst = 1;
    always #5  wclk = ~wclk;   // 100MHz
    always #20 rclk = ~rclk;   // 25MHz

    // ---------- 行为级SD卡：sd_sec_read电平触发，字节值由LBA决定 ----------
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
                    s = (sd_addr - START) * 256 + k / 2;
                    sd_d  <= (sd_addr == IMG_LBA) ? (k[7:0] ^ 8'h5A) : (k[0] ? s[15:8] : s[7:0]);
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

    // ---------- 竞争者：仿fat32_file_streamer，寄存器式单拍req，看到!busy才发 ----------
    reg img_busy = 0, img_req = 0; reg [1:0] img_st = 0; integer img_ok = 0, img_bad = 0, img_cnt = 0;
    wire img_sbusy, img_valid, img_done;
    always @(posedge wclk) begin
        img_req <= 0;
        case (img_st)
        0: if (img_busy) img_st <= 1;
        1: if (!img_sbusy) begin img_req <= 1; img_st <= 2; img_cnt <= 0; end
        2: begin
            if (img_valid) begin
                if (arb_byte !== (img_cnt[7:0] ^ 8'h5A)) img_bad = img_bad + 1;
                img_cnt <= img_cnt + 1;
            end
            if (img_done) begin img_ok = img_ok + 1; img_busy <= 0; img_st <= 0; end
        end
        endcase
    end

    // ---------- 仲裁（照抄sd_card_bmp_v2，去掉扫描器） ----------
    wire wav_req; wire [31:0] wav_lba; wire wav_end_wr;
    reg bus_committed = 0; reg [1:0] owner = 1;
    wire sel_img = (owner == 1), sel_wav = (owner == 2);
    assign arb_req = sel_img ? img_req : wav_req;
    assign arb_lba = sel_img ? IMG_LBA : wav_lba;
    wire committed_now = bus_committed || arb_req;
    always @(posedge wclk) begin
        if (arb_done) bus_committed <= 0; else if (arb_req) bus_committed <= 1;
        if (!committed_now) begin
            if (img_req || img_busy) owner <= 1; else if (wav_req) owner <= 2;
        end
    end
    assign img_sbusy = sel_img ? arb_busy : 1'b1;
    assign img_valid = sel_img ? arb_valid : 1'b0;
    assign img_done  = sel_img ? arb_done  : 1'b0;

    // 自动循环播放控制（照抄sd_card_bmp_v2）
    reg play_en = 0;
    always @(posedge wclk) if (rst) play_en <= 0;
        else if (!play_en) play_en <= 1; else if (wav_end_wr) play_en <= 0;

    // 加速节拍：每40个rd_clk消费1个样本（仍低于SD写入速度，可覆盖流控路径）
    reg [5:0] tc = 0; wire tick = (tc == 39);
    always @(posedge rclk) tc <= tick ? 0 : tc + 1;

    wire signed [15:0] so; wire sv, act;
    wav_stream_player u_dut (
        .wr_clk(wclk), .wr_rst_n(~rst), .play_enable(play_en), .start_lba(START), .total_sectors(TOTAL),
        .sector_req(wav_req), .sector_lba(wav_lba),
        .sector_busy(sel_wav ? arb_busy : 1'b1), .sector_valid(sel_wav ? arb_valid : 1'b0),
        .sector_byte(arb_byte), .sector_byte_index(arb_idx),
        .sector_done(sel_wav ? arb_done : 1'b0), .sector_error(arb_err), .stream_end_wr(wav_end_wr),
        .rd_clk(rclk), .rd_rst_n(~rst), .sample_tick(tick), .sample_out(so), .sample_valid(sv),
        .sample_ready(1'b1), .sample_counter(), .stream_active(act), .stream_end(), .buffer_low());

    // ---------- 检查：活跃后样本按0,1,2...连续递增，到TOTAL*256回到0 ----------
    integer expect_v = 0, got = 0, err = 0, silent_after = 0, loops = 0;
    reg started = 0;
    always @(posedge rclk) if (sv) begin
        if (!started && so == 0 && act) started <= 1;
        if (started || (act && so == 0)) begin
            if (act && so === expect_v[15:0]) begin
                got = got + 1;
                if (expect_v == TOTAL*256-1) begin expect_v = 0; loops = loops + 1; end
                else expect_v = expect_v + 1;
            end else if (so == 0 && expect_v != 0) silent_after = silent_after + 1;
            else if (so != 0 || expect_v != 0) begin
                err = err + 1;
                if (err < 10) $display("[ERR] t=%0t 期望%0d 实际%0d act=%b", $time, expect_v, so, act);
            end
        end
    end

    // 周期性制造图片读取竞争
    initial begin
        #200; rst = 0;
        repeat (12) begin
            #(300_000);
            @(posedge wclk) img_busy <= 1;
        end
    end

    initial begin
        #(4_500_000);
        $display("==== 结果 ====");
        $display("正确样本数=%0d  完整循环次数=%0d  错误=%0d  中途静音(下溢)=%0d", got, loops, err, silent_after);
        $display("竞争者完成扇区=%0d/12  竞争者字节错误=%0d", img_ok, img_bad);
        if (err == 0 && loops >= 2 && img_ok == 12 && img_bad == 0 && silent_after == 0)
            $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
