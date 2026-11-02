`timescale 1ns/1ps
// 转场q缓入缓出（smoothstep）逐帧打印，供 q_check.py 比对
module tb_q;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;   // 两域共用一个时钟，只看q序列

    reg next_ev = 0, frame_start = 0, index_commit = 0;
    wire next_out, busy, fade_active, mix_active, shape_in;
    wire [7:0] alpha, gain;
    wire [2:0] kind;
    wire [8:0] q;

    video_fade_transition #(.FADE_FRAMES(90)) dut (
        .ctrl_clk(clk), .ctrl_rst_n(rst_n),
        .next_event_in(next_ev), .next_event_out(next_out), .fade_busy(busy),
        .pix_clk(clk), .pix_rst_n(rst_n), .player_active(1'b1),
        .frame_start(frame_start), .index_commit(index_commit),
        .alpha_out(alpha), .gain_alpha_out(gain), .fade_active(fade_active),
        .mix_active(mix_active), .shape_kind(kind), .shape_in(shape_in), .shape_q(q));

    integer f, run;
    initial begin
        #100 rst_n = 1;
        for (run = 0; run < 2; run = run + 1) begin
            @(posedge clk) next_ev = 1; @(posedge clk) next_ev = 0;
            for (f = 0; f < 110; f = f + 1) begin
                repeat (40) @(posedge clk);
                // 帧中间采样：打印本帧 q 与包络
                $display("Q run=%0d f=%0d st=%0d kind=%0d q=%0d gain=%0d", run, f, dut.g_fade.state, kind, q, gain);
                repeat (40) @(posedge clk);
                frame_start = 1; @(posedge clk) frame_start = 0;
                if (dut.g_fade.state == 2'd3 && !dut.g_fade.committed) begin
                    repeat (10) @(posedge clk);   // 等提交握手跨域
                    index_commit = 1; @(posedge clk) index_commit = 0;
                end
            end
        end
        $display("DONE");
        $finish;
    end
endmodule
