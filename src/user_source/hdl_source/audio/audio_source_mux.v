// ============================================================================
// 文件名称：audio_source_mux.v
// 模块名称：audio_source_mux
// 功能描述：音频源选择：WAV流式播放 / 媒体提示音琶音
// 目标器件：安路 EG4S20BG256
// ============================================================================
// 音频源二选一——WAV流式播放 / 媒体音调琶音(pcm_media_tone)
//
// 优先级：wav_active（TF卡WAV正在播放）且未被force_arpeggio强制时，选WAV；
// 否则选琶音。纯组合逻辑三目选择，延迟为0。
//
// 本工程的HDMI音频链（audio_arc_calculate+
// hdmi_1_4b_transmitter_core_wrapper）本身没有ready反压（I_audio_valid只是
// 单拍脉冲，下游没有可能"没准备好"），pcm_media_tone同理也没有ready输入，
// 因此这里不做valid/ready握手路由，只做"选中哪一路的valid/sample直通"的
// 纯选择器：未被选中的一路样本直接丢弃，
// 不会影响另一路的产生（两路数据源都不依赖下游ready来驱动自己的状态机）。
module audio_source_mux (
    input  wire               wav_active,      // WAV流处于播放中（wav_stream_player.stream_active）
    input  wire               force_arpeggio,  // 强制切回琶音（当前工程无空闲按键/拨码，固定接0）

    input  wire               wav_valid,
    input  wire signed [23:0] wav_left,
    input  wire signed [23:0] wav_right,

    input  wire               arp_valid,
    input  wire signed [23:0] arp_left,
    input  wire signed [23:0] arp_right,

    output wire               out_valid,
    output wire signed [23:0] out_left,
    output wire signed [23:0] out_right
);
    wire use_wav = wav_active && !force_arpeggio;

    assign out_valid = use_wav ? wav_valid : arp_valid;
    assign out_left  = use_wav ? wav_left  : arp_left;
    assign out_right = use_wav ? wav_right : arp_right;
endmodule
