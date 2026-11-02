`timescale 1ns/1ps
`default_nettype none
// 复现"自动播放每次连续转场两次"：media_player_control + video_fade_transition（真 RTL）
// + sd_card_bmp_v2 的曲目切换/语音间隔逻辑（照抄）+ 按扇区推进的 wav 播放器写侧模型。
// 时间缩放：控制域 10 ns/拍；每帧 100 像素时钟 = 400 控制拍；每扇区 SEC_CLK 拍（约每帧 3 扇区，与实际 60 Hz / 5.33 ms 相同比例）。
// 记录每次 switch_request 的时刻、当前图、栏目段已读扇区；两次请求间隔小于 MIN_GAP_FR 帧判为"连跳"。
module tb_auto_voice;
    localparam FADE_N = 90, HOLD_N = 180;
    localparam integer SEC_CLK = 133;         // 每扇区控制拍数
    localparam integer LOAD_CLK = 40000;      // 一次图片加载约100帧（实际 PIC2 1.4~3.2 s）
    localparam integer MIN_GAP_FR = 300;      // 两次自动切图最少应隔约 5 s
    reg clk = 0, pclk = 0;
    always #5  clk  = ~clk;
    always #20 pclk = ~pclk;
    reg rst = 1;

    reg [5:0] tcnt = 0; reg tick = 0;
    always @(posedge clk) begin tcnt <= (tcnt==49)?0:tcnt+1; tick <= (tcnt==49); end
    reg [6:0] fcnt = 0; reg frame_start = 0;
    always @(posedge pclk) begin fcnt <= (fcnt==99)?0:fcnt+1; frame_start <= (fcnt==99); end
    integer frame_no = 0;
    always @(posedge pclk) if (frame_start) frame_no = frame_no + 1;

    // ---------- 扫描/加载模型（同 l33_no_black 的 tb）----------
    reg scan_found_valid = 0; reg [31:0] scan_found_sector = 0; reg scan_done = 0;
    wire scan_start_pulse;
    integer scnt = 0;
    always @(posedge clk) begin
        scan_found_valid <= 0;
        if (scan_start_pulse) begin scan_done <= 0; scnt = 1; end
        else if (scnt > 0) begin
            scnt = scnt + 1;
            if (scnt == 20) begin scan_found_valid <= 1; scan_found_sector <= 0; end
            if (scnt == 30) begin scan_found_valid <= 1; scan_found_sector <= 1; end
            if (scnt == 40) begin scan_found_valid <= 1; scan_found_sector <= 2; end
            if (scnt == 50) begin scan_found_valid <= 1; scan_found_sector <= 3; end
            if (scnt == 60) begin scan_done <= 1; scnt = 0; end
        end
    end
    wire load_start_pulse; wire [31:0] load_sector;
    reg ready_r = 1, wrfin = 0, loading = 0, wr_en = 0;
    wire bmp_ready = ready_r && !load_start_pulse;
    integer lcnt = 0;
    always @(posedge clk) begin
        wr_en <= 0;
        if (load_start_pulse) begin ready_r <= 0; loading <= 1; lcnt <= 0; end
        else if (loading) begin
            lcnt <= lcnt + 1;
            if (lcnt < LOAD_CLK && lcnt % 16 == 5) wr_en <= 1;
            if (lcnt == LOAD_CLK) ready_r <= 1;
            if (lcnt == LOAD_CLK + 60) begin wrfin <= ~wrfin; loading <= 0; end
        end
    end

    reg cmd_auto = 0;
    wire switch_grant, fade_busy_in, switch_request, disp_commit_toggle, display_valid, select_done;
    wire [1:0] disp_buf_idx, img_idx, mix_buf_idx;
    wire first_committed, auto_play_en;
    reg c1=0,c2=0,c3=0, pa1=0, pa2=0;
    always @(posedge pclk) begin c1<=disp_commit_toggle; c2<=c1; c3<=c2; pa1<=display_valid; pa2<=pa1; end
    wire index_commit = c2 ^ c3;

    wire col_voice_sync_en, col_voice_track_ok, col_voice_gap;
    media_player_control #(.CLK_FREQ_HZ(1000), .AUTO_PLAY_MS(2500), .LOAD_TIMEOUT_MS(2000), .MAX_RETRIES(1)) dut (
        .clk(clk), .rst(rst),
        .cmd_next_image(1'b0), .cmd_prev_image(1'b0), .cmd_toggle_autoplay(cmd_auto),
        .cmd_brightness_enter(1'b0), .cmd_brightness_up(1'b0),
        .tick_1ms(tick), .tick_req(),
        .cmd_select_image(1'b0), .select_index(2'd0), .view_mode(1'b0),
        .sw_sel_valid(1'b0), .sw_sel_idx(2'd0), .sw_hold(), .sw_shown_valid(), .sw_shown_idx(),
        .sw_on_screen(), .nav_target_idx(),
        .bg_valid(1'b0), .intro_commit_req(1'b0),
        .intro_bg_shown(), .intro_pic_ready(), .first_committed(first_committed),
        .scan_found_valid(scan_found_valid), .scan_found_sector(scan_found_sector), .scan_found_total(3'd4),
        .sd_init_done(1'b1), .bmp_ready(bmp_ready), .sdram_ready(1'b1), .scan_done(scan_done),
        .write_finish_toggle(wrfin), .bmp_data_wr_en(wr_en), .bmp_data(24'd0),
        .load_error(1'b0), .bmp_error_code(8'h40),
        .switch_grant(switch_grant), .fade_busy_in(fade_busy_in), .switch_request(switch_request),
        .disp_commit_toggle(disp_commit_toggle), .prev_disp_buf_idx(),
        .mix_buf_idx(mix_buf_idx), .select_done(select_done),
        .voice_sync_en(col_voice_sync_en), .voice_track_ok(col_voice_track_ok), .voice_gap(col_voice_gap),
        .write_buf_idx(), .disp_buf_idx(disp_buf_idx), .img_idx(img_idx),
        .brightness_level(), .brightness_mode(), .volume_level(), .volume_mode(),
        .display_valid(display_valid), .auto_play_en(auto_play_en),
        .scan_start_pulse(scan_start_pulse), .load_start_pulse(load_start_pulse), .load_sector(load_sector),
        .state_code(), .last_error_code(), .image_complete(), .image_count()
    );
    wire mix_active; wire [3:0] shape_kind; wire [8:0] shape_q; wire [7:0] alpha_out, gain;
    video_fade_transition #(.FADE_FRAMES(FADE_N), .HOLD_TIMEOUT_FRAMES(HOLD_N)) fade (
        .ctrl_clk(clk), .ctrl_rst_n(!rst), .next_event_in(switch_request), .next_event_out(switch_grant),
        .fade_busy(fade_busy_in),
        .pix_clk(pclk), .pix_rst_n(!rst), .player_active(pa2), .frame_start(frame_start),
        .index_commit(index_commit), .alpha_out(alpha_out), .gain_alpha_out(gain), .fade_active(),
        .mix_active(mix_active), .shape_kind(shape_kind), .shape_in(), .shape_q(shape_q)
    );

    // ---------- 照抄 sd_card_bmp_v2.v：曲目选择、换曲、语音间隔 ----------
    localparam [31:0] WAV_START_LBA = 32'd148192, WAV_TOTAL_SECTORS = 32'd11381;
    localparam [31:0] WAV_COL0_START_LBA = 32'd165208, WAV_COL0_TOTAL_SECTORS = 32'd8430;
    localparam [31:0] WAV_COL1_START_LBA = 32'd173640, WAV_COL1_TOTAL_SECTORS = 32'd9185;
    localparam [31:0] WAV_COL2_START_LBA = 32'd182832, WAV_COL2_TOTAL_SECTORS = 32'd8672;
    localparam [31:0] WAV_COL3_START_LBA = 32'd191504, WAV_COL3_TOTAL_SECTORS = 32'd9499;
    localparam [31:0] WAV_COL0_VOICE_SAMPLES = 32'd479282, WAV_COL1_VOICE_SAMPLES = 32'd543719;
    localparam [31:0] WAV_COL2_VOICE_SAMPLES = 32'd500006, WAV_COL3_VOICE_SAMPLES = 32'd570497;
    localparam [2:0] WAV_TRK_BGM = 3'd0;
    wire [1:0] mpc_img_idx = img_idx;
    reg  [31:0] col_req_total;
    always @(*) case (mpc_img_idx)
        2'd0: col_req_total = WAV_COL0_TOTAL_SECTORS; 2'd1: col_req_total = WAV_COL1_TOTAL_SECTORS;
        2'd2: col_req_total = WAV_COL2_TOTAL_SECTORS; default: col_req_total = WAV_COL3_TOTAL_SECTORS;
    endcase
    wire [2:0] wav_track_req = (first_committed && col_req_total != 32'd0) ? {1'b1, mpc_img_idx} : WAV_TRK_BGM;
    reg  [2:0] wav_track;
    reg  [31:0] wav_track_lba, wav_track_total, wav_req_total;
    always @(*) begin
        case (wav_track)
            3'd4: begin wav_track_lba = WAV_COL0_START_LBA; wav_track_total = WAV_COL0_TOTAL_SECTORS; end
            3'd5: begin wav_track_lba = WAV_COL1_START_LBA; wav_track_total = WAV_COL1_TOTAL_SECTORS; end
            3'd6: begin wav_track_lba = WAV_COL2_START_LBA; wav_track_total = WAV_COL2_TOTAL_SECTORS; end
            3'd7: begin wav_track_lba = WAV_COL3_START_LBA; wav_track_total = WAV_COL3_TOTAL_SECTORS; end
            default: begin wav_track_lba = WAV_START_LBA; wav_track_total = WAV_TOTAL_SECTORS; end
        endcase
        wav_req_total = (wav_track_req == WAV_TRK_BGM) ? WAV_TOTAL_SECTORS : col_req_total;
    end
    // 播放器写侧模型（状态与 wav_stream_player.v 相同，扇区传输固定 SEC_CLK 拍）
    localparam [2:0] WS_IDLE = 0, WS_REQ = 1, WS_FILL = 2, WS_END = 4;
    reg [2:0] wstate = WS_IDLE; reg [31:0] cur_lba = 0, sectors_read = 0; integer fill_cnt = 0;
    reg wav_play_enable = 0;
    wire wav_stream_end_wr  = (wstate == WS_END);
    wire wav_stream_idle_wr = (wstate == WS_IDLE);
    wire [31:0] wav_sector_lba = cur_lba;
    always @(posedge clk) begin
        if (rst) begin wstate <= WS_IDLE; cur_lba <= 0; end
        else case (wstate)
            WS_IDLE: if (wav_play_enable && wav_track_lba != 0 && wav_track_total != 0) begin
                         cur_lba <= wav_track_lba; sectors_read <= 0; wstate <= WS_REQ; end
            WS_REQ:  if (!wav_play_enable) wstate <= WS_IDLE; else begin wstate <= WS_FILL; fill_cnt <= 0; end
            WS_FILL: begin
                fill_cnt <= fill_cnt + 1;
                if (fill_cnt == SEC_CLK - 2) begin
                    sectors_read <= sectors_read + 1; cur_lba <= cur_lba + 1;
                    if (!wav_play_enable) wstate <= WS_IDLE;
                    else if (sectors_read + 1 >= wav_track_total) wstate <= WS_END;
                    else wstate <= WS_REQ;
                end
            end
            WS_END: if (!wav_play_enable) wstate <= WS_IDLE;
        endcase
    end
    always @(posedge clk) begin
        if (rst) begin wav_play_enable <= 1'b0; wav_track <= WAV_TRK_BGM; end
        else if (!wav_play_enable) begin
            if (wav_stream_idle_wr && wav_req_total != 32'd0) begin wav_track <= wav_track_req; wav_play_enable <= 1'b1; end
        end else if (wav_stream_end_wr || wav_track_req != wav_track) wav_play_enable <= 1'b0;
    end
    localparam integer COL_LEAD_SMP = 72000, COL_GAP_SMP = 240000, COL_SKIP_SMP = 14400, COL_WIN_SMP = 201600;
    function col_gap_hit;
        input [15:0] off_sec; input [31:0] nv;
        integer k; reg [31:0] s_sec;
        begin
            col_gap_hit = 1'b0;
            for (k = 0; k < 3; k = k + 1) begin
                s_sec = (COL_LEAD_SMP + k * (nv + COL_GAP_SMP) + nv + COL_SKIP_SMP) >> 8;
                if (nv != 32'd0 && off_sec >= s_sec[15:0] && off_sec < s_sec[15:0] + (COL_WIN_SMP >> 8))
                    col_gap_hit = 1'b1;
            end
        end
    endfunction
    wire [15:0] wav_off_sec = wav_sector_lba[15:0] - wav_track_lba[15:0];
    // FIXED=1 为带段号校验的写法，0 为无段号校验的写法（用于复现连续转场两次）
    reg col_gap_hit_r = 0; reg [2:0] col_gap_trk_r = 0; reg col_gap_hit_n;
    always @(*) case (wav_track[1:0])
        2'd0: col_gap_hit_n = col_gap_hit(wav_off_sec, WAV_COL0_VOICE_SAMPLES);
        2'd1: col_gap_hit_n = col_gap_hit(wav_off_sec, WAV_COL1_VOICE_SAMPLES);
        2'd2: col_gap_hit_n = col_gap_hit(wav_off_sec, WAV_COL2_VOICE_SAMPLES);
        default: col_gap_hit_n = col_gap_hit(wav_off_sec, WAV_COL3_VOICE_SAMPLES);
    endcase
    always @(posedge clk) begin
        col_gap_hit_r <= `FIXED ? (col_gap_hit_n && !wav_stream_idle_wr) : col_gap_hit_n;
        col_gap_trk_r <= wav_track;
    end
    reg [31:0] col_req_voice;
    always @(*) case (mpc_img_idx)
        2'd0: col_req_voice = WAV_COL0_VOICE_SAMPLES; 2'd1: col_req_voice = WAV_COL1_VOICE_SAMPLES;
        2'd2: col_req_voice = WAV_COL2_VOICE_SAMPLES; default: col_req_voice = WAV_COL3_VOICE_SAMPLES;
    endcase
    assign col_voice_sync_en  = first_committed && col_req_total != 32'd0 && col_req_voice != 32'd0;
    assign col_voice_track_ok = wav_play_enable && !wav_stream_end_wr && wav_track == {1'b1, mpc_img_idx};
    assign col_voice_gap      = col_voice_track_ok && col_gap_hit_r && (`FIXED ? (col_gap_trk_r == wav_track) : 1'b1);

    // ---------- 记录 ----------
    integer n_req = 0, last_req_fr = -100000, n_double = 0;
    always @(posedge clk) begin
        if (switch_request) begin
            n_req = n_req + 1;
            $display("REQ#%0d frame=%0d img=%0d->%0d track=%0d off_sec=%0d gap=%0d seen=%0d (距上次 %0d 帧)%s",
                     n_req, frame_no, img_idx, dut.pending_target_idx, wav_track, wav_off_sec,
                     col_voice_gap, dut.voice_gap_seen, frame_no - last_req_fr,
                     (frame_no - last_req_fr < MIN_GAP_FR) ? "  <== 连跳" : "");
            if (frame_no - last_req_fr < MIN_GAP_FR) n_double = n_double + 1;
            last_req_fr = frame_no;
        end
    end
    reg past_pending = 0, past_seen = 0, past_tok = 0;
    always @(posedge clk) begin
        past_pending <= dut.switch_pending; past_seen <= dut.voice_gap_seen; past_tok <= col_voice_track_ok;
        if (dut.switch_pending && !past_pending)
            $display("  PEND frame=%0d img=%0d target=%0d gap=%0d seen=%0d busy=%0d track=%0d off=%0d",
                     frame_no, img_idx, dut.pending_target_idx, col_voice_gap, dut.voice_gap_seen, fade_busy_in, wav_track, wav_off_sec);
        if (dut.voice_gap_seen != past_seen)
            $display("  SEEN=%0d frame=%0d img=%0d track=%0d off=%0d tok=%0d pend=%0d busy=%0d",
                     dut.voice_gap_seen, frame_no, img_idx, wav_track, wav_off_sec, col_voice_track_ok, dut.switch_pending, fade_busy_in);
        if (col_voice_track_ok != past_tok)
            $display("  TOK=%0d frame=%0d img=%0d track=%0d off=%0d", col_voice_track_ok, frame_no, img_idx, wav_track, wav_off_sec);
    end
    always @(posedge clk) if (switch_grant) $display("  GRANT frame=%0d", frame_no);

    initial begin
        repeat (20) @(posedge pclk); rst = 0;
        wait (display_valid && first_committed);
        repeat (2000) @(posedge clk);
        @(posedge clk); cmd_auto <= 1; @(posedge clk); cmd_auto <= 0;
        repeat (5) @(posedge clk);
        if (!auto_play_en) $display("FAIL 自动播放没打开");
        wait (n_req >= 6 || frame_no > 20000);
        repeat (2000) @(posedge clk);
        $display("自动切图请求 %0d 次，连跳 %0d 次", n_req, n_double);
        $display("%s", (n_req >= 6 && n_double == 0) ? "ALL PASS" : "FAIL");
        $finish;
    end
endmodule
