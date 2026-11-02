// ============================================================================
// 文件名称：fireman_nav_bar_24.v
// 模块名称：fireman_nav_bar_24
// 功能描述：消防员行走导航栏叠加层（屏幕顶部四个栏目）
// 目标器件：安路 EG4S20BG256
// ============================================================================
`timescale 1ns/1ps

// 消防员行走导航栏（24位RGB叠加层，屏幕顶部）。
// 顶部导航栏：白底只铺在标签那一条（第BG_Y行起），小人那几行透出原图；四个栏目标签各占160像素宽：充电桩安全 / 公共区域安全 / 家庭用电安全 / 消防通道安全，
// 栏目编号 = 浏览图片编号0~3。标签上方有一个24×32像素的消防员小人。
// 切图请求一发出，target_idx 就变成目标栏目；小人每帧走1像素，走到目标栏目中央（一格160像素约2.7秒@60Hz），
// 到达后 cur_idx 才更新：选中标签变红并加下划线，滚动字幕据此换成该栏目的内容。
// 行走时按 0→1→2→1 循环播放侧面动作帧，站定后换成第3帧（正面朝向屏幕）。
// 方向取环形最短路：相邻下一栏向右走（第4栏→第1栏从右边走出、左边走进），上一栏向左走（小人镜像），
// 隔一栏（缩略图选择）向右走两格。导航栏隐藏期间小人直接落在目标栏目，不走动。
//
// 时序：与其他叠加层相同，像素路径不增加流水线延迟，不影响HDMI数据岛调度器依赖的video_x/video_de对齐。
// 小人和标签ROM为同步读（1拍延迟），按"下一个像素"的列号提前一拍给地址，行消隐期预取下一行第0列。
// 行号由本地vsync/de重建；小人位置、栏目、使能只在帧边界更新，画面不撕裂。
// 小人与标签点阵由 tools/convert/make_nav_assets.py 生成；INIT文件路径相对 td_project/xxx_Runs/syn_1。
// hold=1（开机动画进行中）时整条导航栏不画，小人不走、不出脚步声；动画结束后若目标已变再按正常规则走过去。
module fireman_nav_bar_24 #(
    parameter integer H_ACTIVE    = 640,
    parameter integer BAND_H      = 52,          // 导航栏高度（从第0行起）
    parameter integer SPRITE_Y    = 2,           // 小人起始行（占32行）
    parameter integer LABEL_Y     = 34,          // 标签起始行（占16行）
    parameter integer ULINE_Y     = 50,          // 选中下划线起始行（占2行）
    parameter integer BG_Y        = 0,           // 白底起始行（BG_Y~BAND_H-1为白底，之前的行透出原图）
    parameter [23:0]  BG_COLOR    = 24'hFFFFFF,  // 导航栏背景（白）
    parameter [23:0]  SEL_COLOR   = 24'hD01818,  // 选中标签与下划线颜色（消防红）
    parameter [23:0]  LABEL_COLOR = 24'h404040,  // 未选中标签颜色（深灰）
    parameter         SPRITE_FILE = "../../../user_source/hdl_source/rom/nav_sprite_4bit.hex",
    parameter         LABEL_FILE  = "../../../user_source/hdl_source/rom/nav_label_1bit.hex"
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [9:0]  pixel_x,
    input  wire        enable,       // 1=显示导航栏；0=隐藏（帧边界生效）
    input  wire [1:0]  target_idx,   // 目标栏目（已同步到本时钟域，连续两帧一致才采纳）
    input  wire        hold,         // 1=开机动画进行中：不画、不走（帧边界生效）
    output wire [23:0] rgb_out,
    output reg  [1:0]  cur_idx,      // 小人已到达的栏目（帧边界更新），给滚动字幕选句子
    output reg         step_pulse,   // 落脚脉冲（1拍）：行走中动作切到迈腿帧时发出，驱动脚步声
    output reg         step_side,    // 本次落脚是哪只脚：0=迈前腿帧，1=迈后腿帧
    output wire        nav_active
);
    localparam integer SPR_W = 24;
    localparam integer SPR_H = 32;
    localparam integer LAB_H = 16;

    // LABEL_BEGIN
    // 每个标签的半宽（像素），标签以栏目中央为中心
    function [6:0] label_half;
        input [1:0] i;
        begin
            case (i)
            2'd0: label_half = 7'd44;   // 充电桩安全
            2'd1: label_half = 7'd53;   // 公共区域安全
            2'd2: label_half = 7'd53;   // 家庭用电安全
            2'd3: label_half = 7'd53;   // 消防通道安全
            default: label_half = 7'd0;
            endcase
        end
    endfunction
    // LABEL_END

    // 栏目中央列：80 + 160*i
    function [9:0] cell_center;
        input [1:0] i;
        begin
            case (i)
            2'd0: cell_center = 10'd80;
            2'd1: cell_center = 10'd240;
            2'd2: cell_center = 10'd400;
            default: cell_center = 10'd560;
            endcase
        end
    endfunction

    // 小人调色板：0=透明 1=红 2=黄 3=肤色 4=深灰 5=黑描边
    function [23:0] sprite_color;
        input [2:0] code;
        begin
            case (code)
            3'd1: sprite_color = 24'hD01818;
            3'd2: sprite_color = 24'hFFC800;
            3'd3: sprite_color = 24'hF5C08A;
            3'd4: sprite_color = 24'h2A2A2A;
            default: sprite_color = 24'h101010;
            endcase
        end
    endfunction

    // ---------- 行号重建（与各叠加层一致）----------
    reg [11:0] line_y;
    reg de_q;
    reg vs_q;
    wire frame_start = vs_q && !vsync;

    // ---------- 帧级状态：目标栏目、小人位置与朝向 ----------
    reg        enable_frame;
    reg [1:0]  tgt_q;        // 上一帧采样的target_idx
    reg [1:0]  tgt_frame;    // 已采纳的目标栏目
    reg [9:0]  pos;          // 小人中心列 0~H_ACTIVE-1（环形）
    reg        face_left;    // 1=面朝左（镜像）
    reg        walking;
    reg [4:0]  step_cnt;     // 行走帧计数，每8帧换一个动作

    wire [9:0]  tx       = cell_center(tgt_frame);
    // 环形距离 (tx - pos) mod H_ACTIVE，不超过半圈就向右走（恰好半圈也向右）
    wire [10:0] ring_raw = {1'b0, tx} - {1'b0, pos};
    wire [10:0] ring_dist = ring_raw[10] ? ring_raw + H_ACTIVE : ring_raw;
    wire        go_right = (ring_dist <= (H_ACTIVE / 2));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y       <= 12'd0;
            de_q         <= 1'b0;
            vs_q         <= 1'b1;
            enable_frame <= 1'b0;
            tgt_q        <= 2'd0;
            tgt_frame    <= 2'd0;
            pos          <= 10'd80;
            face_left    <= 1'b0;
            walking      <= 1'b0;
            step_cnt     <= 5'd0;
            cur_idx      <= 2'd0;
            step_pulse   <= 1'b0;
            step_side    <= 1'b0;
        end else begin
            de_q <= de;
            vs_q <= vsync;
            step_pulse <= 1'b0;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;

            if (frame_start) begin
                enable_frame <= enable && !hold;
                tgt_q <= target_idx;
                if (target_idx == tgt_q)
                    tgt_frame <= target_idx;

                if (!enable) begin
                    // 隐藏期间直接落位，重新显示时不补走
                    pos       <= tx;
                    cur_idx   <= tgt_frame;
                    walking   <= 1'b0;
                    face_left <= 1'b0;
                end else if (hold) begin
                    walking <= 1'b0;
                end else if (pos == tx) begin
                    cur_idx <= tgt_frame;
                    walking <= 1'b0;
                end else begin
                    walking   <= 1'b1;
                    step_cnt  <= step_cnt + 1'b1;
                    // 计数低4位回零时动作切到迈腿帧（step_cnt[4:3]=0或2），每16帧落一次脚
                    if (step_cnt[3:0] == 4'hF) begin
                        step_pulse <= 1'b1;
                        step_side  <= !step_cnt[4];
                    end
                    face_left <= !go_right;
                    if (go_right)
                        pos <= (pos == H_ACTIVE - 1) ? 10'd0 : pos + 1'b1;
                    else
                        pos <= (pos == 10'd0) ? H_ACTIVE - 1 : pos - 1'b1;
                end
            end
        end
    end

    // 动作帧：行走时按 0(迈前腿)→1(并腿)→2(迈后腿)→1 循环，站立时用第3帧（正面）
    wire [1:0] anim = !walking                ? 2'd3 :
                      (step_cnt[4:3] == 2'd3) ? 2'd1 : step_cnt[4:3];

    // ---------- 下一个像素的列号：有效期内为pixel_x+1，消隐期为下一行第0列 ----------
    wire        in_band = (line_y < BAND_H);
    wire        act     = enable_frame && in_band;
    wire [10:0] next_x  = de ? ({1'b0, pixel_x} + 11'd1) : 11'd0;

    // ---------- 小人ROM：{帧号, 行, 列} → 3位颜色编号，同步读 ----------
    wire        in_spr_y = (line_y >= SPRITE_Y) && (line_y < SPRITE_Y + SPR_H);
    wire [11:0] spr_rel  = line_y - SPRITE_Y;
    // 小人左边沿 = pos-12，列偏移按H_ACTIVE取模，支持从右边走出、左边走进
    wire [11:0] sdiff    = {1'b0, next_x} + (SPR_W / 2) - {2'b00, pos};       // -627 ~ 652
    wire [11:0] sx_w     = sdiff[11]           ? sdiff + H_ACTIVE :
                           (sdiff >= H_ACTIVE) ? sdiff - H_ACTIVE : sdiff;
    wire        in_spr_x = (sx_w < SPR_W);
    wire [4:0]  spr_col  = face_left ? (SPR_W - 1) - sx_w[4:0] : sx_w[4:0];
    // 输入隔离：不取数时地址清零，ROM地址不随像素翻转
    wire        spr_fetch = act && in_spr_y && in_spr_x;
    wire [11:0] spr_addr  = spr_fetch ? {anim, spr_rel[4:0], spr_col} : 12'd0;

    reg [3:0] spr_mem [0:4095];
    reg [3:0] spr_q;
    initial begin
        $readmemh(SPRITE_FILE, spr_mem);
    end
    // 读使能：只在取数时读ROM（spr_q只在spr_hit_q时被使用）
    always @(posedge clk) begin
        if (spr_fetch)
            spr_q <= spr_mem[spr_addr];
    end

    // ---------- 标签ROM：{行, 列/16} → 16位点阵，同步读 ----------
    wire        in_lab_y  = (line_y >= LABEL_Y) && (line_y < LABEL_Y + LAB_H);
    wire [11:0] lab_rel   = line_y - LABEL_Y;
    wire        lab_fetch = act && in_lab_y && (next_x < H_ACTIVE);
    wire [9:0]  lab_addr  = lab_fetch ? {lab_rel[3:0], next_x[9:4]} : 10'd0;

    reg [15:0] lab_mem [0:1023];
    reg [15:0] lab_q;
    initial begin
        $readmemh(LABEL_FILE, lab_mem);
    end
    // 读使能：只在取数时读ROM（lab_q只在lab_hit_q时被使用）
    always @(posedge clk) begin
        if (lab_fetch)
            lab_q <= lab_mem[lab_addr];
    end

    // ROM输出对应的有效标志，与ROM同拍延迟
    reg spr_hit_q;
    reg lab_hit_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spr_hit_q <= 1'b0;
            lab_hit_q <= 1'b0;
        end else begin
            spr_hit_q <= spr_fetch;
            lab_hit_q <= lab_fetch;
        end
    end

    // ---------- 当前像素命中判断 ----------
    wire [1:0] pix_cell = (pixel_x < 10'd160) ? 2'd0 :
                      (pixel_x < 10'd320) ? 2'd1 :
                      (pixel_x < 10'd480) ? 2'd2 : 2'd3;
    wire       sel  = (pix_cell == cur_idx);

    wire [9:0] sel_center = cell_center(cur_idx);
    wire [6:0] sel_half   = label_half(cur_idx);
    wire       in_ul_y    = (line_y >= ULINE_Y) && (line_y < ULINE_Y + 2);
    wire       ul_on      = in_ul_y && (pixel_x >= sel_center - sel_half) && (pixel_x < sel_center + sel_half);

    wire spr_on = spr_hit_q && (spr_q[2:0] != 3'd0);
    wire lab_on = lab_hit_q && lab_q[~pixel_x[3:0]];   // bit15为最左像素

    wire in_bg    = (line_y >= BG_Y);
    wire show     = enable_frame && de;
    wire band_hit = show && in_band;

    assign rgb_out = !band_hit ? rgb_in :
                     spr_on    ? sprite_color(spr_q[2:0]) :
                     lab_on    ? (sel ? SEL_COLOR : LABEL_COLOR) :
                     ul_on     ? SEL_COLOR :
                     in_bg     ? BG_COLOR  : rgb_in;
    assign nav_active = band_hit;
endmodule
