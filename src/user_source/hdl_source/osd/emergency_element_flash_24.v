// ============================================================================
// 文件名称：emergency_element_flash_24.v
// 模块名称：emergency_element_flash_24
// 功能描述：紧急场景警示元素闪烁与画面四周红框叠加层
// 目标器件：安路 EG4S20BG256
// ============================================================================
`timescale 1ns/1ps

// 紧急情况局部元素亮暗闪烁 + 画面四周红框闪烁（24位RGB叠加层）。
// 拨码紧急场景（SW1/SW2火警、SW3紧急疏散/地震报警）且对应SW*.BMP已真正显示时：
//   亮相：原图 + 画面四周BORDER像素红框；
//   暗相：红框熄灭，同时"三角警示牌边框 + 主标题"两处压暗；三角牌内部图案、背景、两侧面板不动。
//
// 区域：每张图一个三角环带 + 一个标题矩形，坐标由Desktop/SW*.bmp实测（见下方case表）。
//   外三角：行yt~yb内，|x-xc| <= ((y-ya)*K>>6) + MARGIN（K=半宽斜率*64）；
//   内三角：行yi_end及以上、外沿半宽>RING_W时，|x-xc| <= ((y-ya)*K>>6) - RING_W；
//   环带 = 外三角 - 内三角，即只包住三角牌的边框线条。
//   半宽只与行号有关，每行在消隐期算好边界并寄存，像素级只做比较，不占乘法时序。
// 压暗：区域内每个通道 c<KNEE 不变，否则 KNEE + ((c-KNEE)>>DIM_SHIFT)。
//   曲线连续，暗底几乎不变、亮的线条/文字明显变暗，区域边缘不会出现接缝。
// 节拍：默认每10帧翻转，60Hz下约3Hz（亮/暗各约0.17s），不超过3Hz光敏安全上限。
//   使能拉高后第一帧为亮相（即原图），之后进入暗相。
//
// 时序：与其他叠加层相同，rgb_out为组合输出，与输入de同拍对齐，
// 不增加像素流水线延迟。行号由本地vsync/de重建；使能、图片号、亮灭相位只在帧边界更新，
// 不会出现半帧闪烁。enable/img_sel为跨域同步来的多位信号，帧边界只接受连续两拍一致的值。
module emergency_element_flash_24 #(
    parameter integer H_ACTIVE      = 640,
    parameter integer V_ACTIVE      = 480,
    parameter integer TOGGLE_FRAMES = 10,   // 亮/暗各持续的帧数
    parameter integer BORDER        = 16,   // 画面四周红框宽度（像素）
    parameter [23:0]  BORDER_COLOR  = 24'hFF0000,
    parameter integer MARGIN        = 6,    // 三角形区域外扩余量（像素），包住外发光
    parameter integer KNEE          = 16,   // 压暗拐点：低于此值的通道不变
    parameter integer DIM_SHIFT     = 2     // 拐点以上部分右移位数（2=压到1/4）
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [9:0]  pixel_x,
    input  wire        enable,          // SW*.BMP已显示（已同步到本时钟域）
    input  wire [1:0]  img_sel,         // 0=SW1 1=SW2 2=SW3 3=SW12（已同步到本时钟域）
    output wire [23:0] rgb_out,
    output wire        flash_active
);
    // ---------- 行号重建（与各叠加层一致）----------
    reg [11:0] line_y;
    reg de_q;
    reg vs_q;
    wire frame_start = vs_q && !vsync;

    // ---------- 跨域输入打一拍，用于稳定性判断 ----------
    reg       enable_q;
    reg [1:0] img_sel_q;
    wire      in_stable = (enable_q == enable) && (img_sel_q == img_sel);

    // ---------- 帧级状态：使能/图片号锁存与闪烁相位 ----------
    reg [4:0] frame_cnt;
    reg       en_frame;      // 本帧是否处于紧急闪烁
    reg [1:0] sel_frame;     // 本帧对应的图片
    reg       dim_on;        // 本帧是否为暗相

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y    <= 12'd0;
            de_q      <= 1'b0;
            vs_q      <= 1'b1;
            enable_q  <= 1'b0;
            img_sel_q <= 2'd0;
            frame_cnt <= 5'd0;
            en_frame  <= 1'b0;
            sel_frame <= 2'd0;
            dim_on    <= 1'b0;
        end else begin
            de_q      <= de;
            vs_q      <= vsync;
            enable_q  <= enable;
            img_sel_q <= img_sel;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;

            if (frame_start && in_stable) begin
                en_frame <= enable;
                if (!enable || !en_frame || (img_sel != sel_frame)) begin
                    // 退出、刚进入或换图：本帧显示原图（亮相），相位从头计
                    frame_cnt <= 5'd0;
                    dim_on    <= 1'b0;
                end else if (frame_cnt >= TOGGLE_FRAMES - 1) begin
                    frame_cnt <= 5'd0;
                    dim_on    <= ~dim_on;
                end else begin
                    frame_cnt <= frame_cnt + 1'b1;
                end
                sel_frame <= img_sel;
            end
        end
    end

    // ---------- 每张图的区域参数（坐标来自SW*.bmp实测，640x480）----------
    // xc/ya/K：三角形中心x、外沿延长线交点y、半宽斜率*64；yt/yb：外三角起止行
    // ring_w/yi_end：边框环带宽度（外沿向内）、内三角止行（底边线条上沿）
    // tx0/ty0/tx1/ty1：主标题矩形，右/下为开区间
    reg [9:0] xc, ya, yt, yb, yi_end, tx0, ty0, tx1, ty1;
    reg [5:0] k_slope;
    reg [4:0] ring_w;
    always @(*) begin
        case (sel_frame)
            2'd0: begin  // SW1.bmp：FIRE ALERT
                xc = 10'd320; ya = 10'd39; yt = 10'd52; yb = 10'd318; k_slope = 6'd32;
                ring_w = 5'd16; yi_end = 10'd298;
                tx0 = 10'd150; ty0 = 10'd330; tx1 = 10'd492; ty1 = 10'd392;
            end
            2'd1: begin  // SW2.bmp：EARTHQUAKE ALERT
                xc = 10'd317; ya = 10'd78; yt = 10'd66; yb = 10'd316; k_slope = 6'd36;
                ring_w = 5'd12; yi_end = 10'd296;
                tx0 = 10'd165; ty0 = 10'd325; tx1 = 10'd475; ty1 = 10'd381;
            end
            2'd2: begin  // SW3.bmp：EMERGENCY EVACUATION
                xc = 10'd320; ya = 10'd46; yt = 10'd56; yb = 10'd344; k_slope = 6'd31;
                ring_w = 5'd18; yi_end = 10'd302;
                tx0 = 10'd90;  ty0 = 10'd360; tx1 = 10'd552; ty1 = 10'd416;
            end
            default: begin  // SW12.bmp：EARTHQUAKE + FIRE ALERT
                xc = 10'd320; ya = 10'd15; yt = 10'd6;  yb = 10'd326; k_slope = 6'd38;
                ring_w = 5'd10; yi_end = 10'd314;
                tx0 = 10'd176; ty0 = 10'd333; tx1 = 10'd466; ty1 = 10'd373;
            end
        endcase
    end

    // ---------- 行级预计算：内外三角左右边界与行内标志，寄存一拍 ----------
    // line_y在de下降沿后更新，到下一行de到来前有整段行消隐，寄存值早已稳定。
    wire [9:0]  ly      = line_y[9:0];
    wire [9:0]  dy      = (ly > ya) ? (ly - ya) : 10'd0;
    wire [15:0] hw_mul  = dy * k_slope;
    wire [10:0] hw      = {1'b0, hw_mul[15:6]} + MARGIN;
    wire [11:0] tri_l_c = {2'b00, xc} - {1'b0, hw};   // 可能为负，最高位为符号
    wire [11:0] tri_r_c = {2'b00, xc} + {1'b0, hw};
    wire [9:0]  base_hw = hw_mul[15:6];
    wire [9:0]  in_hw   = base_hw - ring_w;            // 仅在base_hw>ring_w时使用
    wire [9:0]  in_l_c  = xc - in_hw;
    wire [9:0]  in_r_c  = xc + in_hw;

    reg [11:0] tri_l, tri_r;
    reg [9:0]  in_l, in_r;
    reg        tri_row, in_row, title_row, bdr_row;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tri_l     <= 12'd0;
            tri_r     <= 12'd0;
            in_l      <= 10'd0;
            in_r      <= 10'd0;
            tri_row   <= 1'b0;
            in_row    <= 1'b0;
            title_row <= 1'b0;
            bdr_row   <= 1'b0;
        end else begin
            tri_l     <= tri_l_c;
            tri_r     <= tri_r_c;
            in_l      <= in_l_c;
            in_r      <= in_r_c;
            tri_row   <= (line_y >= {2'b00, yt}) && (line_y <= {2'b00, yb});
            in_row    <= (line_y <= {2'b00, yi_end}) && (base_hw > {5'd0, ring_w});
            bdr_row   <= (line_y < BORDER) || (line_y >= V_ACTIVE - BORDER);
            title_row <= (line_y >= {2'b00, ty0}) && (line_y <  {2'b00, ty1});
        end
    end

    // ---------- 像素级区域判断（只做比较）----------
    wire [11:0] px      = {2'b00, pixel_x};
    wire        x_ge_l  = tri_l[11] || (px >= tri_l);   // 左边界为负时恒成立
    wire        in_outer = tri_row && x_ge_l && (px <= tri_r);
    wire        in_inner = in_row && (pixel_x >= in_l) && (pixel_x <= in_r);
    wire        in_tri  = in_outer && !in_inner;        // 只保留三角牌边框环带
    wire        in_title = title_row && (pixel_x >= tx0) && (pixel_x < tx1);

    // ---------- 压暗曲线 ----------
    function [7:0] dim_ch;
        input [7:0] c;
        begin
            if (c < KNEE)
                dim_ch = c;
            else
                dim_ch = KNEE + ((c - KNEE) >> DIM_SHIFT);
        end
    endfunction

    wire in_border = bdr_row || (pixel_x < BORDER) || (pixel_x >= H_ACTIVE - BORDER);

    wire show_dim    = en_frame &&  dim_on && de && (in_tri || in_title);
    wire show_border = en_frame && !dim_on && de && in_border;   // 与元素同步：亮相红框亮，暗相熄灭
    assign rgb_out      = show_border ? BORDER_COLOR :
                          show_dim    ? {dim_ch(rgb_in[23:16]), dim_ch(rgb_in[15:8]), dim_ch(rgb_in[7:0])}
                                      : rgb_in;
    assign flash_active = show_dim || show_border;

endmodule
