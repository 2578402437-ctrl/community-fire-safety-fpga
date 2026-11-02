// ============================================================================
// 文件名称：sync_fade_gain.v
// 模块名称：sync_fade_gain
// 功能描述：音画同步转场音量包络（跨时钟域同步）
// 目标器件：安路 EG4S20BG256
// ============================================================================
`timescale 1ns/1ps

// 音画同步转场音量淡入淡出
//
// 顶层的video_fade_transition已经在像素域产生了8位alpha渐变（0=全黑，
// 255=全亮），本模块把这条包络搬进音频采样域，让音量跟随画面淡出淡入：
// 画面全黑时静音，画面全亮时满音量。alpha从像素域跨到音频域走本工程
// 既有的"帧边界锁存+2FF同步"惯例（与osd_img_idx等准静态信号同步手法一致）。
//
// 增益映射：gain=alpha。video_fade_transition在转场空闲时alpha恒为255，
// 所以转场结束后增益自然回到255（满音量），不需要单独的转场状态输入。
// 音频链用这个包络做乘法衰减（见顶层的增益应用）。本模块不提供独立的
// 音量调节。
module sync_fade_gain #(
    parameter integer SYNC_STAGES = 2
) (
    input  wire       pix_clk,
    input  wire       pix_rst_n,
    input  wire       frame_start,       // 像素域vsync边沿脉冲
    input  wire [7:0] alpha_pix,         // 像素域实时转场alpha（空闲时为255）

    input  wire       aud_clk,           // 音频采样域时钟
    input  wire       aud_rst_n,
    output reg  [7:0] gain_aud           // 音频域增益包络
);
    // 像素侧：帧边界锁存alpha（准静态量，锁存后2FF同步是安全的）
    reg [7:0] alpha_latch;
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n)
            alpha_latch <= 8'd255;
        else if (frame_start)
            alpha_latch <= alpha_pix;
    end

    // 音频侧：2FF同步锁存值，再打一拍输出
    reg [7:0] sync1, sync2;
    always @(posedge aud_clk or negedge aud_rst_n) begin
        if (!aud_rst_n) begin
            sync1    <= 8'd255;
            sync2    <= 8'd255;
            gain_aud <= 8'd255;
        end else begin
            sync1    <= alpha_latch;
            sync2    <= sync1;
            gain_aud <= sync2;
        end
    end
endmodule
