// ============================================================================
// 文件名称：pcm_media_tone.v
// 模块名称：pcm_media_tone
// 功能描述：切图提示音与六音符琶音合成（DDS查表）
// 目标器件：安路 EG4S20BG256
// ============================================================================
// 媒体音调联动：图片切换时先播放1.5kHz提示音(blip)，再进入该图片对应的六音符琶音循环。
// 48kHz采样节拍由外部audio_sample_tick_gen提供（与WAV读侧共用），DDS相位累加器为20位
// （相位增量=频率*2^20/采样率），16点LUT查表输出正弦样本。
module pcm_media_tone #(
    parameter SAMPLE_HZ           = 48_000,      // 采样率（音符相位增量按此计算）
    parameter [19:0] BLIP_INC     = 20'd32768,   // ~1500Hz切换提示音
    parameter        BLIP_SAMPLES = 4800,        // 100ms提示音时长
    parameter        NOTE_SAMPLES = 12000,       // 每个音符250ms
    parameter        VOL_SHIFT    = 7            // 固定音量缩放系数（左移位数）
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       sample_tick,   // 48kHz采样节拍（单周期脉冲，同clk域）
    input  wire [1:0] media_id,
    output reg        audio_valid,
    output reg [23:0] audio_left,
    output reg [23:0] audio_right
);

// 第一步：采样节拍（外部输入）
wire S_samp_tick = sample_tick;

// media_id变化检测：切换瞬间打一个switch_pulse，并锁存当前media_id供播放期间保持稳定
reg [1:0] S_media_id_d1;
wire      S_switch_pulse = (media_id != S_media_id_d1);
reg [1:0] S_media_id_latched;

always @(posedge clk or posedge rst) begin
    if (rst)
        S_media_id_d1 <= 2'd0;
    else
        S_media_id_d1 <= media_id;
end

// 播放状态机：BLIP（提示音）-> NOTE_PLAY（六音符循环，播完回第0个音符继续循环）
localparam S_BLIP      = 1'b0;
localparam S_NOTE_PLAY = 1'b1;

reg        S_play_state;
reg [12:0] S_dur_cnt;     // 计数到BLIP_SAMPLES或NOTE_SAMPLES
reg [2:0]  S_note_idx;    // 0~5循环

// 六音符表：note_inc_lut(media_id, note_idx)，值=round(freq/48000*2^20)
function [19:0] note_inc_lut;
    input [1:0] id;
    input [2:0] idx;
    begin
        case (id)
            2'd0: // C大调上行：C5 E5 G5 C6 G5 E5
                case (idx)
                    3'd0: note_inc_lut = 20'd11431;
                    3'd1: note_inc_lut = 20'd14402;
                    3'd2: note_inc_lut = 20'd17127;
                    3'd3: note_inc_lut = 20'd22861;
                    3'd4: note_inc_lut = 20'd17127;
                    default: note_inc_lut = 20'd14402;
                endcase
            2'd1: // A小调：A4 C5 E5 A5 E5 C5
                case (idx)
                    3'd0: note_inc_lut = 20'd9612;
                    3'd1: note_inc_lut = 20'd11431;
                    3'd2: note_inc_lut = 20'd14402;
                    3'd3: note_inc_lut = 20'd19224;
                    3'd4: note_inc_lut = 20'd14402;
                    default: note_inc_lut = 20'd11431;
                endcase
            2'd2: // 五声音阶：C5 D5 E5 G5 A5 C6
                case (idx)
                    3'd0: note_inc_lut = 20'd11431;
                    3'd1: note_inc_lut = 20'd12830;
                    3'd2: note_inc_lut = 20'd14402;
                    3'd3: note_inc_lut = 20'd17127;
                    3'd4: note_inc_lut = 20'd19224;
                    default: note_inc_lut = 20'd22861;
                endcase
            default: // 低-高摇摆：C4 C6 D4 D6 E4 E6
                case (idx)
                    3'd0: note_inc_lut = 20'd5715;
                    3'd1: note_inc_lut = 20'd22861;
                    3'd2: note_inc_lut = 20'd6415;
                    3'd3: note_inc_lut = 20'd25661;
                    3'd4: note_inc_lut = 20'd7201;
                    default: note_inc_lut = 20'd28803;
                endcase
        endcase
    end
endfunction

wire [19:0] W_phase_inc = (S_play_state == S_BLIP) ? BLIP_INC
                                                    : note_inc_lut(S_media_id_latched, S_note_idx);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        S_play_state        <= S_BLIP;
        S_dur_cnt            <= 13'd0;
        S_note_idx           <= 3'd0;
        S_media_id_latched   <= 2'd0;
    end
    else if (S_switch_pulse) begin
        // 切图瞬间：锁存新media_id，重新从提示音开始播放
        S_media_id_latched <= media_id;
        S_play_state       <= S_BLIP;
        S_dur_cnt          <= 13'd0;
        S_note_idx          <= 3'd0;
    end
    else if (S_samp_tick) begin
        if (S_play_state == S_BLIP) begin
            if (S_dur_cnt == BLIP_SAMPLES - 1) begin
                S_dur_cnt    <= 13'd0;
                S_play_state <= S_NOTE_PLAY;
            end
            else begin
                S_dur_cnt <= S_dur_cnt + 13'd1;
            end
        end
        else begin // S_NOTE_PLAY
            if (S_dur_cnt == NOTE_SAMPLES - 1) begin
                S_dur_cnt  <= 13'd0;
                S_note_idx <= (S_note_idx == 3'd5) ? 3'd0 : S_note_idx + 3'd1;
            end
            else begin
                S_dur_cnt <= S_dur_cnt + 13'd1;
            end
        end
    end
end

// 第二步：DDS相位累加器（20位，相位增量=频率*2^20/采样率）
reg [19:0] S_phase_acc;

always @(posedge clk or posedge rst) begin
    if (rst)
        S_phase_acc <= 20'd0;
    else if (S_samp_tick)
        S_phase_acc <= S_phase_acc + W_phase_inc;
end

// 第三步：16点正弦波LUT（0°~337.5°，幅值±12000）
function signed [15:0] sine_sample;
    input [3:0] index;
    case (index)
        4'd0:  sine_sample =  16'sd0;
        4'd1:  sine_sample =  16'sd4592;
        4'd2:  sine_sample =  16'sd8485;
        4'd3:  sine_sample =  16'sd11087;
        4'd4:  sine_sample =  16'sd12000;
        4'd5:  sine_sample =  16'sd11087;
        4'd6:  sine_sample =  16'sd8485;
        4'd7:  sine_sample =  16'sd4592;
        4'd8:  sine_sample =  16'sd0;
        4'd9:  sine_sample = -16'sd4592;
        4'd10: sine_sample = -16'sd8485;
        4'd11: sine_sample = -16'sd11087;
        4'd12: sine_sample = -16'sd12000;
        4'd13: sine_sample = -16'sd11087;
        4'd14: sine_sample = -16'sd8485;
        default: sine_sample = -16'sd4592;
    endcase
endfunction

// 第四步：取样输出，左移VOL_SHIFT位对齐到24位（固定音量缩放），audio_valid打一拍脉冲
wire signed [23:0] S_sample = {{(24-16-VOL_SHIFT){sine_sample(S_phase_acc[19:16])[15]}},
                                sine_sample(S_phase_acc[19:16]), {VOL_SHIFT{1'b0}}};

always @(posedge clk or posedge rst) begin
    if (rst) begin
        audio_valid <= 1'b0;
        audio_left  <= 24'sd0;
        audio_right <= 24'sd0;
    end
    else if (S_samp_tick) begin
        audio_valid <= 1'b1;
        audio_left  <= S_sample;
        audio_right <= S_sample;
    end
    else begin
        audio_valid <= 1'b0;
    end
end

endmodule
