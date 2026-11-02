`timescale 1ns/1ps
// 音量增益段（顶层原样抠出）激励：随机换档/转场包络/样本，逐 tick 打印供 Python 比对
module tb_gain;
    reg video_clk = 0, video_rst_n = 0;
    always #20 video_clk = ~video_clk;
    reg  [3:0]  vol_level_eff = 4'd15;
    reg  [7:0]  fade_gain_aud = 8'd255;
    reg         wav_sample_tick = 0;
    reg  signed [23:0] mix_audio_left = 0;
    reg  signed [15:0] foot_pcm = 0;
`include "gain_chunk.vh"
    integer i, f, seed;
    initial begin
        seed = 7;
        f = $fopen("rtl_out.txt", "w");
        repeat (3) @(posedge video_clk);
        video_rst_n = 1;
        for (i = 0; i < 6000; i = i + 1) begin
            // 每 500 样本随机换档；每 50 样本随机改包络（模拟按帧阶跃）；样本含满幅极值
            if (i % 500 == 0) vol_level_eff = $random(seed);
            if (i % 50 == 0)  fade_gain_aud = (i % 1000 < 500) ? 8'd255 : $random(seed);
            mix_audio_left = (i % 97 == 0) ? 24'sh7FFF80 : (i % 89 == 0) ? 24'sh800000 : {{8{1'b0}}, $random(seed)} << 7;
            mix_audio_left = {mix_audio_left[16:0], 7'd0};
            foot_pcm = (i % 7 == 0) ? 16'sh8000 : (i % 5 == 0) ? 16'sh7FFF : $random(seed);
            @(posedge video_clk); #1;
            wav_sample_tick = 1;
            @(posedge video_clk); #1;
            wav_sample_tick = 0;
            repeat (3) @(posedge video_clk); #1;
            $fdisplay(f, "%0d %0d %0d %0d %0d %0d", vol_level_eff, fade_gain_aud, mix_audio_16, foot_pcm, aud_gain_eff, mix_out);
        end
        $fclose(f);
        $finish;
    end
endmodule
