// ============================================================================
// 文件名称：audio_sample_tick_gen.v
// 模块名称：audio_sample_tick_gen
// 功能描述：48kHz音频采样节拍发生器（NCO分频）
// 目标器件：安路 EG4S20BG256
// ============================================================================
// 音频采样节拍发生器（NCO分频）
// 把CLK_HZ用累加器精确锁定到SAMPLE_HZ的平均采样率，每当累加溢出，
// sample_tick拉高1个时钟周期。全工程唯一的48kHz节拍：wav_stream_player
// 读侧与pcm_media_tone共用，两路音频源天然同拍。
// 累加器按 SAMPLE_HZ/CLK_HZ 约去公约数RATIO_DIV后的比值 STEP/MODULUS 计数（25MHz/48kHz
// 约分为 6/3125），节拍序列与按原始数值累加完全相同，位宽只需 log2(MODULUS)。
module audio_sample_tick_gen #(
    parameter CLK_HZ    = 25_000_000,  // 本工程video_clk实际频率
    parameter SAMPLE_HZ = 48_000,
    parameter RATIO_DIV = 8_000        // CLK_HZ与SAMPLE_HZ的公约数（取最大公约数时位宽最小），须同时整除二者
)(
    input  wire clk,
    input  wire rst,            // 高有效复位，与pcm_media_tone保持一致
    output wire sample_tick
);

localparam integer STEP    = SAMPLE_HZ / RATIO_DIV;
localparam integer MODULUS = CLK_HZ / RATIO_DIV;
localparam integer ACC_W   = $clog2(MODULUS + 1);

reg [ACC_W-1:0] S_samp_acc;
assign sample_tick = (S_samp_acc + STEP) >= MODULUS;

always @(posedge clk or posedge rst) begin
    if (rst)
        S_samp_acc <= {ACC_W{1'b0}};
    else if (sample_tick)
        S_samp_acc <= S_samp_acc + STEP - MODULUS;
    else
        S_samp_acc <= S_samp_acc + STEP;
end

endmodule
