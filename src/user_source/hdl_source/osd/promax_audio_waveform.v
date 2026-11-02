// ============================================================================
// 文件名称：promax_audio_waveform.v
// 模块名称：promax_audio_waveform
// 功能描述：音频波形与峰值条叠加层
// 目标器件：安路 EG4S20BG256
// ============================================================================
`timescale 1ns/1ps

// 音频波形 + 峰值条像素级叠加
//
// 工作原理：
//   采集侧：pcm_tap_valid每来一个样本，按DECIMATE抽取，每帧存SAMPLE_COUNT个
//           样本的高8位到双缓冲（ping-pong），同时记录本帧绝对值峰值。
//   帧边界：vsync下降沿（frame_start）时，若本帧已采满，交换写/显示bank，
//           保证一帧画面只显示同一批样本，不会撕裂。
//   显示侧：组合逻辑按像素坐标判断是否落在波形线/中心轴/峰值条上，
//           命中则替换颜色，否则直通rgb_in。
//
// 实现说明：
//   - 采集侧和显示侧都在video_clk（像素时钟）域，音频链本身也在video_clk域，
//     不涉及跨时钟域。
//   - line_y重建方式与其他叠加层相同（vsync拉低清零、de下降沿+1），
//     rgb_out为组合输出，与输入de同拍对齐，下游直接使用原de即可。
//   - 屏幕640x480，默认波形区域x=64~575、y=400~463，峰值条在x=584~591，
//     与左上角OSD状态条（8,8）不重叠。
module promax_audio_waveform #(
    parameter integer WAVE_X      = 64,    // 波形区域左上角X
    parameter integer WAVE_Y      = 400,   // 波形区域左上角Y
    parameter integer WAVE_WIDTH  = 512,   // 波形区域宽度
    parameter integer WAVE_HEIGHT = 64,    // 波形区域高度
    parameter integer DECIMATE    = 12,    // 抽取率：每12个样本取1个
    // 每帧采样点数：每个点在屏幕上画一段WAVE_WIDTH/SAMPLE_COUNT像素宽的横条，
    // 点数越多横条越短、波形越平滑。须满足 SAMPLE_COUNT*DECIMATE ≤ 800
    // （48kHz/60Hz每帧约800个样本），且WAVE_WIDTH能被SAMPLE_COUNT整除，最大255。
    parameter integer SAMPLE_COUNT = 32,
    // 显示增益（左移位数，带饱和）：只放大屏幕上的波形和峰值条，不影响声音。
    // 0=不放大（满量程才±32像素）。流行音乐平均响度常在-20dBFS
    // 左右，0档下波形几乎是平线，本工程顶层取2（×4）。
    parameter integer GAIN_SHIFT  = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [9:0]  pixel_x,
    input  wire        enable,             // 波形显示使能
    input  wire        pcm_tap_valid,      // 每个音频样本一个脉冲（clk域）
    input  wire signed [15:0] pcm_tap_left,
    output wire [23:0] rgb_out,
    output wire        waveform_active     // 当前像素被波形/轴线/峰值条覆盖
);
    localparam integer SAMPLE_SPACING = WAVE_WIDTH / SAMPLE_COUNT;  // 每个样本点横条宽度（像素）
    localparam integer CENTER_Y       = WAVE_Y + WAVE_HEIGHT/2;     // 中心轴线行号

    reg [11:0] line_y;
    reg de_q;
    reg vs_q;
    wire frame_start = vs_q && !vsync;   // vsync下降沿=一帧开始

    // 双缓冲：每个bank存32个8位有符号样本
    reg signed [7:0] sample_bank0 [0:SAMPLE_COUNT-1];
    reg signed [7:0] sample_bank1 [0:SAMPLE_COUNT-1];
    reg write_bank;
    reg display_bank;
    reg display_valid;
    reg [7:0] capture_count;   // 8位，SAMPLE_COUNT最大255
    reg [7:0] decimate_count;
    reg [7:0] peak_bank0;
    reg [7:0] peak_bank1;
    reg [7:0] display_peak;
    // 显示增益：放大GAIN_SHIFT位，超出16位范围时饱和到±32767，避免溢出翻转
    wire signed [31:0] tap_amp = $signed(pcm_tap_left) <<< GAIN_SHIFT;
    wire signed [15:0] tap_sat = (tap_amp >  32'sd32767) ? 16'sh7FFF :
                                 (tap_amp < -32'sd32768) ? 16'sh8000 :
                                                           tap_amp[15:0];
    // 高8位取绝对值（补码取反加1）
    wire [7:0] sample_abs = tap_sat[15] ?
                            (~tap_sat[15:8] + 1'b1) : tap_sat[15:8];

    // ---------------- 采集侧 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y <= 12'd0;
            de_q <= 1'b0;
            vs_q <= 1'b1;
            write_bank <= 1'b0;
            display_bank <= 1'b1;
            display_valid <= 1'b0;
            capture_count <= 8'd0;
            decimate_count <= 8'd0;
            peak_bank0 <= 8'd0;
            peak_bank1 <= 8'd0;
            display_peak <= 8'd0;
        end else begin
            de_q <= de;
            vs_q <= vsync;
            if (!vsync)
                line_y <= 12'd0;               // 场同步期间行号清零
            else if (de_q && !de)
                line_y <= line_y + 1'b1;       // 一行有效像素结束，行号+1

            if (frame_start) begin
                // 帧开始：本帧已采满才交换，否则继续显示上一批完整数据
                if (capture_count == SAMPLE_COUNT) begin
                    display_bank <= write_bank;
                    display_valid <= 1'b1;
                    display_peak <= write_bank ? peak_bank1 : peak_bank0;
                    write_bank <= ~write_bank;
                end
                capture_count <= 8'd0;
                decimate_count <= 8'd0;
                // 清零下一帧将要写入的bank的峰值
                if (write_bank) peak_bank0 <= 8'd0;
                else peak_bank1 <= 8'd0;
            end else if (pcm_tap_valid && capture_count < SAMPLE_COUNT) begin
                if (decimate_count == 0) begin
                    // 抽中样本：存高8位到当前写bank
                    if (write_bank)
                        sample_bank1[capture_count] <= tap_sat[15:8];
                    else
                        sample_bank0[capture_count] <= tap_sat[15:8];
                    capture_count <= capture_count + 1'b1;
                    decimate_count <= DECIMATE-1;
                    // 更新本帧峰值
                    if (write_bank) begin
                        if (sample_abs > peak_bank1) peak_bank1 <= sample_abs;
                    end else begin
                        if (sample_abs > peak_bank0) peak_bank0 <= sample_abs;
                    end
                end else begin
                    decimate_count <= decimate_count - 1'b1;
                end
            end
        end
    end

    // ---------------- 显示侧（组合逻辑） ----------------
    integer sample_index;
    integer sample_value;
    integer sample_y;
    integer peak_height;
    reg signed [7:0] selected_sample;
    reg wave_pixel;
    reg axis_pixel;
    reg peak_pixel;

    always @* begin
        sample_index = 0;
        selected_sample = 8'sd0;
        sample_value = 0;
        sample_y = CENTER_Y;
        peak_height = display_peak >> 2;   // 与波形同一缩放：峰值/4，0~31像素
        wave_pixel = 1'b0;
        axis_pixel = 1'b0;
        peak_pixel = 1'b0;

        // 波形区域
        if (enable && de && pixel_x >= WAVE_X &&
            pixel_x < WAVE_X + WAVE_WIDTH &&
            line_y >= WAVE_Y && line_y < WAVE_Y + WAVE_HEIGHT) begin
            axis_pixel = (line_y == CENTER_Y);
            sample_index = (pixel_x-WAVE_X) / SAMPLE_SPACING;
            if (display_valid && sample_index < SAMPLE_COUNT) begin
                selected_sample = display_bank ?
                                  sample_bank1[sample_index] : sample_bank0[sample_index];
                sample_value = $signed(selected_sample);
                sample_y = CENTER_Y - sample_value/4;   // 正半周在上，负半周在下
                wave_pixel = (line_y >= sample_y-1 && line_y <= sample_y+1);  // 线宽3像素
            end
        end

        // 峰值条：波形区域右侧8~16像素处，自底向上
        if (enable && de && pixel_x >= WAVE_X+WAVE_WIDTH+8 &&
            pixel_x < WAVE_X+WAVE_WIDTH+16 &&
            line_y >= WAVE_Y+WAVE_HEIGHT-peak_height &&
            line_y < WAVE_Y+WAVE_HEIGHT)
            peak_pixel = 1'b1;
    end

    // 颜色：波形绿 / 峰值橙 / 轴线深灰 / 其余直通
    assign waveform_active = wave_pixel || axis_pixel || peak_pixel;
    assign rgb_out = wave_pixel ? 24'h20ff90 :
                     peak_pixel ? 24'hffb020 :
                     axis_pixel ? 24'h406060 : rgb_in;
endmodule
