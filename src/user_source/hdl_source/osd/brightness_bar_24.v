// ============================================================================
// 文件名称：brightness_bar_24.v
// 模块名称：brightness_bar_24
// 功能描述：亮度/音量调节界面叠加层（标题文字 + 16格进度条）
// 目标器件：安路 EG4S20BG256
// ============================================================================
`timescale 1ns/1ps

// KEY3亮度/音量调节：屏幕中央"亮度调节"/"音量调节"字幕+进度条（24位RGB叠加层）。
// 进入亮度或音量模式时显示：半透明暗色面板，上方4个32×32汉字（title_sel选标题），
// 下方16格进度条，点亮格数 = 等级+1。
// 字库6字：0亮 1度 2调 3节 4音 5量；音量标题第0/1格换成4/5，"调节"共用。
// 与scroll_subtitle_24相同：像素路径纯组合，不增加流水线延迟；
// 行号由本地vsync/de重建；使能与等级只在帧边界锁存，画面不撕裂。
// 字形点阵由 tools/convert/make_brightness_font.py 生成，改文字时重跑该脚本。
module brightness_bar_24 #(
    parameter integer PANEL_X   = 140,          // 面板左上角
    parameter integer PANEL_Y   = 184,
    parameter integer PANEL_W   = 360,
    parameter integer PANEL_H   = 112,
    parameter integer TEXT_X    = 256,          // 文字起点（4字×32=128，水平居中于640）
    parameter integer TEXT_Y    = 194,
    parameter integer BAR_X     = 160,          // 进度条起点：16格×(18+2)=320，水平居中于640
    parameter integer BAR_Y     = 244,
    parameter integer BAR_H     = 24,
    parameter integer CELL_W    = 18,           // 每格宽度
    parameter integer CELL_GAP  = 2,            // 格间距
    parameter [23:0]  TEXT_COLOR = 24'hFFD200,  // 文字颜色（金黄，与滚动字幕一致）
    parameter [23:0]  ON_COLOR   = 24'hFFD200,  // 已点亮格
    parameter [23:0]  VOL_TEXT_COLOR = 24'h30C8FF,  // 音量模式文字颜色（青蓝，与亮度金黄区分）
    parameter [23:0]  VOL_ON_COLOR   = 24'h30C8FF,  // 音量模式已点亮格
    parameter [23:0]  OFF_COLOR  = 24'h404040   // 未点亮格
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [9:0]  pixel_x,
    input  wire        enable,       // 1=显示（亮度或音量模式），帧边界生效
    input  wire        title_sel,    // 0=亮度调节 1=音量调节，帧边界生效
    input  wire [3:0]  level,        // 亮度/音量等级0~15，帧边界生效
    output wire [23:0] rgb_out,
    output wire        bar_active
);
    localparam integer GLYPH     = 32;
    localparam integer NUM_CHARS = 4;               // 每个标题固定4字（字形ROM按3位字号寻址，共6字）
    localparam integer TEXT_W    = GLYPH * NUM_CHARS;
    localparam integer CELL_PITCH = CELL_W + CELL_GAP;
    localparam integer BAR_W     = CELL_PITCH * 16;

    // ---------- 行号重建（与scroll_subtitle_24一致）----------
    reg [11:0] line_y;
    reg de_q;
    reg vs_q;
    wire frame_start = vs_q && !vsync;

    reg       enable_frame;
    reg       title_frame;
    reg [3:0] level_frame;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y <= 12'd0;
            de_q <= 1'b0;
            vs_q <= 1'b1;
            enable_frame <= 1'b0;
            title_frame <= 1'b0;
            level_frame <= 4'd15;
        end else begin
            de_q <= de;
            vs_q <= vsync;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;

            if (frame_start) begin
                enable_frame <= enable;
                title_frame  <= title_sel;
                level_frame  <= level;
            end
        end
    end

    // ---------- 字形ROM：{字号, 行号} → 32位行点阵（bit31为最左像素）----------
    function [31:0] glyph_row;
        input [7:0] addr;
        begin
            case (addr)
            // FONT_BEGIN
            // 第0字：亮
            {3'd0, 5'd 0}: glyph_row = 32'h00000000;
            {3'd0, 5'd 1}: glyph_row = 32'h00020000;
            {3'd0, 5'd 2}: glyph_row = 32'h00070000;
            {3'd0, 5'd 3}: glyph_row = 32'h00070000;
            {3'd0, 5'd 4}: glyph_row = 32'h1fffffe0;
            {3'd0, 5'd 5}: glyph_row = 32'h1fffffe0;
            {3'd0, 5'd 6}: glyph_row = 32'h00000000;
            {3'd0, 5'd 7}: glyph_row = 32'h00000000;
            {3'd0, 5'd 8}: glyph_row = 32'h01fffe00;
            {3'd0, 5'd 9}: glyph_row = 32'h01fffe00;
            {3'd0, 5'd10}: glyph_row = 32'h01800600;
            {3'd0, 5'd11}: glyph_row = 32'h01800600;
            {3'd0, 5'd12}: glyph_row = 32'h01fffe00;
            {3'd0, 5'd13}: glyph_row = 32'h01fffe00;
            {3'd0, 5'd14}: glyph_row = 32'h00000000;
            {3'd0, 5'd15}: glyph_row = 32'h00000000;
            {3'd0, 5'd16}: glyph_row = 32'h3ffffff0;
            {3'd0, 5'd17}: glyph_row = 32'h3ffffff0;
            {3'd0, 5'd18}: glyph_row = 32'h38000030;
            {3'd0, 5'd19}: glyph_row = 32'h38000030;
            {3'd0, 5'd20}: glyph_row = 32'h003ff000;
            {3'd0, 5'd21}: glyph_row = 32'h00387000;
            {3'd0, 5'd22}: glyph_row = 32'h00707000;
            {3'd0, 5'd23}: glyph_row = 32'h00707000;
            {3'd0, 5'd24}: glyph_row = 32'h00707030;
            {3'd0, 5'd25}: glyph_row = 32'h00e07070;
            {3'd0, 5'd26}: glyph_row = 32'h0fc03ff0;
            {3'd0, 5'd27}: glyph_row = 32'h0f803fe0;
            {3'd0, 5'd28}: glyph_row = 32'h0e000000;
            {3'd0, 5'd29}: glyph_row = 32'h00000000;
            {3'd0, 5'd30}: glyph_row = 32'h00000000;
            {3'd0, 5'd31}: glyph_row = 32'h00000000;
            // 第1字：度
            {3'd1, 5'd 0}: glyph_row = 32'h00000000;
            {3'd1, 5'd 1}: glyph_row = 32'h00000000;
            {3'd1, 5'd 2}: glyph_row = 32'h0001c000;
            {3'd1, 5'd 3}: glyph_row = 32'h0000c000;
            {3'd1, 5'd 4}: glyph_row = 32'h0000e000;
            {3'd1, 5'd 5}: glyph_row = 32'h07fffff0;
            {3'd1, 5'd 6}: glyph_row = 32'h07fffff0;
            {3'd1, 5'd 7}: glyph_row = 32'h06000200;
            {3'd1, 5'd 8}: glyph_row = 32'h06060600;
            {3'd1, 5'd 9}: glyph_row = 32'h06060600;
            {3'd1, 5'd10}: glyph_row = 32'h066e0720;
            {3'd1, 5'd11}: glyph_row = 32'h06fffff0;
            {3'd1, 5'd12}: glyph_row = 32'h060e0700;
            {3'd1, 5'd13}: glyph_row = 32'h06060600;
            {3'd1, 5'd14}: glyph_row = 32'h06060600;
            {3'd1, 5'd15}: glyph_row = 32'h0607fe00;
            {3'd1, 5'd16}: glyph_row = 32'h0607fe00;
            {3'd1, 5'd17}: glyph_row = 32'h06000000;
            {3'd1, 5'd18}: glyph_row = 32'h067fff80;
            {3'd1, 5'd19}: glyph_row = 32'h067fff80;
            {3'd1, 5'd20}: glyph_row = 32'h06060700;
            {3'd1, 5'd21}: glyph_row = 32'h0e070600;
            {3'd1, 5'd22}: glyph_row = 32'h0c030c00;
            {3'd1, 5'd23}: glyph_row = 32'h0c01d800;
            {3'd1, 5'd24}: glyph_row = 32'h0c00f000;
            {3'd1, 5'd25}: glyph_row = 32'h1c01f800;
            {3'd1, 5'd26}: glyph_row = 32'h180fffc0;
            {3'd1, 5'd27}: glyph_row = 32'h19fe07f8;
            {3'd1, 5'd28}: glyph_row = 32'h00f00078;
            {3'd1, 5'd29}: glyph_row = 32'h00000000;
            {3'd1, 5'd30}: glyph_row = 32'h00000000;
            {3'd1, 5'd31}: glyph_row = 32'h00000000;
            // 第2字：调
            {3'd2, 5'd 0}: glyph_row = 32'h00000000;
            {3'd2, 5'd 1}: glyph_row = 32'h00000000;
            {3'd2, 5'd 2}: glyph_row = 32'h00000000;
            {3'd2, 5'd 3}: glyph_row = 32'h0307fff8;
            {3'd2, 5'd 4}: glyph_row = 32'h0387fff8;
            {3'd2, 5'd 5}: glyph_row = 32'h03860018;
            {3'd2, 5'd 6}: glyph_row = 32'h01c60c18;
            {3'd2, 5'd 7}: glyph_row = 32'h00860c18;
            {3'd2, 5'd 8}: glyph_row = 32'h00060c18;
            {3'd2, 5'd 9}: glyph_row = 32'h00067f98;
            {3'd2, 5'd10}: glyph_row = 32'h00067f98;
            {3'd2, 5'd11}: glyph_row = 32'h3f860c18;
            {3'd2, 5'd12}: glyph_row = 32'h3f860c18;
            {3'd2, 5'd13}: glyph_row = 32'h01867f98;
            {3'd2, 5'd14}: glyph_row = 32'h01867fd8;
            {3'd2, 5'd15}: glyph_row = 32'h01860018;
            {3'd2, 5'd16}: glyph_row = 32'h01860018;
            {3'd2, 5'd17}: glyph_row = 32'h01867f98;
            {3'd2, 5'd18}: glyph_row = 32'h01867f98;
            {3'd2, 5'd19}: glyph_row = 32'h01b66198;
            {3'd2, 5'd20}: glyph_row = 32'h01f66198;
            {3'd2, 5'd21}: glyph_row = 32'h01e66198;
            {3'd2, 5'd22}: glyph_row = 32'h03ce7f98;
            {3'd2, 5'd23}: glyph_row = 32'h038c7f98;
            {3'd2, 5'd24}: glyph_row = 32'h030c0018;
            {3'd2, 5'd25}: glyph_row = 32'h001c0038;
            {3'd2, 5'd26}: glyph_row = 32'h003801f8;
            {3'd2, 5'd27}: glyph_row = 32'h003801f0;
            {3'd2, 5'd28}: glyph_row = 32'h001000e0;
            {3'd2, 5'd29}: glyph_row = 32'h00000000;
            {3'd2, 5'd30}: glyph_row = 32'h00000000;
            {3'd2, 5'd31}: glyph_row = 32'h00000000;
            // 第3字：节
            {3'd3, 5'd 0}: glyph_row = 32'h00000000;
            {3'd3, 5'd 1}: glyph_row = 32'h00000000;
            {3'd3, 5'd 2}: glyph_row = 32'h00000000;
            {3'd3, 5'd 3}: glyph_row = 32'h00381800;
            {3'd3, 5'd 4}: glyph_row = 32'h00381800;
            {3'd3, 5'd 5}: glyph_row = 32'h00381800;
            {3'd3, 5'd 6}: glyph_row = 32'h1ffffff8;
            {3'd3, 5'd 7}: glyph_row = 32'h1ffffff8;
            {3'd3, 5'd 8}: glyph_row = 32'h1c383c38;
            {3'd3, 5'd 9}: glyph_row = 32'h00381800;
            {3'd3, 5'd10}: glyph_row = 32'h00381800;
            {3'd3, 5'd11}: glyph_row = 32'h00381800;
            {3'd3, 5'd12}: glyph_row = 32'h00000000;
            {3'd3, 5'd13}: glyph_row = 32'h0fffffe0;
            {3'd3, 5'd14}: glyph_row = 32'h0fffffe0;
            {3'd3, 5'd15}: glyph_row = 32'h000e00e0;
            {3'd3, 5'd16}: glyph_row = 32'h000e0060;
            {3'd3, 5'd17}: glyph_row = 32'h000e0060;
            {3'd3, 5'd18}: glyph_row = 32'h000e0060;
            {3'd3, 5'd19}: glyph_row = 32'h000e0060;
            {3'd3, 5'd20}: glyph_row = 32'h000e00e0;
            {3'd3, 5'd21}: glyph_row = 32'h000e00e0;
            {3'd3, 5'd22}: glyph_row = 32'h000e00e0;
            {3'd3, 5'd23}: glyph_row = 32'h000e0fc0;
            {3'd3, 5'd24}: glyph_row = 32'h000e0fc0;
            {3'd3, 5'd25}: glyph_row = 32'h000e0700;
            {3'd3, 5'd26}: glyph_row = 32'h000e0000;
            {3'd3, 5'd27}: glyph_row = 32'h000e0000;
            {3'd3, 5'd28}: glyph_row = 32'h000e0000;
            {3'd3, 5'd29}: glyph_row = 32'h000e0000;
            {3'd3, 5'd30}: glyph_row = 32'h00000000;
            {3'd3, 5'd31}: glyph_row = 32'h00000000;
            // 第4字：音
            {3'd4, 5'd 0}: glyph_row = 32'h00000000;
            {3'd4, 5'd 1}: glyph_row = 32'h00000000;
            {3'd4, 5'd 2}: glyph_row = 32'h00020000;
            {3'd4, 5'd 3}: glyph_row = 32'h00070000;
            {3'd4, 5'd 4}: glyph_row = 32'h00070000;
            {3'd4, 5'd 5}: glyph_row = 32'h00070000;
            {3'd4, 5'd 6}: glyph_row = 32'h1fffffc0;
            {3'd4, 5'd 7}: glyph_row = 32'h0fffffc0;
            {3'd4, 5'd 8}: glyph_row = 32'h00401800;
            {3'd4, 5'd 9}: glyph_row = 32'h00e01c00;
            {3'd4, 5'd10}: glyph_row = 32'h00601800;
            {3'd4, 5'd11}: glyph_row = 32'h00703800;
            {3'd4, 5'd12}: glyph_row = 32'h00203000;
            {3'd4, 5'd13}: glyph_row = 32'h3ffffff0;
            {3'd4, 5'd14}: glyph_row = 32'h3ffffff0;
            {3'd4, 5'd15}: glyph_row = 32'h00000000;
            {3'd4, 5'd16}: glyph_row = 32'h00000000;
            {3'd4, 5'd17}: glyph_row = 32'h03ffff00;
            {3'd4, 5'd18}: glyph_row = 32'h03ffff00;
            {3'd4, 5'd19}: glyph_row = 32'h03800700;
            {3'd4, 5'd20}: glyph_row = 32'h03800700;
            {3'd4, 5'd21}: glyph_row = 32'h03800700;
            {3'd4, 5'd22}: glyph_row = 32'h03ffff00;
            {3'd4, 5'd23}: glyph_row = 32'h03ffff00;
            {3'd4, 5'd24}: glyph_row = 32'h03800700;
            {3'd4, 5'd25}: glyph_row = 32'h03800700;
            {3'd4, 5'd26}: glyph_row = 32'h03ffff00;
            {3'd4, 5'd27}: glyph_row = 32'h03ffff00;
            {3'd4, 5'd28}: glyph_row = 32'h03800700;
            {3'd4, 5'd29}: glyph_row = 32'h03800700;
            {3'd4, 5'd30}: glyph_row = 32'h00000000;
            {3'd4, 5'd31}: glyph_row = 32'h00000000;
            // 第5字：量
            {3'd5, 5'd 0}: glyph_row = 32'h00000000;
            {3'd5, 5'd 1}: glyph_row = 32'h00000000;
            {3'd5, 5'd 2}: glyph_row = 32'h00000000;
            {3'd5, 5'd 3}: glyph_row = 32'h00000000;
            {3'd5, 5'd 4}: glyph_row = 32'h01ffff80;
            {3'd5, 5'd 5}: glyph_row = 32'h01800180;
            {3'd5, 5'd 6}: glyph_row = 32'h01800180;
            {3'd5, 5'd 7}: glyph_row = 32'h01ffff80;
            {3'd5, 5'd 8}: glyph_row = 32'h01800180;
            {3'd5, 5'd 9}: glyph_row = 32'h01800180;
            {3'd5, 5'd10}: glyph_row = 32'h01ffff80;
            {3'd5, 5'd11}: glyph_row = 32'h00000000;
            {3'd5, 5'd12}: glyph_row = 32'h1ffffff8;
            {3'd5, 5'd13}: glyph_row = 32'h1ffffff8;
            {3'd5, 5'd14}: glyph_row = 32'h00000000;
            {3'd5, 5'd15}: glyph_row = 32'h01ffff80;
            {3'd5, 5'd16}: glyph_row = 32'h03ffffc0;
            {3'd5, 5'd17}: glyph_row = 32'h038181c0;
            {3'd5, 5'd18}: glyph_row = 32'h01ffffc0;
            {3'd5, 5'd19}: glyph_row = 32'h03ffffc0;
            {3'd5, 5'd20}: glyph_row = 32'h038181c0;
            {3'd5, 5'd21}: glyph_row = 32'h03ffffc0;
            {3'd5, 5'd22}: glyph_row = 32'h01ffff80;
            {3'd5, 5'd23}: glyph_row = 32'h00018000;
            {3'd5, 5'd24}: glyph_row = 32'h03ffffc0;
            {3'd5, 5'd25}: glyph_row = 32'h03ffffc0;
            {3'd5, 5'd26}: glyph_row = 32'h00018000;
            {3'd5, 5'd27}: glyph_row = 32'h1ffffff8;
            {3'd5, 5'd28}: glyph_row = 32'h1ffffff8;
            {3'd5, 5'd29}: glyph_row = 32'h00000000;
            {3'd5, 5'd30}: glyph_row = 32'h00000000;
            {3'd5, 5'd31}: glyph_row = 32'h00000000;
            // FONT_END
            default: glyph_row = 32'h00000000;
            endcase
        end
    endfunction

    // ---------- 像素命中判断 ----------
    // 输入隔离：亮度模式关闭或不在面板行内时列号清零，命中判断、字形ROM与格号比较链
    // 输入保持不变，不随像素翻转（此时panel_hit为0，输出直通rgb_in，结果不受影响）
    wire        in_panel_y = (line_y >= PANEL_Y) && (line_y < PANEL_Y + PANEL_H);
    wire [11:0] px = (enable_frame && in_panel_y) ? {2'b00, pixel_x} : 12'd0;

    wire in_panel = (px >= PANEL_X) && (px < PANEL_X + PANEL_W) &&
                    (line_y >= PANEL_Y) && (line_y < PANEL_Y + PANEL_H);

    // 文字
    wire [11:0] text_x   = px - TEXT_X;
    wire [11:0] text_row = line_y - TEXT_Y;
    wire in_text = (px >= TEXT_X) && (px < TEXT_X + TEXT_W) &&
                   (line_y >= TEXT_Y) && (line_y < TEXT_Y + GLYPH);
    // 音量标题：第0/1格（亮/度）换成第4/5字（音/量）
    wire [2:0]  char_id  = (title_frame && !text_x[6]) ? {2'b10, text_x[5]} : {1'b0, text_x[6:5]};
    wire [31:0] row_bits = glyph_row({char_id, text_row[4:0]});
    wire text_hit = in_text && row_bits[5'd31 - text_x[4:0]];

    // 进度条：格号 = (x-BAR_X)/20，格内偏移 <18 为格子，其余为间隙
    wire [11:0] bar_x  = px - BAR_X;
    wire in_bar = (px >= BAR_X) && (px < BAR_X + BAR_W) &&
                  (line_y >= BAR_Y) && (line_y < BAR_Y + BAR_H);
    reg  [4:0] cell_idx;
    reg  [4:0] cell_off;
    integer k;
    always @(*) begin
        // 常数除法用比较链展开（16格），避免综合出除法器
        cell_idx = 5'd0;
        cell_off = bar_x[4:0];
        for (k = 1; k < 16; k = k + 1) begin
            if (bar_x >= k * CELL_PITCH) begin
                cell_idx = k;
                cell_off = bar_x - k * CELL_PITCH;
            end
        end
    end
    wire cell_hit = in_bar && (cell_off < CELL_W);
    wire cell_on  = (cell_idx <= {1'b0, level_frame});

    wire show      = enable_frame && de;
    wire panel_hit = show && in_panel;

    // 面板背景：原图亮度降到1/4，突出文字与进度条
    wire [23:0] panel_rgb = {2'b00, rgb_in[23:18], 2'b00, rgb_in[15:10], 2'b00, rgb_in[7:2]};

    // 颜色随标题在帧边界切换：亮度金黄、音量青蓝
    wire [23:0] text_rgb = title_frame ? VOL_TEXT_COLOR : TEXT_COLOR;
    wire [23:0] on_rgb   = title_frame ? VOL_ON_COLOR   : ON_COLOR;

    assign rgb_out = !panel_hit ? rgb_in     :
                     text_hit   ? text_rgb   :
                     cell_hit   ? (cell_on ? on_rgb : OFF_COLOR) :
                                  panel_rgb;
    assign bar_active = panel_hit;
endmodule
