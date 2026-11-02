`timescale 1ns/1ps

// 按键交互链仿真：dual_key_chord_router → dual_key_long_hold_guard → media_policy → thumbnail_controller
// CLK_FREQ_HZ缩小到1MHz（1ms=1000拍）加快仿真；按键低有效。
module tb_thumb_ctrl;
    reg clk = 0, rst = 1;
    always #500 clk = ~clk;   // 1MHz
    reg key1 = 1, key2 = 1, key3 = 1;

    wire next_ev, view_ev, prev_ev, auto_ev, br_en, br_adj, save_ev, k2_rel;
    dual_key_chord_router #(.CLK_FREQ_HZ(1_000_000)) u_r (.clk(clk), .rst(rst),
        .key1_in(key1), .key2_in(key2), .key3_in(key3), .next_event(next_ev), .view_toggle_event(view_ev),
        .prev_event(prev_ev), .autoplay_toggle_event(auto_ev), .brightness_enter_event(br_en),
        .brightness_adjust_event(br_adj), .save_config_event(save_ev), .key2_released_event(k2_rel));

    wire [3:0] ks; wire [31:0] lhc; wire save_trig, ks_chg;
    dual_key_long_hold_guard #(.CLK_FREQ_HZ(1_000_000)) u_g (.clk(clk), .rst(rst),
        .next_event(next_ev), .view_toggle_event(view_ev), .prev_event(prev_ev), .autoplay_toggle_event(auto_ev),
        .brightness_enter_event(br_en), .brightness_adjust_event(br_adj), .save_config_event(save_ev),
        .key2_released_event(k2_rel), .key_state(ks), .long_hold_cnt(lhc), .save_triggered(save_trig),
        .key_state_changed(ks_chg));

    wire view_mode;
    wire c_next, c_prev, c_auto, c_ben, c_bup, c_bdn, c_save, c_view, c_fn, c_fp, c_fc;
    media_policy u_p (.clk(clk), .rst(rst), .key_state(ks), .long_hold_cnt(lhc), .save_triggered(save_trig),
        .key_state_changed(ks_chg), .scan_done(1'b1), .display_valid(1'b1), .brightness_mode(1'b0),
        .view_mode(view_mode), .cmd_next_image(c_next), .cmd_prev_image(c_prev), .cmd_toggle_autoplay(c_auto),
        .cmd_brightness_enter(c_ben), .cmd_brightness_up(c_bup), .cmd_brightness_down(c_bdn),
        .cmd_save_config(c_save), .cmd_toggle_view(c_view), .cmd_focus_next(c_fn), .cmd_focus_prev(c_fp),
        .cmd_focus_confirm(c_fc));

    reg switch_grant = 0;
    wire [1:0] focus, sel_idx; wire sel_req;
    thumbnail_controller u_tc (.clk(clk), .rst(rst), .key_right(c_fn), .key_left(c_fp), .key_confirm(c_fc),
        .key_mode(c_view), .display_ready(1'b1), .image_count(3'd4), .current_index(2'd1),
        .switch_grant(switch_grant), .fade_busy(1'b0), .view_mode(view_mode), .focus_index(focus),
        .select_req(sel_req), .select_index(sel_idx));

    // 命令计数
    integer n_next = 0, n_prev = 0, n_auto = 0, n_sel = 0; reg [1:0] last_sel;
    always @(posedge clk) begin
        if (c_next) n_next = n_next + 1;
        if (c_prev) n_prev = n_prev + 1;
        if (c_auto) n_auto = n_auto + 1;
        if (sel_req) begin n_sel = n_sel + 1; last_sel = sel_idx; end
    end

    integer errors = 0;
    task press1(input integer ms); begin key1 = 0; #(ms * 1_000_000); key1 = 1; #(60_000_000); end endtask
    task press2(input integer ms); begin key2 = 0; #(ms * 1_000_000); key2 = 1; #(60_000_000); end endtask
    task check(input cond, input [8*48-1:0] msg); begin
        if (cond) $display("  通过：%0s", msg); else begin $display("  失败：%0s", msg); errors = errors + 1; end
    end endtask

    initial begin
        #5000 rst = 0; #1_000_000;
        $display("1) 全屏KEY1短按 → 下一张");
        press1(100);
        check(n_next == 1 && view_mode == 0, "cmd_next_image=1次，仍是全屏");
        $display("2) KEY1长按 → 进缩略图，焦点=当前图1，松开不产生下一张");
        press1(800);
        check(view_mode == 1 && focus == 1 && n_next == 1, "view_mode=1 focus=1 n_next仍为1");
        $display("3) 缩略图KEY1短按×3 → 焦点1→2→3→0(循环)");
        press1(100); check(focus == 2, "focus=2");
        press1(100); check(focus == 3, "focus=3");
        press1(100); check(focus == 0 && n_next == 1, "focus=0 且未产生下一张");
        $display("4) 缩略图KEY2长按 → 焦点左移0→3，不产生上一张");
        press2(800); check(focus == 3 && n_prev == 0, "focus=3 n_prev=0");
        $display("5) 缩略图KEY2短按 → 确认选中图3，等switch_grant再回全屏");
        press2(100);
        check(n_sel == 1 && last_sel == 3 && view_mode == 1 && n_auto == 0, "select_req→3，未切自动轮播，仍在缩略图");
        @(posedge clk) switch_grant = 1; @(posedge clk) switch_grant = 0; @(posedge clk);
        check(view_mode == 0, "switch_grant后回到全屏");
        $display("6) 进缩略图后焦点在当前图上直接确认 → 立即回全屏，不发选择请求");
        press1(800); check(view_mode == 1 && focus == 1, "进入缩略图 focus=1");
        press2(100); check(view_mode == 0 && n_sel == 1, "直接回全屏 n_sel仍为1");
        $display("7) 全屏下KEY2短按/长按功能不变");
        press2(100); check(n_auto == 1, "自动轮播切换1次");
        press2(800); check(n_prev == 1, "上一张1次");
        $display("8) 缩略图中KEY1长按 → 不切换图片直接回全屏");
        press1(800); press1(800); check(view_mode == 0 && n_sel == 1, "返回全屏");
        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d)", errors);
        $finish;
    end
endmodule
