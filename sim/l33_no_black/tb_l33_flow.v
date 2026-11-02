`timescale 1ns/1ps
`default_nettype none
// 控制流程联合仿真：media_player_control + video_fade_transition（小帧，每帧100像素时钟）
// 屏幕内容按帧建模：A路bank = disp_buf_idx 两级同步后在帧首锁存，B路bank = mix_buf_idx 同样处理
// （与mem域 frame_fifo_read 在帧首 S_ACK 锁存一致），合成参数在帧首后第20拍锁存（vs_pre）。
// 每帧检查：
//   1) 不出现全黑/渐暗（alpha_out 恒255）；
//   2) 屏幕用到的bank都已加载完成，且不是正在写入的bank；
//   3) 同一次转场内：A只能是旧图、B只能是新图，B出现后不再出现纯旧图帧（不闪回）；
//   4) 转场结束后的第一帧空闲帧，A路已经是新图（交接无跳变）；
//   5) 音频包络：空闲255，转场中点最低约127。
// 场景：
//   K1 首图提交后"下一张"：目标未加载 → 预加载（期间旧图照常显示）→ 转场 → 提交，加载1次
//   K2 切回已加载过的图：不读卡，直接转场
//   K3 预加载内容错误（重试1次后放弃）：不发起转场，画面不动，之后还能切图
//   K4 预加载无进展（看门狗超时放弃）：同K3
//   K5 缩略图模式选图：预加载 → 硬切（不走转场）→ 约100ms后 select_done
//   K6 连续切图，转场类型轮换 0,1,3,4,5,0
module tb_l33_flow;
    localparam FADE_N = 8, HOLD_N = 40;
    reg clk = 0, pclk = 0;
    always #5  clk  = ~clk;    // 控制域
    always #20 pclk = ~pclk;   // 像素域
    reg rst = 1;

    reg [5:0] tcnt = 0; reg tick = 0;
    always @(posedge clk) begin tcnt <= (tcnt==49)?0:tcnt+1; tick <= (tcnt==49); end
    reg [6:0] fcnt = 0; reg frame_start = 0;
    always @(posedge pclk) begin fcnt <= (fcnt==99)?0:fcnt+1; frame_start <= (fcnt==99); end

    // 扫描模型：四张图（句柄 0~3）
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

    // 加载模型：3000拍送完（约7帧，跨多帧），再60拍写完；fail_mask 对应句柄内容错误，stall_mask 对应句柄卡住无进展
    reg [3:0] fail_mask = 0, stall_mask = 0;
    wire load_start_pulse; wire [31:0] load_sector;
    reg ready_r = 1, load_error = 0, wrfin = 0, loading = 0, wr_en = 0;
    wire bmp_ready = ready_r && !load_start_pulse;
    reg [12:0] lcnt = 0;
    integer n_loads = 0;
    always @(posedge clk) begin
        wr_en <= 0;
        if (load_start_pulse) begin ready_r <= 0; loading <= 1; lcnt <= 0; n_loads = n_loads + 1; end
        else if (loading && !stall_mask[load_sector[1:0]]) begin
            lcnt <= lcnt + 1;
            if (lcnt < 3000 && lcnt[3:0] == 4'd5) wr_en <= 1;
            if (lcnt == 3000) ready_r <= 1;
            if (lcnt == 3060) begin
                load_error <= fail_mask[load_sector[1:0]];
                wrfin <= ~wrfin; loading <= 0;
            end
        end
    end

    reg cmd_next = 0, cmd_sel = 0, view_mode = 0; reg [1:0] sel_idx = 0;
    wire switch_grant, fade_busy_in, switch_request, disp_commit_toggle, display_valid, select_done;
    wire [1:0] disp_buf_idx, img_idx, prev_disp_buf_idx, mix_buf_idx, write_buf_idx;
    wire [3:0] image_complete;

    reg c1=0,c2=0,c3=0, pa1=0, pa2=0;
    always @(posedge pclk) begin c1<=disp_commit_toggle; c2<=c1; c3<=c2; pa1<=display_valid; pa2<=pa1; end
    wire index_commit = c2 ^ c3;

    media_player_control #(.CLK_FREQ_HZ(1000), .AUTO_PLAY_MS(100000), .LOAD_TIMEOUT_MS(20), .MAX_RETRIES(1)) dut (
        .clk(clk), .rst(rst),
        .cmd_next_image(cmd_next), .cmd_prev_image(1'b0), .cmd_toggle_autoplay(1'b0),
        .cmd_brightness_enter(1'b0), .cmd_brightness_up(1'b0), .cmd_brightness_down(1'b0), .cmd_save_config(1'b0),
        .tick_1ms(tick), .tick_req(),
        .cmd_select_image(cmd_sel), .select_index(sel_idx), .view_mode(view_mode),
        .sw_sel_valid(1'b0), .sw_sel_idx(2'd0), .sw_hold(), .sw_shown_valid(), .sw_shown_idx(), .nav_target_idx(),
        .bg_valid(1'b0), .intro_commit_req(1'b0),
        .intro_bg_shown(), .intro_pic_ready(), .first_committed(),
        .scan_found_valid(scan_found_valid), .scan_found_sector(scan_found_sector), .scan_found_total(3'd4),
        .sd_init_done(1'b1), .bmp_ready(bmp_ready), .sdram_ready(1'b1), .scan_done(scan_done),
        .write_finish_toggle(wrfin), .bmp_data_wr_en(wr_en), .bmp_data(24'd0),
        .load_error(load_error), .bmp_error_code(8'h40),
        .switch_grant(switch_grant), .fade_busy_in(fade_busy_in), .switch_request(switch_request),
        .disp_commit_toggle(disp_commit_toggle), .prev_disp_buf_idx(prev_disp_buf_idx),
        .mix_buf_idx(mix_buf_idx), .select_done(select_done),
        .write_buf_idx(write_buf_idx), .disp_buf_idx(disp_buf_idx), .img_idx(img_idx),
        .brightness_level(), .brightness_mode(), .volume_level(), .volume_mode(),
        .display_valid(display_valid), .auto_play_en(),
        .scan_start_pulse(scan_start_pulse), .load_start_pulse(load_start_pulse), .load_sector(load_sector),
        .state_code(), .last_error_code(), .image_complete(image_complete), .image_count()
    );
    wire mix_active; wire [2:0] shape_kind; wire [8:0] shape_q; wire [7:0] alpha_out, gain;
    video_fade_transition #(.FADE_FRAMES(FADE_N), .HOLD_TIMEOUT_FRAMES(HOLD_N)) fade (
        .ctrl_clk(clk), .ctrl_rst_n(!rst), .next_event_in(switch_request), .next_event_out(switch_grant),
        .fade_busy(fade_busy_in),
        .pix_clk(pclk), .pix_rst_n(!rst), .player_active(pa2), .frame_start(frame_start),
        .index_commit(index_commit), .alpha_out(alpha_out), .gain_alpha_out(gain), .fade_active(),
        .mix_active(mix_active), .shape_kind(shape_kind), .shape_in(), .shape_q(shape_q)
    );

    // ---------- 屏幕内容逐帧监视 ----------
    integer errs = 0;
    task fail(input [8*48-1:0] msg); begin errs = errs + 1; if (errs <= 30) $display("FAIL %0s t=%0t", msg, $time); end endtask

    reg [1:0] a_s1=0, a_s2=0, b_s1=0, b_s2=0, A_f=0, B_f=0;
    reg act_f = 0; reg [8:0] q_f = 0; reg [2:0] kind_f = 0;
    reg in_tr = 0, saw_b = 0, check_hand = 0; reg [1:0] tr_old = 0, tr_new = 0;
    integer n_tr = 0, min_gain = 255, n_blend = 0;
    integer kind_log [0:15];
    always @(posedge pclk) begin
        a_s1 <= disp_buf_idx; a_s2 <= a_s1; b_s1 <= mix_buf_idx; b_s2 <= b_s1;
        if (frame_start) begin A_f <= a_s2; B_f <= b_s2; end
        if (fcnt == 20) begin act_f <= mix_active; q_f <= shape_q; kind_f <= shape_kind; end
        if (!rst && pa2) begin
            if (alpha_out != 8'd255) fail("alpha_out!=255 (dimming)");
            if (!fade_busy_in && !mix_active && gain != 8'd255) fail("idle gain!=255");
            if (mix_active && gain < min_gain) min_gain = gain;
        end
        if (fcnt == 60 && !rst && pa2) begin : frame_chk
            reg cA, cB;
            cA = !act_f || (q_f < 9'd256);
            cB = act_f && (q_f > 9'd0);
            if (cA && !image_complete[A_f]) fail("A shows bank not complete");
            if (cB && !image_complete[B_f]) fail("B shows bank not complete");
            if (cA && dut.load_busy && A_f == write_buf_idx) fail("A shows bank being written");
            if (cB && dut.load_busy && B_f == write_buf_idx) fail("B shows bank being written");
            if (cA && cB) n_blend = n_blend + 1;
            if (act_f && !in_tr) begin
                in_tr = 1; saw_b = 0; tr_old = A_f; kind_log[n_tr] = kind_f; n_tr = n_tr + 1;
            end
            if (in_tr && act_f) begin
                if (cA && A_f != tr_old) fail("A not old image during transition");
                if (cB) begin
                    if (!saw_b) begin saw_b = 1; tr_new = B_f; end
                    else if (B_f != tr_new) fail("B changed during transition");
                    if (B_f == tr_old) fail("B same as old");
                end
                if (saw_b && cA && !cB) fail("flash back to old after new appeared");
            end
            if (check_hand) begin
                check_hand = 0;
                if (A_f != tr_new) fail("A not new on first frame after handoff");
            end
            if (!act_f && in_tr) begin
                in_tr = 0;
                if (!saw_b) fail("transition ended without showing new");
                else if (A_f != tr_new) fail("A not new on first frame after handoff");
                check_hand = 1;
            end
        end
    end

    // ---------- 场景驱动 ----------
    task press_next; begin @(posedge clk); cmd_next <= 1; @(posedge clk); cmd_next <= 0; end endtask
    task press_sel(input [1:0] k); begin @(posedge clk); sel_idx <= k; cmd_sel <= 1; @(posedge clk); cmd_sel <= 0; end endtask
    task wait_idle; integer k; begin
        // 等切图与转场全部结束（先等几拍，避开按键当拍 switch_pending 尚未更新的竞争）
        repeat (5) @(posedge clk);
        for (k = 0; k < 400000 && (dut.switch_pending || fade_busy_in || dut.load_busy || dut.sel_exit_wait); k = k + 1)
            @(posedge clk);
        if (k >= 400000) fail("wait_idle timeout (stuck)");
        repeat (3000) @(posedge clk);
    end endtask

    integer l0, sel_t0, sel_t1, busy_seen;
    always @(posedge clk) if (fade_busy_in) busy_seen = 1;
    always @(posedge clk) if (select_done) sel_t1 = $time;
    always @(posedge clk) begin
        if (cmd_next) $display("DBG t=%0t press disp=%0d img=%0d pend=%0d busy=%0d ld=%0d", $time, disp_buf_idx, img_idx, dut.switch_pending, fade_busy_in, dut.load_busy);
        if (switch_request) $display("DBG t=%0t request target=%0d mix=%0d", $time, dut.pending_target_idx, mix_buf_idx);
        if (load_start_pulse) $display("DBG t=%0t load sector=%0d preload=%0d", $time, load_sector, dut.load_preload);
        if (switch_grant) $display("DBG t=%0t grant", $time);
    end
    reg tgl_q = 0; integer n_commit = 0;
    always @(posedge clk) begin tgl_q <= disp_commit_toggle; if (tgl_q != disp_commit_toggle) n_commit = n_commit + 1; end

    initial begin
        repeat (20) @(posedge pclk); rst = 0;
        // 首图
        wait (display_valid); wait_idle;
        if (disp_buf_idx != 0) fail("first image bank!=0");

        // K1：0→1，未加载，预加载后转场
        l0 = n_loads; busy_seen = 0; press_next;
        repeat (200) @(posedge clk);
        if (!dut.load_busy || fade_busy_in) fail("K1 no preload first / transition too early");
        wait_idle;
        if (disp_buf_idx != 1 || img_idx != 1) fail("K1 not switched to 1");
        if (n_loads - l0 != 1) fail("K1 loads!=1");
        if (!busy_seen) fail("K1 no transition");
        $display("K1 done disp=%0d loads=%0d", disp_buf_idx, n_loads - l0);

        // K2：1→2→3→0→1（2、3 首次加载；0、1 已加载过不读卡）
        press_next; wait_idle; press_next; wait_idle;
        l0 = n_loads; busy_seen = 0; press_next; wait_idle;
        if (disp_buf_idx != 0) fail("K2 not switched to 0");
        if (n_loads != l0) fail("K2 resident image reloaded");
        if (!busy_seen) fail("K2 no transition");
        press_next; wait_idle;
        if (disp_buf_idx != 1) fail("K2 not switched to 1");
        $display("K2 done disp=%0d", disp_buf_idx);

        // K3：bank2 被覆盖后预加载内容错误 → 放弃，画面不动
        force dut.image_complete[2] = 1'b0; repeat (2) @(posedge clk); release dut.image_complete[2];
        fail_mask = 4'b0100; l0 = n_loads; busy_seen = 0;
        press_next; wait_idle;
        if (disp_buf_idx != 1 || img_idx != 1) fail("K3 display changed after abandon");
        if (n_loads - l0 != 2) fail("K3 loads!=2");
        if (busy_seen) fail("K3 transition started on failure");
        fail_mask = 0;
        press_next; wait_idle;
        if (disp_buf_idx != 2) fail("K3 switch after recovery failed");
        $display("K3 done disp=%0d", disp_buf_idx);

        // K4：bank3 预加载无进展 → 看门狗放弃
        force dut.image_complete[3] = 1'b0; repeat (2) @(posedge clk); release dut.image_complete[3];
        stall_mask = 4'b1000; busy_seen = 0;
        press_next; wait_idle;
        if (disp_buf_idx != 2) fail("K4 display changed after abandon");
        if (busy_seen) fail("K4 transition started on failure");
        stall_mask = 0; loading = 0; ready_r = 1;
        press_next; wait_idle;
        if (disp_buf_idx != 3) fail("K4 switch after recovery failed");
        $display("K4 done disp=%0d", disp_buf_idx);

        // K5：缩略图模式选图1（先让bank1失效以覆盖预加载），硬切
        force dut.image_complete[1] = 1'b0; repeat (2) @(posedge clk); release dut.image_complete[1];
        view_mode = 1; busy_seen = 0; sel_t1 = 0; l0 = n_commit;
        press_sel(2'd1); sel_t0 = $time;
        wait (disp_buf_idx == 2'd1 || $time > sel_t0 + 2000000);
        sel_t0 = $time;
        wait_idle;
        if (disp_buf_idx != 1) fail("K5 not hard-cut to 1");
        if (busy_seen) fail("K5 thumbnail select used transition");
        if (sel_t1 == 0) fail("K5 no select_done");
        else if (sel_t1 - sel_t0 < 4900*10) fail("K5 select_done too early");
        if (n_commit != l0) fail("K5 hard cut toggled commit");
        view_mode = 0;
        $display("K5 done disp=%0d select_done_delay=%0dns", disp_buf_idx, sel_t1 - sel_t0);

        // K6：再切两次，凑满轮换
        press_next; wait_idle; press_next; wait_idle;

        // 汇总
        begin : summary
            integer i, exp;
            $display("transitions=%0d blend_frames=%0d min_gain=%0d", n_tr, n_blend, min_gain);
            for (i = 0; i < n_tr; i = i + 1) begin
                case (i % 5) 0: exp = 0; 1: exp = 1; 2: exp = 3; 3: exp = 4; default: exp = 5; endcase
                $display("  transition %0d kind=%0d", i + 1, kind_log[i]);
                if (kind_log[i] != exp) fail("kind rotation wrong");
            end
            if (n_tr != 9) fail("transition count!=9");  // K1:1 K2:4 K3:1 K4:1 K6:2
            if (min_gain < 120 || min_gain > 135) fail("gain midpoint not ~half");
        end
        $display("TB_DONE errors=%0d", errs);
        $display("%s", errs == 0 ? "ALL PASS" : "FAIL");
        $finish;
    end
endmodule
