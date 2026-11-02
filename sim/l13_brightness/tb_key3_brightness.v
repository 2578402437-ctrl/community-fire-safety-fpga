`timescale 1ns/1ps
// KEY3亮度调节仿真：真实RTL = 路由层+守护层+策略层；时钟按1MHz折算（1周期=1us）
// 亮度等级更新、alpha折叠与media_player_control/顶层改动使用同一表达式
module tb_key3_brightness;
    reg clk = 0, rst = 1;
    always #500 clk = ~clk;              // 1MHz
    reg key1 = 1, key2 = 1, key3 = 1;    // 低有效

    wire next_e, view_e, prev_e, auto_e, ben_e, badj_e, save_e, k2rel_e, k3rel_e;
    dual_key_chord_router #(.CLK_FREQ_HZ(1_000_000), .LONG_PRESS_MS(500), .DEBOUNCE_MS(20)) u_r (
        .clk(clk), .rst(rst), .key1_in(key1), .key2_in(key2), .key3_in(key3),
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

    reg  brightness_mode = 0;
    reg  [3:0] brightness_level = 4'd15;
    wire c_next, c_prev, c_auto, c_ben, c_up, c_down, c_save, c_view, c_fn, c_fp, c_fc;
    media_policy #(.BRIGHTNESS_ADJUST_INTERVAL(32'd500_000)) u_p (   // 500ms@1MHz
        .clk(clk), .rst(rst), .key_state(key_state), .long_hold_cnt(lhc), .save_triggered(save_trig),
        .key_state_changed(ksc), .scan_done(1'b1), .display_valid(1'b1), .brightness_mode(brightness_mode),
        .view_mode(1'b0), .cmd_next_image(c_next), .cmd_prev_image(c_prev), .cmd_toggle_autoplay(c_auto),
        .cmd_brightness_enter(c_ben), .cmd_brightness_up(c_up), .cmd_brightness_down(c_down),
        .cmd_save_config(c_save), .cmd_toggle_view(c_view), .cmd_focus_next(c_fn),
        .cmd_focus_prev(c_fp), .cmd_focus_confirm(c_fc));

    // 与media_player_control改动一致
    integer up_cnt = 0; time last_up = 0;
    always @(posedge clk) begin
        if (c_ben) brightness_mode <= ~brightness_mode;
        if (c_up && brightness_mode) begin
            brightness_level <= brightness_level + 4'd1;
            up_cnt = up_cnt + 1;
            $display("[%0t ms] 亮度+1 -> %0d（距上次 %0t ms）", $time/1_000_000, brightness_level + 4'd1, ($time-last_up)/1_000_000);
            last_up = $time;
        end
    end

    integer errs = 0;
    task press(input integer ms); begin key3 = 0; #(ms*1_000_000); key3 = 1; end endtask
    task wait_ms(input integer ms); #(ms*1_000_000); endtask
    task check(input cond, input [8*48-1:0] msg); begin
        if (!cond) begin errs = errs + 1; $display("FAIL: %0s", msg); end
        else $display("PASS: %0s", msg);
    end endtask

    // alpha折叠：与顶层改动同一表达式，穷举检查
    reg [3:0] lv; reg [7:0] fa; reg [8:0] gain; reg [16:0] e17; integer i, j, aerr;
    initial begin
        aerr = 0;
        for (i = 0; i < 16; i = i + 1) for (j = 0; j < 256; j = j + 1) begin
            lv = i; fa = j;
            gain = {1'b0, lv, 4'b0000} + 9'd16;
            e17  = fa * gain;
            if (e17[16]) aerr = aerr + 1;                                     // 溢出
            if (i == 15 && e17[15:8] != fa) aerr = aerr + 1;                  // 等级15必须逐位旁路
            if (e17[15:8] != (j * (i + 1) * 16) / 256) aerr = aerr + 1;       // 与理论值一致
        end
        $display("alpha折叠穷举 4096 组，错误 %0d；等级0/7/15 稳态alpha=%0d/%0d/%0d",
                 aerr, (255*16)>>8, (255*128)>>8, (255*256)>>8);
    end

    initial begin
        #5000 rst = 0;
        wait_ms(50);
        // 1) 非亮度模式下长按：不应调节
        press(1200); wait_ms(100);
        check(brightness_level == 15 && up_cnt == 0, "非亮度模式长按不调节");
        // 2) 短按进入亮度模式
        press(100); wait_ms(100);
        check(brightness_mode == 1, "短按进入亮度模式");
        // 3) 长按2.2s：0.5s判长按，之后每500ms+1，共3次：15->0->1->2（含回绕）
        press(2200); wait_ms(50);
        check(brightness_level == 2 && up_cnt == 3, "长按2.2s升3级且15回绕到0");
        // 4) 松手后保持2s不应继续变化（修复点）
        wait_ms(2000);
        check(brightness_level == 2 && up_cnt == 3, "松手后亮度保持不变");
        check(key_state == 4'd0, "松手后状态回IDLE");
        // 5) 再长按1.1s：1次+1
        press(1100); wait_ms(50);
        check(brightness_level == 3, "再次长按1.1s升1级");
        // 6) 短按退出亮度模式，之后长按不调节
        press(100); wait_ms(100);
        check(brightness_mode == 0, "短按退出亮度模式");
        press(1500); wait_ms(100);
        check(brightness_level == 3, "退出模式后长按不调节");
        check(aerr == 0, "alpha折叠无溢出且等级15逐位旁路");
        if (errs == 0) $display("==== ALL PASS ===="); else $display("==== %0d FAIL ====", errs);
        $finish;
    end
endmodule
