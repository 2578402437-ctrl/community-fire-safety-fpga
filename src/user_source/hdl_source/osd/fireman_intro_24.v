// ============================================================================
// 文件名称：fireman_intro_24.v
// 模块名称：fireman_intro_24
// 功能描述：开机动画叠加层：消防员从屏幕左侧走入并挥手问候
// 目标器件：安路 EG4S20BG256
// ============================================================================
`timescale 1ns/1ps

// 开机动画叠加层（24位RGB，整屏覆盖）：贴纸消防员从正左方屏幕外侧身走入，走到 PIC1 图中消防员的位置交接。
// 上电后先只显示背景 STAND_N 帧（约3秒，留出显示器重新锁定 HDMI 的时间，消防员还在屏幕外）；
// 首图提交（boot_done）后侧身（带白边，约240像素高）从左边屏幕外沿水平方向走 WALK_N 帧（约6.1秒）到 PIC1 中消防员的位置；
// 行走中第 FRONT_T0~FRONT_T1-1 帧原地站定、换正面图挥手打招呼（不移动、无脚步声），之后转回侧身继续往右走；
// 同时顶层按 walk_active 播开机问候语音，WALK_N 与语音等长。挥手不占新 ROM：正面图举起的前臂和手按行左右错切
// （以肘部 WV_PIVOT 行为轴，每行偏移 dx=(s·(WV_PIVOT−行))>>5，s 取32帧一周期的升余弦表 0~6，只向外摆），
// 第 WV_TOP1~WV_TOP2-1 行只动 WV_SPLIT1 列以右（手顶白边，避开耳朵），WV_TOP2~WV_PIVOT 行动 WV_SPLIT2 列以右，
// 偏移后空出的列取分界列本身的像素。几何与定点模型见 sim/l63_intro_greet/l63_model.py。
// 到位后换正面站立 ARRIVE_N 帧：轮廓内直接显示 rgb_in（PIC1 本身的像素，与图中消防员完全重合），
// 轮廓外仍为背景色；下一帧起交还原画面，看起来像消防员走进了画面。
// 首图一直不提交（读卡失败）就一直停在只有背景的画面；enable=0（硬切/缩略图）时动画直接结束。
//
// 卡上有 BG.BMP 时（bg_shown=1，显示bank里是背景图）：背景改为透出 rgb_in；PIC1 加载完（pic_ready）就开始走；
// 到位后继续画正面贴纸并举起 commit_req，控制层据此把显示bank从背景硬切到 PIC1，
// 首图提交（boot_done）后再画 BG_GUARD_N 帧（盖住 bank 切换生效前的帧），然后交还原画面。
//
// 行走循环每 16 帧换一个姿势：迈步(后腿压暗) → 并腿(身体抬高 BOB) → 迈步(前腿压暗) → 并腿。
// 侧身只有一张迈步图，靠把远侧那条腿压暗到3/4（c - c>>2，白边不压）做出左右脚交替；
// 进入迈步姿势、以及到位立定的那一帧发出落脚脉冲 step_pulse，驱动脚步声。
//
// ROM：3 张图（正面 1 倍显示，只在到位时用；迈步、并腿半分辨率 2 倍显示），每像素 5 位编号（0=透明，2起=调色板），
// 每个 16 位字存 3 个像素（[4:0]、[9:5]、[14:10]），每行补齐到整字。按 BRAM32K 的 2048×16 配置约 10 块。
// 正面图颜色取自 PIC1，轮廓与 PIC1 中消防员对齐。
// 同步读1拍延迟：按"下一个像素"提前一拍给地址；ROM 列 c，字号 = c/3 = (c*171)>>9（c<256 精确）。
// 资源与几何常量（INTRO_BEGIN~INTRO_END 段）与 ROM 文件 rom/intro_sticker_5bit.hex 配套，修改时须同步；
// INIT文件路径相对 td_project/xxx_Runs/syn_1。
module fireman_intro_24 #(
    parameter         ROM_FILE  = "../../../user_source/hdl_source/rom/intro_sticker_5bit.hex",
    parameter integer STAND_N   = 180,           // 开场只显示背景的帧数（约3秒@60Hz，≤255；显示器重新锁定HDMI要1~3秒），之后首图未到继续等
    parameter integer WALK_N    = 368,           // 行走帧数（约6.13秒，≤511；与开机问候语音等长，VX/AX0 按此与挥手段计算）
    parameter integer FRONT_T0  = 120,           // 正面原地挥手起始行走帧号
    parameter integer FRONT_T1  = 248,           // 挥手结束（转回侧身）帧号，FRONT_T1-FRONT_T0 须为32的倍数（结束时手回原位）
    parameter integer ARRIVE_N  = 16,            // 到位后正面站立帧数（约0.27秒）
    parameter integer BG_GUARD_N = 4,            // 有背景图时：首图提交后继续画贴纸的帧数
    parameter [23:0]  BG        = 24'h1B2A41     // 无背景图时的纯色背景（深海军蓝）
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire        enable,       // 0=导航栏被隐藏（硬切/缩略图），动画直接结束（帧边界判断）
    input  wire        boot_done,    // 首图已提交（已同步到本时钟域）
    input  wire        bg_shown,     // 显示bank里是背景图 BG.BMP（已同步到本时钟域）
    input  wire        pic_ready,    // PIC1 已加载完、等本模块放行提交（已同步到本时钟域）
    output wire [23:0] rgb_out,
    output wire        intro_active, // 开机动画进行中（帧边界更新）
    output wire        commit_req,   // 请求提交首图：到位后及结束后为1
    output reg         step_pulse,   // 落脚脉冲（1拍）：行走中进入迈步姿势、到位立定时发出，驱动脚步声
    output reg         step_side,    // 本次落脚是哪只脚（交替）
    output wire        walk_active   // 行走中（含原地挥手），顶层据此开始播开机问候语音
);
    // INTRO_BEGIN
    // 与 rom/intro_sticker_5bit.hex 配套的几何常量
    localparam integer FRONT_W    = 164;      // ROM 有效宽（像素）
    localparam integer FRONT_H    = 241;      // ROM 行数
    localparam integer FRONT_WPR  = 55;       // 每行字数（3像素/字）
    localparam integer FRONT_BASE = 0;   // 首字地址
    localparam integer STEP_W     = 69;      // ROM 有效宽（像素）
    localparam integer STEP_H     = 120;      // ROM 行数
    localparam integer STEP_WPR   = 23;       // 每行字数（3像素/字）
    localparam integer STEP_BASE  = 13255;   // 首字地址
    localparam integer PASS_W     = 70;      // ROM 有效宽（像素）
    localparam integer PASS_H     = 120;      // ROM 行数
    localparam integer PASS_WPR   = 24;       // 每行字数（3像素/字）
    localparam integer PASS_BASE  = 16015;   // 首字地址
    localparam integer ROM_DEPTH  = 18895;
    localparam integer X_TGT      = 456;      // 到位：PIC1 中消防员左上角屏幕列
    localparam integer Y_TGT      = 217;      // 到位：PIC1 中消防员顶行屏幕行
    localparam integer AX0        = -74;      // 行走起点：脚底中心屏幕列（负=左边屏幕外），定点模型见 sim/l63_intro_greet/l63_model.py
    localparam integer AY0        = 458;      // 行走起点：脚底下一行屏幕行
    localparam integer VX         = 41;       // 每帧右移（Q4 像素），只在侧身段移动 WALK_N-1-(FRONT_T1-FRONT_T0) 帧
    localparam integer VY         = 0;       // 每帧下移（Q4 像素）
    localparam integer BOB        = 4;        // 并腿姿势身体抬高（像素）
    localparam integer LEG_Y      = 91;       // 迈步图腿部起始 ROM 行
    localparam integer LEG_SPLIT  = 31;       // 迈步图前后腿分界 ROM 列（左=后腿）
    function [23:0] spr_color;           // 调色板（编号2起）
        input [4:0] code;
        begin
            case (code)
            5'd2: spr_color = 24'hFFFFFF;
            5'd3: spr_color = 24'hFEFEFE;
            5'd4: spr_color = 24'hFDFCFB;
            5'd5: spr_color = 24'hFCFAF9;
            5'd6: spr_color = 24'hFAF8F9;
            5'd7: spr_color = 24'hFBF8F6;
            5'd8: spr_color = 24'hFCF1DB;
            5'd9: spr_color = 24'hF9EBDB;
            5'd10: spr_color = 24'hF2E4DA;
            5'd11: spr_color = 24'hF9E6D1;
            5'd12: spr_color = 24'hF7E08D;
            5'd13: spr_color = 24'hE2CAB5;
            5'd14: spr_color = 24'hF5CB4F;
            5'd15: spr_color = 24'hEFAE6B;
            5'd16: spr_color = 24'hC1AB99;
            5'd17: spr_color = 24'hEE7438;
            5'd18: spr_color = 24'hF0682D;
            5'd19: spr_color = 24'hF25F2C;
            5'd20: spr_color = 24'hD47A44;
            5'd21: spr_color = 24'h9A7D6E;
            5'd22: spr_color = 24'hDD5836;
            5'd23: spr_color = 24'h925A46;
            5'd24: spr_color = 24'hDF432B;
            5'd25: spr_color = 24'h913623;
            5'd26: spr_color = 24'h6A4038;
            5'd27: spr_color = 24'h6B291E;
            5'd28: spr_color = 24'h563D38;
            5'd29: spr_color = 24'h4F2E26;
            5'd30: spr_color = 24'h451D15;
            5'd31: spr_color = 24'h42120A;
            default: spr_color = 24'h000000;
            endcase
        end
    endfunction
    function spr_white;                  // 白边色（不参与远侧腿压暗）
        input [4:0] code;
        begin
            case (code)
            5'd2, 5'd3, 5'd4, 5'd5, 5'd6, 5'd7: spr_white = 1'b1;
            default: spr_white = 1'b0;
            endcase
        end
    endfunction
    // INTRO_END

    // ---------- 挥手错切参数（正面图 ROM 坐标）----------
    localparam integer FRONT_HALF = FRONT_W / 2;   // 正面图脚底中心相对左上角的列
    localparam integer WV_TOP1   = 96;              // 手顶白边起始行
    localparam integer WV_SPLIT1 = 142;             // 该段只动此列以右
    localparam integer WV_TOP2   = 103;             // 手掌起始行
    localparam integer WV_SPLIT2 = 120;             // 该段到肘部只动此列以右
    localparam integer WV_PIVOT  = 140;             // 肘部（轴）行，偏移为0
    localparam [4:0]   WV_PH0    = FRONT_T0 % 32;   // 挥手相位起点（t_cnt 低5位）
    function [2:0] wave_s;                          // 挥手幅度表 round(6·(1−cos(2πk/32))/2)
        input [4:0] k;
        begin
            case (k)
            5'd0, 5'd1, 5'd2, 5'd30, 5'd31:                 wave_s = 3'd0;
            5'd3, 5'd4, 5'd5, 5'd27, 5'd28, 5'd29:          wave_s = 3'd1;
            5'd6, 5'd7, 5'd25, 5'd26:                       wave_s = 3'd2;
            5'd8, 5'd24:                                    wave_s = 3'd3;
            5'd9, 5'd10, 5'd22, 5'd23:                      wave_s = 3'd4;
            5'd11, 5'd12, 5'd13, 5'd19, 5'd20, 5'd21:       wave_s = 3'd5;
            default:                                        wave_s = 3'd6;   // 14~18
            endcase
        end
    endfunction

    // ---------- 帧边界 ----------
    reg vs_q, de_q;
    wire frame_start = vs_q && !vsync;

    // ---------- 帧级状态 ----------
    wire next_front;             // 下一帧是原地挥手（定义在状态机之后）
    localparam [1:0] ST_STAND = 2'd0, ST_WALK = 2'd1, ST_DONE = 2'd2, ST_ARRIVE = 2'd3;
    reg [1:0]  st;
    reg [7:0]  s_cnt;            // 已站立帧数 0~STAND_N
    reg [8:0]  t_cnt;            // 行走帧号 0~WALK_N-1
    reg [5:0]  a_cnt;            // 到位帧号 0~ARRIVE_N-1
    reg [13:0] pos_x, pos_y;     // 行走位移（Q4，像素，最大约 610 像素）
    reg        primed;           // 上电后第一个 frame_start 才开始画，复位后的半帧不出杂乱画面
    reg        bg_d1, bg_f;      // bg_shown 连续两个帧边界为1才透出 rgb_in（确保读帧已换到背景bank）
    reg        arr_bg;           // 本次到位是背景图模式：画贴纸、等首图提交

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_q       <= 1'b1;
            de_q       <= 1'b0;
            st         <= ST_STAND;
            s_cnt      <= 8'd0;
            t_cnt      <= 9'd0;
            a_cnt      <= 6'd0;
            pos_x      <= 14'd0;
            pos_y      <= 14'd0;
            primed     <= 1'b0;
            bg_d1      <= 1'b0;
            bg_f       <= 1'b0;
            arr_bg     <= 1'b0;
            step_pulse <= 1'b0;
            step_side  <= 1'b0;
        end else begin
            vs_q       <= vsync;
            de_q       <= de;
            step_pulse <= 1'b0;
            if (frame_start && st != ST_DONE) begin
                primed <= 1'b1;
                bg_d1  <= bg_shown;
                bg_f   <= bg_shown && bg_d1;
                if (!enable) begin
                    st <= ST_DONE;
                end else if (st == ST_STAND) begin
                    if (s_cnt == STAND_N) begin
                        if (boot_done || pic_ready) begin
                            st         <= ST_WALK;      // 本帧为行走第0帧：迈步、压暗后腿
                            t_cnt      <= 9'd0;
                            pos_x      <= 14'd0;
                            pos_y      <= 14'd0;
                            step_pulse <= 1'b1;
                            step_side  <= 1'b0;
                        end
                    end else
                        s_cnt <= s_cnt + 1'b1;
                end else if (st == ST_WALK) begin
                    if (t_cnt == WALK_N - 1) begin
                        st         <= ST_ARRIVE;        // 到位立定，出一声脚步
                        a_cnt      <= 6'd0;
                        arr_bg     <= bg_f;
                        step_pulse <= 1'b1;
                        step_side  <= !step_side;       // 与上一步换脚
                    end else begin
                        t_cnt <= t_cnt + 1'b1;
                        if (!next_front) begin          // 原地挥手期间不移动
                            pos_x <= pos_x + VX;
                            pos_y <= pos_y + VY;
                        end
                        if (t_cnt == FRONT_T0 - 1) begin                        // 下一帧站定挥手：出一声立定脚步
                            step_pulse <= 1'b1;
                            step_side  <= !t_cnt[5];
                        end else if (t_cnt[4:0] == 5'd31 && !next_front) begin  // 下一帧进入迈步姿势
                            step_pulse <= 1'b1;
                            step_side  <= !t_cnt[5];
                        end
                    end
                end else if (arr_bg) begin
                    if (boot_done) begin                // 背景图模式：首图提交后再画 BG_GUARD_N 帧
                        if (a_cnt == BG_GUARD_N - 1)
                            st <= ST_DONE;
                        else
                            a_cnt <= a_cnt + 1'b1;
                    end
                end else begin
                    if (a_cnt == ARRIVE_N - 1)
                        st <= ST_DONE;                  // 交还原画面（PIC1）
                    else
                        a_cnt <= a_cnt + 1'b1;
                end
            end
        end
    end

    wire active = (st != ST_DONE);
    assign intro_active = active;
    assign walk_active  = (st == ST_WALK);
    assign next_front   = (t_cnt >= FRONT_T0 - 1) && (t_cnt < FRONT_T1 - 1);
    assign commit_req   = st[1];          // ST_ARRIVE/ST_DONE，单个寄存器位，跨域无毛刺

    // ---------- 本帧图片选择与位置（帧内恒定） ----------
    // 行走姿势 t_cnt[5:4]：0=迈步(压暗后腿) 1=并腿 2=迈步(压暗前腿) 3=并腿；原地挥手与到位用正面图
    // （下面 walking 指"侧身 2 倍显示"，原地挥手帧不算）
    wire        greet    = (st == ST_WALK) && (t_cnt >= FRONT_T0) && (t_cnt < FRONT_T1);
    wire        walking  = (st == ST_WALK) && !greet;
    wire        arrive   = (st == ST_ARRIVE);
    wire        is_pass  = walking && t_cnt[4];
    wire        is_step  = walking && !t_cnt[4];
    wire [7:0]  spr_w    = !walking ? FRONT_W : is_pass ? PASS_W : STEP_W;     // ROM 宽
    wire [8:0]  scr_w    = !walking ? FRONT_W : {spr_w, 1'b0};                // 屏幕宽
    wire [8:0]  scr_h    = !walking ? FRONT_H : 2 * STEP_H;                    // 屏幕高（迈步/并腿同高）
    wire [14:0] spr_base = !walking ? FRONT_BASE : is_pass ? PASS_BASE : STEP_BASE;
    wire [5:0]  spr_wpr  = !walking ? FRONT_WPR : is_pass ? PASS_WPR : STEP_WPR;
    localparam signed [11:0] AX0_S = AX0;                                     // 起点在左边屏幕外（负列）
    wire signed [11:0] ax = AX0_S + $signed({2'd0, pos_x[13:4]});             // 脚底中心屏幕列（可为负）
    wire        [9:0]  ay = AY0 + pos_y[13:4];                                 // 脚底下一行屏幕行
    wire signed [11:0] x0 = arrive ? X_TGT : greet ? ax - FRONT_HALF : ax - $signed({4'd0, spr_w});
    wire signed [11:0] y0 = (arrive || greet) ? Y_TGT :
                            $signed({2'd0, ay}) - (2 * STEP_H) - (is_pass ? BOB : 0);
    wire        dark_front = t_cnt[5];        // 迈步姿势下压暗哪条腿：0=后腿（左侧），1=前腿（右侧）

    // ---------- 行计数与行首地址 ----------
    reg  [9:0]  ln;                           // 当前行号（de 下降沿加1，消隐期即为下一行）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ln <= 10'd0;
        else if (active) begin
            if (frame_start)
                ln <= 10'd0;
            else if (de_q && !de)
                ln <= ln + 1'b1;
        end
    end
    wire signed [11:0] ry2    = $signed({2'd0, ln}) - y0;           // 屏幕行相对图片顶行
    wire               row_in = (ry2 >= 0) && (ry2 < $signed({3'd0, scr_h}));
    wire        [7:0]  ry     = walking ? ry2[8:1] : ry2[7:0];     // ROM 行（正面 1 倍、侧身 2 倍）
    reg         [14:0] row_base;                                   // 本行 ROM 字地址起点（消隐期算好）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            row_base <= 15'd0;
        else if (active)
            row_base <= spr_base + ry * spr_wpr;
    end
    // 挥手：本行错切区开关、分界列与偏移（随 ln 每拍寄存，消隐期即为下一行的值；非挥手帧 wv_on=0）
    wire [2:0]  wv_s     = wave_s(t_cnt[4:0] - WV_PH0);
    wire [5:0]  wv_h     = WV_PIVOT - ry;                          // 行在错切区内时 ≤ 44
    wire [8:0]  wv_prod  = wv_s * wv_h;
    reg         wv_on;
    reg  [7:0]  wv_split;
    reg  [3:0]  wv_dx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wv_on    <= 1'b0;
            wv_split <= 8'd0;
            wv_dx    <= 4'd0;
        end else if (active) begin
            wv_on    <= greet && row_in && (ry >= WV_TOP1) && (ry <= WV_PIVOT);
            wv_split <= (ry < WV_TOP2) ? WV_SPLIT1 : WV_SPLIT2;
            wv_dx    <= wv_prod[8:5];
        end
    end

    // ---------- 下一个像素的列 ----------
    reg  signed [11:0] rel_q;                                      // 有效期内为下一个像素相对 X0 的列
    wire signed [11:0] rel_n = de ? rel_q : -x0;                   // 下一个像素：消隐期为本行第0列
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rel_q <= 12'sd0;
        else if (active)
            rel_q <= rel_n + 12'sd1;
    end
    wire        col_in = (rel_n >= 0) && (rel_n < $signed({3'd0, scr_w}));
    wire [7:0]  c      = walking ? rel_n[8:1] : rel_n[7:0];        // ROM 列 0~255
    // 挥手错切：分界列以右读 c−dx，落到分界列以左时取分界列（c≥分界列≥120，相减不会下溢）
    wire [7:0]  c_sh   = c - {4'd0, wv_dx};
    wire [7:0]  cr     = (wv_on && c >= wv_split) ? ((c_sh < wv_split) ? wv_split : c_sh) : c;
    wire [15:0] c171   = cr * 8'd171;
    wire [5:0]  w      = c171[14:9];                               // c/3（0~54）
    wire [1:0]  sub    = cr - {w, 1'b0} - w;                       // cr - 3w
    wire        fetch  = active && primed && (st != ST_STAND) && row_in && col_in;   // 开场等待期间不画人
    wire        dk_n   = is_step && (ry >= LEG_Y) && ((c < LEG_SPLIT) != dark_front);
    // 输入隔离：不取数时地址清零
    wire [14:0] addr   = fetch ? row_base + w : 15'd0;

    (* ram_style = "bram_32k" *) reg [14:0] rom [0:ROM_DEPTH-1];
    reg [14:0] q;
    initial $readmemh(ROM_FILE, rom);
    // 读使能：只在取数时读ROM，开机动画结束后ROM不再翻转（q只在hit时被使用）
    always @(posedge clk)
        if (fetch)
            q <= rom[addr];

    reg       hit;
    reg [1:0] sub_q;
    reg       dk_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hit   <= 1'b0;
            sub_q <= 2'd0;
            dk_q  <= 1'b0;
        end else begin
            hit   <= fetch;
            sub_q <= sub;
            dk_q  <= dk_n;
        end
    end

    // ---------- 合成 ----------
    wire [4:0]  code  = (sub_q == 2'd0) ? q[4:0] : (sub_q == 2'd1) ? q[9:5] : q[14:10];
    wire        body  = hit && (code >= 5'd2);
    wire [23:0] col   = spr_color(code);
    wire        dk    = dk_q && !spr_white(code);
    wire [23:0] col_d = dk ? {col[23:16] - col[23:18], col[15:8] - col[15:10], col[7:0] - col[7:2]} : col;
    // 到位：轮廓内直通 PIC1 原像素，与图中消防员完全重合（背景图模式此时 PIC1 还没显示，仍画贴纸）
    wire [23:0] fg    = (arrive && !arr_bg) ? rgb_in : col_d;
    // 背景：有背景图时透出 rgb_in，否则纯色
    wire [23:0] bk    = (bg_f || (arrive && arr_bg)) ? rgb_in : BG;

    assign rgb_out = (active && primed && de) ? (body ? fg : bk) : rgb_in;
endmodule
