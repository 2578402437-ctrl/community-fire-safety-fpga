wire signed [15:0] mix_audio_16 = mix_audio_left[22:7];
// KEY3音量：按听感等分。感知响度N∝振幅^0.6（Stevens），N在等级0(-22.5dB)与等级15(0dB)之间线性等分，
// Q12系数=round(4096*N^(1/0.6))，307~4096；每档响度约+5%，dB步进由低端3.2dB渐变到高端0.8dB。
reg [12:0] vol_gain;   // Q12，307~4096
always @(*) begin
    case (vol_level_eff)
        4'd0:  vol_gain = 13'd307;
        4'd1:  vol_gain = 13'd445;
        4'd2:  vol_gain = 13'd602;
        4'd3:  vol_gain = 13'd778;
        4'd4:  vol_gain = 13'd971;
        4'd5:  vol_gain = 13'd1181;
        4'd6:  vol_gain = 13'd1408;
        4'd7:  vol_gain = 13'd1649;
        4'd8:  vol_gain = 13'd1906;
        4'd9:  vol_gain = 13'd2178;
        4'd10: vol_gain = 13'd2464;
        4'd11: vol_gain = 13'd2763;
        4'd12: vol_gain = 13'd3077;
        4'd13: vol_gain = 13'd3404;
        4'd14: vol_gain = 13'd3743;
        default: vol_gain = 13'd4096;
    endcase
end
// 转场包络0~255映射到0~256（255→256），非转场时增益精确等于音量表值；
// 与音量系数相乘后舍入回Q12并寄存为目标增益（两者都是准静态量，晚一拍无影响）。
wire [8:0]  fade_gain_q8   = fade_gain_aud + fade_gain_aud[7];
wire [21:0] aud_gain_prod  = fade_gain_q8 * vol_gain;           // 最大256*4096=2^20
reg  [12:0] aud_gain_tgt;     // Q12，0~4096
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n)
        aud_gain_tgt <= 13'd4096;
    else
        aud_gain_tgt <= (aud_gain_prod + 22'd128) >> 8;
end
// 增益一阶平滑：每个48kHz样本 g += (t-g)>>>6（时间常数约1.3ms），
// 差值不足一步时按±1收敛，保证最终精确等于目标；消除换档与转场包络按帧阶跃的拉链噪声。
reg  [12:0] aud_gain_eff;     // Q12，0~4096
wire signed [13:0] aud_gain_diff = $signed({1'b0, aud_gain_tgt}) - $signed({1'b0, aud_gain_eff});
wire signed [13:0] aud_gain_step = (aud_gain_diff >>> 6) != 14'sd0 ? (aud_gain_diff >>> 6) :
                                   (aud_gain_diff > 14'sd0) ? 14'sd1 :
                                   (aud_gain_diff < 14'sd0) ? -14'sd1 : 14'sd0;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n)
        aud_gain_eff <= 13'd4096;
    else if (wav_sample_tick)
        aud_gain_eff <= aud_gain_eff + aud_gain_step[12:0];
end

wire signed [29:0] gain_prod    = mix_audio_16 * $signed({1'b0, aud_gain_eff});
wire signed [29:0] foot_prod = foot_pcm * $signed({1'b0, vol_gain});   // 无脚步时foot_pcm=0，乘法器不翻转
wire signed [30:0] mix_sum   = gain_prod + foot_prod + 31'sd16;
wire signed [30:0] mix_out   = mix_sum >>> 5;
