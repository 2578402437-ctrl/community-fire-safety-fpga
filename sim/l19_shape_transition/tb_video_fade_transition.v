`timescale 1ns/1ps
// video_fade_transition 自检测试，与旧版（改名为video_fade_transition_old）并排运行：
//   1) 握手：next_event_out/fade_busy 与旧版逐拍一致；
//   2) 音频包络：新版gain_alpha_out 与旧版alpha_out 逐拍一致（不含空闲期index_commit）；
//   3) 按次轮换：连续6次切换的类型依次为 0,1,2,3,0,1；
//   4) 画面alpha：类型0等于淡入淡出曲线；类型1~3除全黑等待期为0外恒为255；
//   5) 形状进度：退场q=256-vis、进场q=vis，单调不减，退场从0到256、进场从0开始；空闲时kind=0；
//   6) 转场忙时的新请求被丢弃；空闲期index_commit不触发转场（旧版会进入不可见的Wipe）。
module tb;
    localparam integer FF = 90;          // 与顶层一致
    localparam integer FRAME_CYC = 64;   // 缩短的"帧"周期（像素时钟拍数）
    reg pix_clk = 0, ctrl_clk = 0, rst_n = 0;
    always #20 pix_clk = ~pix_clk;       // 25MHz
    always #5  ctrl_clk = ~ctrl_clk;     // 100MHz

    reg next_in = 0;
    reg commit_pulse = 0;
    reg [7:0] fcnt = 0;
    wire frame_start = (fcnt == FRAME_CYC - 1);
    always @(posedge pix_clk) fcnt <= frame_start ? 8'd0 : fcnt + 1'b1;

    wire n_next, n_busy, n_act, n_in;
    wire [7:0] n_alpha, n_gain;
    wire [1:0] n_kind;
    wire [8:0] n_q;
    video_fade_transition #(.FADE_FRAMES(FF)) dut (
        .ctrl_clk(ctrl_clk), .ctrl_rst_n(rst_n), .next_event_in(next_in),
        .next_event_out(n_next), .fade_busy(n_busy),
        .pix_clk(pix_clk), .pix_rst_n(rst_n), .player_active(1'b1),
        .frame_start(frame_start), .index_commit(commit_pulse),
        .alpha_out(n_alpha), .gain_alpha_out(n_gain), .fade_active(n_act),
        .shape_kind(n_kind), .shape_in(n_in), .shape_q(n_q));

    wire o_next, o_busy;
    wire [7:0] o_alpha;
    video_fade_transition_old #(.FADE_FRAMES(FF)) ref_old (
        .ctrl_clk(ctrl_clk), .ctrl_rst_n(rst_n), .next_event_in(next_in),
        .next_event_out(o_next), .fade_busy(o_busy),
        .pix_clk(pix_clk), .pix_rst_n(rst_n), .player_active(1'b1),
        .frame_start(frame_start), .index_commit(commit_pulse), .active_index(2'd0),
        .alpha_out(o_alpha), .fade_active(), .wipe_active(), .ramp_out(), .transition_kind());

    wire [1:0] st = dut.g_fade.state;
    integer errors = 0;
    reg compare_en = 1;
    reg [1:0] prev_st = 0;
    reg [8:0] prev_q = 0;
    reg [1:0] kind_seen;
    integer   kind_log [0:7];
    integer   n_trans = 0;
    wire [8:0] vis9 = (n_gain == 8'hFF) ? 9'd256 : {1'b0, n_gain};

    always @(posedge pix_clk) if (rst_n) begin
        prev_st <= st;
        prev_q  <= n_q;
        if (compare_en && (n_gain !== o_alpha)) begin
            errors = errors + 1;
            if (errors < 10) $display("ERR gain!=old alpha t=%0t new=%0d old=%0d", $time, n_gain, o_alpha);
        end
        if (st == 0 && n_kind != 0) begin errors = errors + 1; $display("ERR 空闲时kind!=0"); end
        if (st != 0) begin
            if (dut.g_fade.cur_kind == 0) begin
                if (n_alpha !== n_gain) begin errors = errors + 1; $display("ERR 类型0 alpha!=曲线"); end
            end else begin
                if (n_alpha !== ((st == 2) ? 8'd0 : 8'd255)) begin
                    errors = errors + 1; $display("ERR 形状类型alpha=%0d st=%0d", n_alpha, st);
                end
            end
            if (n_q !== ((st == 3) ? vis9 : (9'd256 - vis9))) begin
                errors = errors + 1; $display("ERR q映射 st=%0d q=%0d", st, n_q);
            end
            // 单调：同一阶段内q不减
            if (st == prev_st && n_q < prev_q) begin
                errors = errors + 1; $display("ERR q回退 st=%0d %0d->%0d", st, prev_q, n_q);
            end
        end
        // 阶段入口值
        if (prev_st == 0 && st == 1) begin
            if (n_q != 0) begin errors = errors + 1; $display("ERR 退场起点q=%0d", n_q); end
            kind_log[n_trans] = dut.g_fade.cur_kind;
            n_trans = n_trans + 1;
        end
        if (prev_st == 1 && st == 2 && prev_q != 256) begin
            errors = errors + 1; $display("ERR 退场末帧q=%0d", prev_q);
        end
        if (prev_st == 2 && st == 3 && n_q != 0) begin
            errors = errors + 1; $display("ERR 进场起点q=%0d", n_q);
        end
    end

    always @(posedge ctrl_clk) if (rst_n && compare_en) begin
        if (n_next !== o_next || n_busy !== o_busy) begin
            errors = errors + 1;
            if (errors < 10) $display("ERR 握手不一致 t=%0t next %b/%b busy %b/%b", $time, n_next, o_next, n_busy, o_busy);
        end
    end

    task do_switch(input integer commit_delay);
        begin
            @(posedge ctrl_clk); next_in <= 1; @(posedge ctrl_clk); next_in <= 0;
            // 转场进行中再发一次请求，应被丢弃
            repeat (FRAME_CYC * 10 * 4) @(posedge ctrl_clk);
            @(posedge ctrl_clk); next_in <= 1; @(posedge ctrl_clk); next_in <= 0;
            wait (n_next == 1'b1);
            // 模拟SD加载耗时，index_commit落在帧中间
            repeat (commit_delay) @(posedge pix_clk);
            @(posedge pix_clk); commit_pulse <= 1; @(posedge pix_clk); commit_pulse <= 0;
            wait (n_busy == 1'b0);
            repeat (FRAME_CYC * 4 * 3) @(posedge ctrl_clk);
        end
    endtask

    integer i;
    initial begin
        #200 rst_n = 1;
        repeat (100) @(posedge pix_clk);
        for (i = 0; i < 6; i = i + 1)
            do_switch(FRAME_CYC * (3 + i) + 17 * i + 5);
        // 空闲期index_commit：新版应保持空闲（旧版会进Wipe，此段不比较）
        compare_en = 0;
        @(posedge pix_clk); commit_pulse <= 1; @(posedge pix_clk); commit_pulse <= 0;
        repeat (FRAME_CYC * 5) @(posedge pix_clk);
        if (st != 0 || n_busy) begin errors = errors + 1; $display("ERR 空闲期commit触发了转场"); end

        if (n_trans != 6) begin errors = errors + 1; $display("ERR 转场次数=%0d", n_trans); end
        for (i = 0; i < n_trans; i = i + 1) begin
            $display("第%0d次转场类型=%0d", i + 1, kind_log[i]);
            if (kind_log[i] != (i % 4)) begin errors = errors + 1; $display("ERR 轮换顺序"); end
        end
        $display("TB_DONE errors=%0d", errors);
        $display("%s", (errors == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
