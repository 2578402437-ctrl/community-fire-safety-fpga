`timescale 1ns/1ps
`default_nettype none
// P2 仿真：加载无进展看门狗 + SD重新初始化清switch_pending（在P1场景基础上扩展）
// A~D 同P1；E 源端送完但写完脉冲丢失；F 慢速但持续有进展（总时长超过超时阈值）；A3 D恢复后再切图
module tb_p2_wd;
    localparam FADE_N = 4, HOLD_N = 12;
    reg clk = 0, pclk = 0;
    always #5  clk  = ~clk;    // 控制域
    always #20 pclk = ~pclk;   // 像素域
    reg rst = 1;

    // 1ms节拍：每50拍一个
    reg [5:0] tcnt = 0; reg tick = 0;
    always @(posedge clk) begin tcnt <= (tcnt==49)?0:tcnt+1; tick <= (tcnt==49); end
    // 帧开始：每100个像素时钟一个
    reg [6:0] fcnt = 0; reg frame_start = 0;
    always @(posedge pclk) begin fcnt <= (fcnt==99)?0:fcnt+1; frame_start <= (fcnt==99); end

    reg sd_init_done = 1;
    // 扫描模型
    reg scan_found_valid = 0; reg [31:0] scan_found_sector = 0; reg scan_done = 0;
    wire scan_start_pulse;
    // 加载模型：mode 0=成功 1=内容错误 2=源端不送完 3=送完但写完脉冲丢失 4=慢速成功（每100拍一个像素，共3000拍）
    reg [2:0] mode = 0;
    reg wr_en = 0;
    wire load_busy = dut.load_busy;
    reg ready_r = 1, load_error = 0, wrfin = 0;
    reg loading = 0;
    wire load_start_pulse;
    wire bmp_ready = ready_r && !load_start_pulse;
    integer n_loads = 0;
    reg [11:0] lcnt2 = 0;
    wire [11:0] t_src = (mode == 4) ? 12'd3000 : 12'd200;
    always @(posedge clk) begin
        wr_en <= 0;
        if (load_start_pulse) begin ready_r <= 0; loading <= 1; lcnt2 <= 0; n_loads = n_loads + 1; end
        else if (loading) begin
            lcnt2 <= lcnt2 + 1;
            if (lcnt2 < t_src && lcnt2[3:0] == 4'd5 && (mode != 4 || lcnt2 % 100 == 5) && mode != 2) wr_en <= 1;
            if (lcnt2 == t_src && mode != 2) ready_r <= 1;   // 源数据送完；mode2源端一直不送完
            if (lcnt2 == t_src && mode == 3) loading <= 0;   // mode3写完脉冲丢失
            if (lcnt2 == t_src + 60 && mode != 2 && mode != 3) begin
                load_error <= (mode == 1);
                wrfin <= ~wrfin; loading <= 0;
            end
        end
    end
    // mode2：控制层放弃加载（或SD重新初始化）后源端回到就绪
    always @(posedge clk) if ((mode == 2 || mode == 3) && !load_busy && !load_start_pulse && !ready_r) begin ready_r <= 1; loading <= 0; end
    integer scnt = 0;
    always @(posedge clk) begin
        scan_found_valid <= 0;
        if (scan_start_pulse) begin scan_done <= 0; scnt = 1; end
        else if (scnt > 0) begin
            scnt = scnt + 1;
            if (scnt == 20) begin scan_found_valid <= 1; scan_found_sector <= 100; end
            if (scnt == 30) begin scan_found_valid <= 1; scan_found_sector <= 200; end
            if (scnt == 40) begin scan_done <= 1; scnt = 0; end
        end
    end

    reg cmd_next = 0;
    wire switch_grant, fade_busy_in, switch_request, disp_commit_toggle, display_valid;
    wire [1:0] disp_buf_idx, img_idx, prev_disp_buf_idx;

    // index_commit 跨域（与顶层一致：两级打拍+边沿）
    reg c1=0,c2=0,c3=0, pa1=0, pa2=0;
    always @(posedge pclk) begin c1<=disp_commit_toggle; c2<=c1; c3<=c2; pa1<=display_valid; pa2<=pa1; end
    wire index_commit = c2 ^ c3;

    media_player_control #(.CLK_FREQ_HZ(1000), .AUTO_PLAY_MS(100000), .LOAD_TIMEOUT_MS(20), .MAX_RETRIES(1)) dut (
        .clk(clk), .rst(rst),
        .cmd_next_image(cmd_next), .cmd_prev_image(1'b0), .cmd_toggle_autoplay(1'b0),
        .cmd_brightness_enter(1'b0), .cmd_brightness_up(1'b0), .cmd_brightness_down(1'b0), .cmd_save_config(1'b0),
        .tick_1ms(tick), .tick_req(),
        .cmd_select_image(1'b0), .select_index(2'd0), .view_mode(1'b0),
        .sw_sel_valid(1'b0), .sw_sel_idx(2'd0), .sw_hold(), .sw_shown_valid(), .sw_shown_idx(), .nav_target_idx(),
        .scan_found_valid(scan_found_valid), .scan_found_sector(scan_found_sector), .scan_found_total(3'd2),
        .sd_init_done(sd_init_done), .bmp_ready(bmp_ready), .sdram_ready(1'b1), .scan_done(scan_done),
        .write_finish_toggle(wrfin), .bmp_data_wr_en(wr_en), .bmp_data(24'd0),
        .load_error(load_error), .bmp_error_code(8'h40),
        .switch_grant(switch_grant), .fade_busy_in(fade_busy_in), .switch_request(switch_request),
        .disp_commit_toggle(disp_commit_toggle), .prev_disp_buf_idx(prev_disp_buf_idx),
        .write_buf_idx(), .disp_buf_idx(disp_buf_idx), .img_idx(img_idx),
        .brightness_level(), .brightness_mode(), .volume_level(), .volume_mode(),
        .display_valid(display_valid), .auto_play_en(),
        .scan_start_pulse(scan_start_pulse), .load_start_pulse(load_start_pulse), .load_sector(),
        .state_code(), .last_error_code(), .image_complete(), .image_count()
    );
    wire [1:0] fstate = fade.g_fade.state;
    video_fade_transition #(.FADE_FRAMES(FADE_N)
`ifndef OLD
        , .HOLD_TIMEOUT_FRAMES(HOLD_N)
`endif
    ) fade (
        .ctrl_clk(clk), .ctrl_rst_n(!rst), .next_event_in(switch_request), .next_event_out(switch_grant),
        .fade_busy(fade_busy_in),
        .pix_clk(pclk), .pix_rst_n(!rst), .player_active(pa2), .frame_start(frame_start),
        .index_commit(index_commit), .alpha_out(), .gain_alpha_out(), .fade_active(),
        .shape_kind(), .shape_in(), .shape_q()
    );

    integer errs = 0;
    task press; begin @(posedge clk); cmd_next <= 1; @(posedge clk); cmd_next <= 0; end endtask
    // 等转场回到空闲，最多 maxf 帧
    task wait_idle(input integer maxf, output integer ok); integer k; begin
        ok = 0; repeat (20) @(posedge pclk);
        for (k = 0; k < maxf*100 && !ok; k = k + 1) begin @(posedge pclk); if (fstate == 0 && !load_busy) ok = 1; end
    end endtask
    task check(input [8*24-1:0] name, input integer ok, input [1:0] exp_disp); begin
        repeat (10) @(posedge clk);
        if (ok && disp_buf_idx == exp_disp && img_idx == exp_disp && display_valid)
            $display("PASS %0s : fade idle, disp=%0d img=%0d loads=%0d t=%0t", name, disp_buf_idx, img_idx, n_loads, $time);
        else begin
            errs = errs + 1;
            $display("FAIL %0s : ok=%0d fstate=%0d disp=%0d img=%0d load_busy=%0d t=%0t", name, ok, fstate, disp_buf_idx, img_idx, load_busy, $time);
        end
    end endtask

    integer ok;
    initial begin
        repeat (5) @(posedge clk); rst = 0;
        // 首张图
        wait (display_valid); repeat (100) @(posedge clk);
        $display("first image shown disp=%0d", disp_buf_idx);

        // A 正常切图 0→1
        mode = 0; n_loads = 0; press; wait_idle(40, ok); check("A normal", ok, 2'd1);
        // B 内容错误，重试1次后放弃 → 回旧图1
        mode = 1; n_loads = 0; press; wait_idle(40, ok); check("B content-err", ok, 2'd1);
        if (n_loads != 2) begin errs = errs + 1; $display("FAIL B loads=%0d expect 2", n_loads); end
        // C 加载超时，重试1次后放弃 → 回旧图1
        mode = 2; n_loads = 0; press; wait_idle(60, ok); check("C timeout", ok, 2'd1);
        if (n_loads != 2) begin errs = errs + 1; $display("FAIL C loads=%0d expect 2", n_loads); end
        // A2 失败后还能正常切图 1→0
        mode = 0; n_loads = 0; press; wait_idle(40, ok); check("A2 after-fail", ok, 2'd0);
        // D 全黑等待期间SD重新初始化：提交丢失，靠S_HOLD超时进场
        mode = 2; press;
        wait (fstate == 2); repeat (300) @(posedge clk);
        sd_init_done = 0; repeat (50) @(posedge clk); sd_init_done = 1;
        mode = 0;
        wait_idle(HOLD_N + 30, ok); check("D hold-timeout", ok, 2'd0);
        // A3 恢复后按键仍有效 0→1
        mode = 0; n_loads = 0; press; wait_idle(40, ok); check("A3 after-reinit", ok, 2'd1);
        // E 源端送完但写完脉冲丢失 → 看门狗超时重试再放弃，回旧图1
        mode = 3; n_loads = 0; press; wait_idle(60, ok); check("E wrfin-lost", ok, 2'd1);
        if (n_loads != 2) begin errs = errs + 1; $display("FAIL E loads=%0d expect 2", n_loads); end
        // F 慢速但持续有进展（3000拍 > 超时1000拍）→ 一次成功 1→0
        mode = 4; n_loads = 0; press; wait_idle(60, ok); check("F slow-progress", ok, 2'd0);
        if (n_loads != 1) begin errs = errs + 1; $display("FAIL F loads=%0d expect 1", n_loads); end

        if (errs == 0) $display("ALL PASS"); else $display("%0d FAILED", errs);
        $finish;
    end
    initial begin #20_000_000; $display("GLOBAL TIMEOUT"); $finish; end
endmodule
