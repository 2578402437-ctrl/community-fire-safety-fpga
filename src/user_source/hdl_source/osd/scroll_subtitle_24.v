// ============================================================================
// 文件名称：scroll_subtitle_24.v
// 模块名称：scroll_subtitle_24
// 功能描述：分栏目滚动字幕叠加层
// 目标器件：安路 EG4S20BG256
// ============================================================================
`timescale 1ns/1ps

// 分栏目滚动字幕（24位RGB叠加层）。
// 在导航栏下方画一条半透明暗色字幕条，按 sentence（= 消防员已到达的栏目）选择4句之一，
// 32×32汉字从右向左循环滚动；句子一变就从右侧重新进入。
// 与其他叠加层相同：像素路径不增加流水线延迟，不影响HDMI数据岛调度器依赖的video_x/video_de对齐。
// 字库存同步读ROM（1拍延迟），按"下一个像素"的列号提前一拍给地址，行消隐期预取下一行第0列。
// 行号由本地vsync/de重建；滚动位置、句子与使能都只在帧消隐期更新，画面不撕裂。
// 字库与句子表由 tools/convert/make_nav_assets.py 生成，改字幕文字时重跑该脚本。
module scroll_subtitle_24 #(
    parameter integer H_ACTIVE    = 640,        // 有效行宽
    parameter integer BAND_Y      = 52,         // 字幕条起始行
    parameter integer BAND_H      = 40,         // 字幕条高度
    parameter integer TEXT_Y      = 56,         // 文字起始行（字幕条内上下各留4行）
    parameter integer SCROLL_STEP = 2,          // 每帧左移像素数：2px@60Hz
    parameter [23:0]  TEXT_COLOR  = 24'hFFD200, // 文字颜色（金黄）
    parameter         GLYPH_FILE  = "../../../user_source/hdl_source/rom/subtitle_glyph32.hex"
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [9:0]  pixel_x,
    input  wire        enable,       // 1=显示字幕；0=隐藏（帧边界生效，并让字幕重新从右侧进入）
    input  wire [1:0]  sentence,     // 句子编号0~3（帧边界锁存）
    output wire [23:0] rgb_out,
    output wire        subtitle_active
);
    localparam integer GLYPH = 32;              // 点阵边长

    // SENT_BEGIN
    localparam integer NUM_GLYPHS = 45;   // 字库字数：规范充电不飞线，人走断保平安公共区域守消防全记心间用无小事随手火灾生命通道严禁占持畅就是护

    // 每句字数
    function [4:0] sent_len;
        input [1:0] s;
        begin
            case (s)
            2'd0: sent_len = 5'd15;   // 规范充电不飞线，人走断电保平安
            2'd1: sent_len = 5'd15;   // 公共区域守规范，消防安全记心间
            2'd2: sent_len = 5'd15;   // 用电安全无小事，随手断电防火灾
            2'd3: sent_len = 5'd19;   // 生命通道严禁占用，保持畅通就是守护生命
            default: sent_len = 5'd0;
            endcase
        end
    endfunction

    // {句号, 字序} → 字库编号
    function [5:0] sent_char;
        input [6:0] addr;
        begin
            case (addr)
            {2'd0, 5'd 0}: sent_char = 6'd 0;   // 规
            {2'd0, 5'd 1}: sent_char = 6'd 1;   // 范
            {2'd0, 5'd 2}: sent_char = 6'd 2;   // 充
            {2'd0, 5'd 3}: sent_char = 6'd 3;   // 电
            {2'd0, 5'd 4}: sent_char = 6'd 4;   // 不
            {2'd0, 5'd 5}: sent_char = 6'd 5;   // 飞
            {2'd0, 5'd 6}: sent_char = 6'd 6;   // 线
            {2'd0, 5'd 7}: sent_char = 6'd 7;   // ，
            {2'd0, 5'd 8}: sent_char = 6'd 8;   // 人
            {2'd0, 5'd 9}: sent_char = 6'd 9;   // 走
            {2'd0, 5'd10}: sent_char = 6'd10;   // 断
            {2'd0, 5'd11}: sent_char = 6'd 3;   // 电
            {2'd0, 5'd12}: sent_char = 6'd11;   // 保
            {2'd0, 5'd13}: sent_char = 6'd12;   // 平
            {2'd0, 5'd14}: sent_char = 6'd13;   // 安
            {2'd1, 5'd 0}: sent_char = 6'd14;   // 公
            {2'd1, 5'd 1}: sent_char = 6'd15;   // 共
            {2'd1, 5'd 2}: sent_char = 6'd16;   // 区
            {2'd1, 5'd 3}: sent_char = 6'd17;   // 域
            {2'd1, 5'd 4}: sent_char = 6'd18;   // 守
            {2'd1, 5'd 5}: sent_char = 6'd 0;   // 规
            {2'd1, 5'd 6}: sent_char = 6'd 1;   // 范
            {2'd1, 5'd 7}: sent_char = 6'd 7;   // ，
            {2'd1, 5'd 8}: sent_char = 6'd19;   // 消
            {2'd1, 5'd 9}: sent_char = 6'd20;   // 防
            {2'd1, 5'd10}: sent_char = 6'd13;   // 安
            {2'd1, 5'd11}: sent_char = 6'd21;   // 全
            {2'd1, 5'd12}: sent_char = 6'd22;   // 记
            {2'd1, 5'd13}: sent_char = 6'd23;   // 心
            {2'd1, 5'd14}: sent_char = 6'd24;   // 间
            {2'd2, 5'd 0}: sent_char = 6'd25;   // 用
            {2'd2, 5'd 1}: sent_char = 6'd 3;   // 电
            {2'd2, 5'd 2}: sent_char = 6'd13;   // 安
            {2'd2, 5'd 3}: sent_char = 6'd21;   // 全
            {2'd2, 5'd 4}: sent_char = 6'd26;   // 无
            {2'd2, 5'd 5}: sent_char = 6'd27;   // 小
            {2'd2, 5'd 6}: sent_char = 6'd28;   // 事
            {2'd2, 5'd 7}: sent_char = 6'd 7;   // ，
            {2'd2, 5'd 8}: sent_char = 6'd29;   // 随
            {2'd2, 5'd 9}: sent_char = 6'd30;   // 手
            {2'd2, 5'd10}: sent_char = 6'd10;   // 断
            {2'd2, 5'd11}: sent_char = 6'd 3;   // 电
            {2'd2, 5'd12}: sent_char = 6'd20;   // 防
            {2'd2, 5'd13}: sent_char = 6'd31;   // 火
            {2'd2, 5'd14}: sent_char = 6'd32;   // 灾
            {2'd3, 5'd 0}: sent_char = 6'd33;   // 生
            {2'd3, 5'd 1}: sent_char = 6'd34;   // 命
            {2'd3, 5'd 2}: sent_char = 6'd35;   // 通
            {2'd3, 5'd 3}: sent_char = 6'd36;   // 道
            {2'd3, 5'd 4}: sent_char = 6'd37;   // 严
            {2'd3, 5'd 5}: sent_char = 6'd38;   // 禁
            {2'd3, 5'd 6}: sent_char = 6'd39;   // 占
            {2'd3, 5'd 7}: sent_char = 6'd25;   // 用
            {2'd3, 5'd 8}: sent_char = 6'd 7;   // ，
            {2'd3, 5'd 9}: sent_char = 6'd11;   // 保
            {2'd3, 5'd10}: sent_char = 6'd40;   // 持
            {2'd3, 5'd11}: sent_char = 6'd41;   // 畅
            {2'd3, 5'd12}: sent_char = 6'd35;   // 通
            {2'd3, 5'd13}: sent_char = 6'd42;   // 就
            {2'd3, 5'd14}: sent_char = 6'd43;   // 是
            {2'd3, 5'd15}: sent_char = 6'd18;   // 守
            {2'd3, 5'd16}: sent_char = 6'd44;   // 护
            {2'd3, 5'd17}: sent_char = 6'd33;   // 生
            {2'd3, 5'd18}: sent_char = 6'd34;   // 命
            default: sent_char = 6'd0;
            endcase
        end
    endfunction
    // SENT_END

    // ---------- 行号重建（与各叠加层一致）----------
    reg [11:0] line_y;
    reg de_q;
    reg vs_q;
    wire frame_start = vs_q && !vsync;

    // ---------- 帧级状态：滚动位置、句子与使能 ----------
    reg [11:0] scroll_pos;   // 0时文字左边沿在x=H_ACTIVE（刚好在屏幕右侧外）
    reg        enable_frame;
    reg [1:0]  sent_frame;

    wire [11:0] text_w     = {2'b00, sent_len(sent_frame), 5'd0};   // 句宽 = 字数×32
    wire [11:0] scroll_max = H_ACTIVE + text_w;                    // 文字从完全在右侧外到完全移出左侧

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y <= 12'd0;
            de_q <= 1'b0;
            vs_q <= 1'b1;
            scroll_pos <= 12'd0;
            enable_frame <= 1'b0;
            sent_frame <= 2'd0;
        end else begin
            de_q <= de;
            vs_q <= vsync;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;

            if (frame_start) begin
                enable_frame <= enable;
                sent_frame   <= sentence;
                if (!enable || sentence != sent_frame)
                    scroll_pos <= 12'd0;
                else if (scroll_pos + SCROLL_STEP >= scroll_max)
                    scroll_pos <= 12'd0;
                else
                    scroll_pos <= scroll_pos + SCROLL_STEP;
            end
        end
    end

    // ---------- 下一个像素的字库取数 ----------
    // 输入隔离：字幕关闭或不在文字行内时列号清零，取数地址不随像素翻转
    wire        in_band   = (line_y >= BAND_Y) && (line_y < BAND_Y + BAND_H);
    wire        in_text_y = (line_y >= TEXT_Y) && (line_y < TEXT_Y + GLYPH);
    wire        fetch_en  = enable_frame && in_text_y;
    wire [10:0] next_x    = (fetch_en && de) ? ({1'b0, pixel_x} + 11'd1) : 11'd0;
    // 文字坐标 = 屏幕x + scroll_pos - H_ACTIVE，落在[0, text_w)内即在文字区
    wire [11:0] text_sum  = {1'b0, next_x} + scroll_pos;
    wire        in_text_x = (text_sum >= H_ACTIVE) && (text_sum < scroll_max);
    wire [11:0] text_x    = text_sum - H_ACTIVE;
    wire [11:0] text_row  = line_y - TEXT_Y;
    wire [5:0]  gcode     = sent_char({sent_frame, text_x[9:5]});
    wire        glyph_fetch = fetch_en && in_text_x;
    wire [10:0] rom_addr  = glyph_fetch ? {gcode, text_row[4:0]} : 11'd0;

    // ---------- 字库ROM：{字库编号, 行号} → 32位行点阵（bit31为最左像素），同步读 ----------
    reg [31:0] glyph_mem [0:NUM_GLYPHS*GLYPH-1];
    reg [31:0] glyph_q;
    initial begin
        $readmemh(GLYPH_FILE, glyph_mem);
    end
    // 读使能：只在取数时读ROM（glyph_q只在hit_q时被使用）
    always @(posedge clk) begin
        if (glyph_fetch)
            glyph_q <= glyph_mem[rom_addr];
    end

    reg       hit_q;
    reg [4:0] bit_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hit_q <= 1'b0;
            bit_q <= 5'd0;
        end else begin
            hit_q <= glyph_fetch;
            bit_q <= text_x[4:0];
        end
    end

    // ---------- 当前像素命中判断 ----------
    wire text_hit  = hit_q && glyph_q[~bit_q];

    wire show      = enable_frame && de;
    wire band_hit  = show && in_band;
    wire pixel_hit = band_hit && text_hit;

    // 字幕条背景：原图亮度减半，既能看清文字又不完全遮住图片
    wire [23:0] band_rgb = {1'b0, rgb_in[23:17], 1'b0, rgb_in[15:9], 1'b0, rgb_in[7:1]};

    assign rgb_out = pixel_hit ? TEXT_COLOR :
                     band_hit  ? band_rgb   : rgb_in;
    assign subtitle_active = band_hit;
endmodule
