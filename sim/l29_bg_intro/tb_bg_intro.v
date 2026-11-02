`timescale 1ns/1ps
`default_nettype none
// 仿真：开机背景 BG.BMP + 开机动画放行提交 PIC1
// media_player_control + video_fade_transition + fireman_intro_24 联合，小帧（每帧100像素时钟）只验控制流程。
// G 有BG：BG→bank1显示，PIC1加载后不提交，开机动画到位放行，bank切到0；期间按键无效、不翻转提交、bank0不提前露出；之后切图正常
// H BG加载失败（内容错误，重试后放弃）→ 原流程：PIC1直接提交，开机动画按 boot_done 走
// I 卡上无BG → 原流程
// J 有BG但开机时 enable=0（硬切/缩略图）→ 开机动画直接结束，PIC1一就绪立即提交
module tb_bg_intro;
    localparam FADE_N = 4, HOLD_N = 12, STAND = 4, WALK = 32, GUARD = 4;
    reg clk = 0, pclk = 0;
    always #5  clk  = ~clk;    // 控制域
    always #20 pclk = ~pclk;   // 像素域
    reg rst = 1;

    reg [5:0] tcnt = 0; reg tick = 0;
    always @(posedge clk) begin tcnt <= (tcnt==49)?0:tcnt+1; tick <= (tcnt==49); end
    // 小帧：0~4 场同步，10~89 有效
    reg [6:0] fcnt = 0; reg frame_start = 0;
    always @(posedge pclk) begin fcnt <= (fcnt==99)?0:fcnt+1; frame_start <= (fcnt==99); end
    wire vs = (fcnt < 5);
    wire de = (fcnt >= 10 && fcnt < 90);

    // 扫描模型：两张图（句柄0、1）
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
            if (scnt == 40) begin scan_done <= 1; scnt = 0; end
        end
    end

    // 加载模型：每次加载200拍送完，再60拍写完；bg_fail=1 时 BG 句柄内容错误
    reg bg_valid = 1, bg_fail = 0, enable = 1;
    wire load_start_pulse; wire [31:0] load_sector;
    wire load_busy = dut.load_busy;
    reg ready_r = 1, load_error = 0, wrfin = 0, loading = 0, wr_en = 0;
    wire bmp_ready = ready_r && !load_start_pulse;
    reg [11:0] lcnt = 0;
    integer n_loads = 0, n_bg_loads = 0;
    always @(posedge clk) begin
        wr_en <= 0;
        if (load_start_pulse) begin ready_r <= 0; loading <= 1; lcnt <= 0; n_loads = n_loads + 1; end
        else if (loading) begin
            lcnt <= lcnt + 1;
            if (lcnt < 200 && lcnt[3:0] == 4'd5) wr_en <= 1;
            if (lcnt == 200) ready_r <= 1;
            if (lcnt == 260) begin
                load_error <= bg_fail && load_sector[3];
                wrfin <= ~wrfin; loading <= 0;
            end
        end
    end
    always @(posedge clk) if (load_start_pulse && load_sector[3]) n_bg_loads = n_bg_loads + 1;

    reg cmd_next = 0;
    wire switch_grant, fade_busy_in, switch_request, disp_commit_toggle, display_valid;
    wire [1:0] disp_buf_idx, img_idx, prev_disp_buf_idx;
    wire bg_shown, pic_ready, first_committed, commit_req;

    // 跨域（与顶层/sd_card_bmp_v2一致：两级打拍）
    reg c1=0,c2=0,c3=0, pa1=0, pa2=0;
    reg [1:0] bg_s=0, rdy_s=0, fc_s=0, req_s=0;
    always @(posedge pclk) begin
        c1<=disp_commit_toggle; c2<=c1; c3<=c2; pa1<=display_valid; pa2<=pa1;
        bg_s <= {bg_s[0], bg_shown}; rdy_s <= {rdy_s[0], pic_ready}; fc_s <= {fc_s[0], first_committed};
    end
    always @(posedge clk) req_s <= {req_s[0], commit_req};
    wire index_commit = c2 ^ c3;

    media_player_control #(.CLK_FREQ_HZ(1000), .AUTO_PLAY_MS(100000), .LOAD_TIMEOUT_MS(20), .MAX_RETRIES(1)) dut (
        .clk(clk), .rst(rst),
        .cmd_next_image(cmd_next), .cmd_prev_image(1'b0), .cmd_toggle_autoplay(1'b0),
        .cmd_brightness_enter(1'b0), .cmd_brightness_up(1'b0), .cmd_brightness_down(1'b0), .cmd_save_config(1'b0),
        .tick_1ms(tick), .tick_req(),
        .cmd_select_image(1'b0), .select_index(2'd0), .view_mode(1'b0),
        .sw_sel_valid(1'b0), .sw_sel_idx(2'd0), .sw_hold(), .sw_shown_valid(), .sw_shown_idx(), .nav_target_idx(),
        .bg_valid(bg_valid), .intro_commit_req(req_s[1]),
        .intro_bg_shown(bg_shown), .intro_pic_ready(pic_ready), .first_committed(first_committed),
        .scan_found_valid(scan_found_valid), .scan_found_sector(scan_found_sector), .scan_found_total(3'd2),
        .sd_init_done(1'b1), .bmp_ready(bmp_ready), .sdram_ready(1'b1), .scan_done(scan_done),
        .write_finish_toggle(wrfin), .bmp_data_wr_en(wr_en), .bmp_data(24'd0),
        .load_error(load_error), .bmp_error_code(8'h40),
        .switch_grant(switch_grant), .fade_busy_in(fade_busy_in), .switch_request(switch_request),
        .disp_commit_toggle(disp_commit_toggle), .prev_disp_buf_idx(prev_disp_buf_idx),
        .write_buf_idx(), .disp_buf_idx(disp_buf_idx), .img_idx(img_idx),
        .brightness_level(), .brightness_mode(), .volume_level(), .volume_mode(),
        .display_valid(display_valid), .auto_play_en(),
        .scan_start_pulse(scan_start_pulse), .load_start_pulse(load_start_pulse), .load_sector(load_sector),
        .state_code(), .last_error_code(), .image_complete(), .image_count()
    );
    wire [1:0] fstate = fade.g_fade.state;
    video_fade_transition #(.FADE_FRAMES(FADE_N), .HOLD_TIMEOUT_FRAMES(HOLD_N)) fade (
        .ctrl_clk(clk), .ctrl_rst_n(!rst), .next_event_in(switch_request), .next_event_out(switch_grant),
        .fade_busy(fade_busy_in),
        .pix_clk(pclk), .pix_rst_n(!rst), .player_active(pa2), .frame_start(frame_start),
        .index_commit(index_commit), .alpha_out(), .gain_alpha_out(), .fade_active(),
        .shape_kind(), .shape_in(), .shape_q()
    );
    wire intro_active;
    fireman_intro_24 #(.ROM_FILE("../../src/user_source/hdl_source/rom/intro_sticker_5bit.hex"),
                       .STAND_N(STAND), .WALK_N(WALK), .ARRIVE_N(4), .BG_GUARD_N(GUARD)) intro (
        .clk(pclk), .rst_n(!rst), .vsync(vs), .de(de), .rgb_in(24'h123456), .enable(enable),
        .boot_done(fc_s[1]), .bg_shown(bg_s[1]), .pic_ready(rdy_s[1]),
        .rgb_out(), .intro_active(intro_active), .commit_req(commit_req), .step_pulse(), .step_side()
    );
    wire [1:0] ist = intro.st;

    // ---------- 监视 ----------
    integer errs = 0;
    integer n_req = 0, n_tgl = 0, bad_bank = 0, bad_commit = 0;
    reg tgl_q = 0, fc_q = 0, bg_seen = 0;
    always @(posedge clk) begin
        tgl_q <= disp_commit_toggle; fc_q <= first_committed;
        if (rst) begin n_req = 0; n_tgl = 0; bad_bank = 0; bad_commit = 0; bg_seen <= 0; end
        else begin
            if (switch_request && !first_committed) n_req = n_req + 1;          // 首图提交前不应发起转场
            if (disp_commit_toggle != tgl_q && !fc_q) n_tgl = n_tgl + 1;        // 首图提交不应翻转
            if (bg_shown) bg_seen <= 1;
            // 有BG时：首图提交前显示的只能是BG bank1
            if (bg_seen && display_valid && !first_committed && disp_buf_idx != 2'd1) bad_bank = bad_bank + 1;
            // 有BG时：首图提交那一拍开机动画必须已到位或已结束
            if (bg_seen && first_committed && !fc_q && !req_s[1]) bad_commit = bad_commit + 1;
        end
    end
    // 开机动画结束时距首图提交（像素域看到）的帧数
    integer f_after = -1;
    always @(posedge pclk) begin
        if (rst) f_after = -1;
        else if (frame_start) begin
            if (fc_s[1] && f_after < 0) f_after = 0;
            else if (f_after >= 0 && intro_active) f_after = f_after + 1;
        end
    end

    task press; begin @(posedge clk); cmd_next <= 1; @(posedge clk); cmd_next <= 0; end endtask
    task fail(input [8*40-1:0] msg); begin errs = errs + 1; $display("FAIL %0s t=%0t", msg, $time); end endtask
    task do_reset; begin
        rst = 1; repeat (20) @(posedge pclk); rst = 0;
    end endtask
    task wait_intro_done(input integer maxf); integer k; begin
        for (k = 0; k < maxf*100 && intro_active; k = k + 1) @(posedge pclk);
        repeat (300) @(posedge clk);
    end endtask
    task check_boot(input [8*24-1:0] name, input integer exp_bg_loads, input integer exp_guard); begin
        if (intro_active) fail({name, " intro not done"});
        if (!first_committed || disp_buf_idx != 0 || img_idx != 0 || !display_valid) fail({name, " PIC1 not committed"});
        if (n_bg_loads != exp_bg_loads) begin fail({name, " bg loads"}); $display("  n_bg_loads=%0d", n_bg_loads); end
        if (n_req) fail({name, " switch_request before commit"});
        if (n_tgl) fail({name, " commit toggled on boot"});
        if (bad_bank) fail({name, " bank0 shown before commit"});
        if (bad_commit) fail({name, " committed before intro arrive"});
        // 统计用的帧边界与模块内的场同步下降沿相差几拍，允许 GUARD-1~GUARD
        if (exp_guard >= 0 && (f_after < exp_guard - 1 || f_after > exp_guard)) begin fail({name, " guard frames"}); $display("  f_after=%0d", f_after); end
        if (fstate != 0) fail({name, " fade not idle"});
        $display("%0s : loads=%0d bg_loads=%0d disp=%0d f_after=%0d t=%0t", name, n_loads, n_bg_loads, disp_buf_idx, f_after, $time);
    end endtask

    integer k;
    initial begin
        // ---------- G 有BG ----------
        bg_valid = 1; bg_fail = 0; enable = 1; n_loads = 0; n_bg_loads = 0;
        do_reset;
        wait (bg_shown);
        if (disp_buf_idx != 1 || !display_valid) fail("G bg not shown on bank1");
        $display("G bg shown bank=%0d t=%0t", disp_buf_idx, $time);
        press;                                   // 开机期间按键应被忽略
        wait (pic_ready);
        if (first_committed || disp_buf_idx != 1) fail("G PIC1 committed too early");
        if (ist != 0) fail("G intro should still stand when pic_ready rises");
        $display("G pic_ready, intro st=%0d t=%0t", ist, $time);
        press;
        wait (first_committed);
        $display("G committed, intro st=%0d t=%0t", ist, $time);
        wait_intro_done(200);
        check_boot("G with-bg", 1, GUARD);
        // 之后正常切图 0→1（bank1 原为BG，需重新加载PIC2）
        n_loads = 0; press;
        for (k = 0; k < 40*100 && !(fstate == 0 && !load_busy && disp_buf_idx == 1); k = k + 1) @(posedge pclk);
        repeat (300) @(posedge clk);
        if (disp_buf_idx != 1 || img_idx != 1 || n_loads != 1 || dut.image_complete != 4'b0011)
            fail("G2 switch after boot");
        $display("G2 next: disp=%0d img=%0d loads=%0d complete=%b", disp_buf_idx, img_idx, n_loads, dut.image_complete);

        // ---------- H BG加载失败 ----------
        bg_valid = 1; bg_fail = 1; enable = 1; n_loads = 0; n_bg_loads = 0;
        do_reset;
        wait (first_committed);
        if (bg_shown || pic_ready) fail("H bg flags should stay 0");
        wait_intro_done(200);
        check_boot("H bg-fail", 2, -1);          // BG 加载1次+重试1次
        if (n_loads != 3) begin fail("H loads"); $display("  n_loads=%0d", n_loads); end

        // ---------- I 无BG ----------
        bg_valid = 0; bg_fail = 0; enable = 1; n_loads = 0; n_bg_loads = 0;
        do_reset;
        wait (first_committed);
        if (ist != 0) fail("I PIC1 should commit while intro stands (old flow)");
        wait_intro_done(200);
        check_boot("I no-bg", 0, -1);
        if (n_loads != 1) fail("I loads");

        // ---------- J 有BG、开机即 enable=0 ----------
        bg_valid = 1; bg_fail = 0; enable = 0; n_loads = 0; n_bg_loads = 0;
        do_reset;
        wait (first_committed);
        wait_intro_done(200);
        check_boot("J bg-disabled", 1, -1);
        if (bg_shown || pic_ready) fail("J flags not cleared");

        if (errs == 0) $display("ALL PASS"); else $display("%0d FAILED", errs);
        $finish;
    end
    initial begin #50_000_000; $display("GLOBAL TIMEOUT"); $finish; end
endmodule
