`timescale 1ns/1ps
// KEY3音量调节仿真：真实RTL = 路由层+守护层+策略层+media_player_control
// 时钟按1MHz折算（1周期=1us）；1ms节拍与sd_card_bmp_v2一致，只在有模块请求时产生。
// 另外穷举检查顶层音量增益：转场包络(0~255) × 音量等级(0~15)。
module tb_key3_volume;
    reg clk = 0, rst = 1;
    always #500 clk = ~clk;              // 1MHz
    reg key1 = 1, key2 = 1, key3 = 1;    // 低有效

    // ---------- 1ms节拍 ----------
    wire rt_req, pol_req, mpc_req;
    reg [9:0] tdiv = 0;
    reg tick_1ms = 0;
    always @(posedge clk) begin
        tdiv     <= (tdiv == 999) ? 10'd0 : tdiv + 1'b1;
        tick_1ms <= (tdiv == 999) && (rt_req || pol_req || mpc_req);
    end

    wire next_e, view_e, prev_e, auto_e, ben_e, badj_e, save_e, k2rel_e, k3rel_e;
    dual_key_chord_router #(.CLK_FREQ_HZ(1_000_000), .LONG_PRESS_MS(500), .DEBOUNCE_MS(20)) u_r (
        .clk(clk), .rst(rst), .key1_in(key1), .key2_in(key2), .key3_in(key3),
        .tick_1ms(tick_1ms), .tick_req(rt_req),
        .next_event(next_e), .view_toggle_event(view_e), .prev_event(prev_e),
        .autoplay_toggle_event(auto_e), .brightness_enter_event(ben_e),
        .brightness_adjust_event(badj_e), .save_config_event(save_e),
        .key2_released_event(k2rel_e), .key3_released_event(k3rel_e));

    wire [3:0] key_state; wire [31:0] lhc; wire save_trig, ksc;
    dual_key_long_hold_guard #(.CLK_FREQ_HZ(1_000_000)) u_g (
        .clk(clk), .rst(rst), .next_event(next_e), .view_toggle_event(view_e), .prev_event(prev_e),
        .autoplay_toggle_event(auto_e), .brightness_enter_event(ben_e), .brightness_adjust_event(badj_e),
        .save_config_event(save_e), .key2_released_event(k2rel_e), .key3_released_event(k3rel_e),
        .key_state(key_state), .long_hold_cnt(lhc), .save_triggered(save_trig), .key_state_changed(ksc));

    wire brightness_mode, volume_mode;
    wire [3:0] brightness_level, volume_level;
    wire c_next, c_prev, c_auto, c_ben, c_up, c_down, c_save, c_view, c_fn, c_fp, c_fc;
    media_policy #(.BRIGHTNESS_ADJUST_MS(500)) u_p (
        .clk(clk), .rst(rst), .key_state(key_state), .long_hold_cnt(lhc), .save_triggered(save_trig),
        .key_state_changed(ksc), .scan_done(1'b1), .display_valid(1'b1),
        .brightness_mode(brightness_mode | volume_mode),          // 与sd_card_bmp_v2接法一致
        .view_mode(1'b0), .tick_1ms(tick_1ms), .tick_req(pol_req),
        .cmd_next_image(c_next), .cmd_prev_image(c_prev), .cmd_toggle_autoplay(c_auto),
        .cmd_brightness_enter(c_ben), .cmd_brightness_up(c_up), .cmd_brightness_down(c_down),
        .cmd_save_config(c_save), .cmd_toggle_view(c_view), .cmd_focus_next(c_fn),
        .cmd_focus_prev(c_fp), .cmd_focus_confirm(c_fc));

    // 媒体控制：scan_done=1、未找到图片、bmp_ready=0 → 不发起扫描/加载，直接进入命令处理分支
    wire [3:0] state_code;
    media_player_control #(.CLK_FREQ_HZ(1_000_000)) u_m (
        .clk(clk), .rst(rst),
        .cmd_next_image(c_next), .cmd_prev_image(c_prev), .cmd_toggle_autoplay(c_auto),
        .cmd_brightness_enter(c_ben), .cmd_brightness_up(c_up), .cmd_brightness_down(c_down),
        .cmd_save_config(c_save), .tick_1ms(tick_1ms), .tick_req(mpc_req),
        .cmd_select_image(1'b0), .select_index(2'd0), .view_mode(1'b0),
        .sw_sel_valid(1'b0), .sw_sel_idx(2'd0), .sw_hold(), .sw_shown_valid(), .sw_shown_idx(),
        .nav_target_idx(),
        .scan_found_valid(1'b0), .scan_found_sector(32'd0), .scan_found_total(3'd0),
        .sd_init_done(1'b1), .bmp_ready(1'b0), .sdram_ready(1'b1), .scan_done(1'b1),
        .write_finish_toggle(1'b0), .bmp_data_wr_en(1'b0), .bmp_data(24'd0),
        .load_error(1'b0), .bmp_error_code(8'd0),
        .switch_grant(1'b0), .fade_busy_in(1'b0), .switch_request(), .disp_commit_toggle(),
        .prev_disp_buf_idx(),
        .write_buf_idx(), .disp_buf_idx(), .img_idx(),
        .brightness_level(brightness_level), .brightness_mode(brightness_mode),
        .volume_level(volume_level), .volume_mode(volume_mode),
        .display_valid(), .auto_play_en(),
        .scan_start_pulse(), .load_start_pulse(), .load_sector(),
        .state_code(state_code), .last_error_code(), .image_complete(), .image_count());

    always @(posedge clk) begin
        if (c_up && brightness_mode) $display("[%t] 亮度+1 -> %0d", $realtime, brightness_level + 4'd1);
        if (c_up && volume_mode)     $display("[%t] 音量+1 -> %0d", $realtime, volume_level + 4'd1);
    end

    integer errs = 0;
    integer amb = 0;     // 两种模式同时为1的周期数（应为0）
    always @(posedge clk) if (brightness_mode && volume_mode) amb = amb + 1;

    task press(input integer ms); begin key3 = 0; #(ms*1_000_000); key3 = 1; end endtask
    task wait_ms(input integer ms); #(ms*1_000_000); endtask
    task check(input cond, input string msg); begin
        if (!cond) begin errs = errs + 1; $display("FAIL: %0s  (bm=%0d bl=%0d vm=%0d vl=%0d seg=%h)",
                     msg, brightness_mode, brightness_level, volume_mode, volume_level, state_code); end
        else $display("PASS: %0s", msg);
    end endtask

    // ---------- 顶层音量增益：与top_tf_hdmi_audio_v2同一张表、同一表达式，穷举 ----------
    function [8:0] vol_gain_f; input [3:0] l; begin
        case (l)
            4'd0:  vol_gain_f = 9'd3;   4'd1:  vol_gain_f = 9'd5;   4'd2:  vol_gain_f = 9'd6;
            4'd3:  vol_gain_f = 9'd8;   4'd4:  vol_gain_f = 9'd11;  4'd5:  vol_gain_f = 9'd14;
            4'd6:  vol_gain_f = 9'd19;  4'd7:  vol_gain_f = 9'd26;  4'd8:  vol_gain_f = 9'd34;
            4'd9:  vol_gain_f = 9'd46;  4'd10: vol_gain_f = 9'd61;  4'd11: vol_gain_f = 9'd81;
            4'd12: vol_gain_f = 9'd108; 4'd13: vol_gain_f = 9'd144; 4'd14: vol_gain_f = 9'd192;
            default: vol_gain_f = 9'd256;
        endcase
    end endfunction
    reg [7:0] fa; reg [16:0] p17; integer i, j, gerr, mono_err;
    real db;
    reg signed [15:0] smp; reg signed [24:0] old_out, new_out; integer serr;
    initial begin
        gerr = 0; mono_err = 0; serr = 0;
        for (i = 0; i < 16; i = i + 1) begin
            // 表值与公式 round(256*10^(-2.5*(15-L)/20)) 一致
            if (vol_gain_f(i) != $rtoi(256.0 * (10.0 ** (-2.5 * (15 - i) / 20.0)) + 0.5)) gerr = gerr + 1;
            if (i > 0 && vol_gain_f(i) <= vol_gain_f(i-1)) mono_err = mono_err + 1;   // 严格单调
            for (j = 0; j < 256; j = j + 1) begin
                fa  = j;
                p17 = fa * vol_gain_f(i);
                if (p17[16]) gerr = gerr + 1;                                // 溢出
                if (i == 15 && p17[15:8] != fa) gerr = gerr + 1;             // 等级15逐位旁路
            end
        end
        // 等级15时样本输出与参考实现逐位一致（随机样本×全部包络）
        for (j = 0; j < 256; j = j + 1) for (i = 0; i < 64; i = i + 1) begin
            smp = $random;
            old_out = smp * $signed({1'b0, j[7:0]});
            p17 = j[7:0] * vol_gain_f(15);
            new_out = smp * $signed({1'b0, p17[15:8]});
            if ((old_out >>> 1) !== (new_out >>> 1)) serr = serr + 1;
        end
        for (i = 0; i < 16; i = i + 1) begin
            db = 20.0 * $log10(vol_gain_f(i) / 256.0);
            $display("音量等级%2d 系数%3d  %6.2f dB", i, vol_gain_f(i), db);
        end
        $display("增益穷举 4096 组：错误 %0d，单调错误 %0d；等级15样本对照 16384 组错误 %0d", gerr, mono_err, serr);
    end

    initial begin
        $timeformat(-3, 0, " ms", 8);
        #5000 rst = 0;
        wait_ms(50);
        check(!brightness_mode && !volume_mode && volume_level == 15, "上电：正常模式，音量15");
        // 1) 正常模式长按：亮度、音量都不变
        press(1200); wait_ms(100);
        check(brightness_level == 15 && volume_level == 15, "正常模式长按不调节");
        // 2) 第1次短按 → 亮度模式；长按1.1s亮度+1回绕到0，音量不动
        press(100); wait_ms(100);
        check(brightness_mode && !volume_mode, "短按1次进入亮度模式");
        check(state_code == brightness_level, "亮度模式数码管显示亮度等级");
        press(1100); wait_ms(50);
        check(brightness_level == 0 && volume_level == 15, "亮度模式长按只调亮度");
        // 3) 第2次短按 → 音量模式；长按2.2s音量+3：15→0→1→2
        press(100); wait_ms(100);
        check(!brightness_mode && volume_mode, "短按2次进入音量模式");
        press(2200); wait_ms(50);
        check(volume_level == 2 && brightness_level == 0, "音量模式长按2.2s升3级含回绕");
        check(state_code == 4'd2, "音量模式数码管显示音量等级");
        // 4) 松手保持2s不变
        wait_ms(2000);
        check(volume_level == 2 && key_state == 4'd0, "松手后音量保持、状态回IDLE");
        // 5) 第3次短按 → 正常模式；长按不调节
        press(100); wait_ms(100);
        check(!brightness_mode && !volume_mode, "短按3次回到正常模式");
        press(1500); wait_ms(100);
        check(brightness_level == 0 && volume_level == 2, "回到正常模式后长按不调节");
        // 6) 再走一圈：亮度→音量→正常
        press(100); wait_ms(100);
        check(brightness_mode && !volume_mode, "第二圈：亮度模式");
        press(100); wait_ms(100);
        check(!brightness_mode && volume_mode, "第二圈：音量模式");
        press(1100); wait_ms(50);
        check(volume_level == 3, "音量模式长按1.1s升1级");
        press(100); wait_ms(100);
        check(!brightness_mode && !volume_mode, "第二圈：回到正常");
        check(amb == 0, "亮度与音量模式从不同时为1");
        check(gerr == 0 && mono_err == 0 && serr == 0, "音量增益穷举/单调/等级15旁路");
        if (errs == 0) $display("==== ALL PASS ===="); else $display("==== %0d FAIL ====", errs);
        $finish;
    end
endmodule
