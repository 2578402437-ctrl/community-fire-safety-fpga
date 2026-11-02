// ============================================================================
// 文件名称：transition_shape_mask_24.v
// 模块名称：transition_shape_mask_24
// 功能描述：转场双路像素合成（交叉淡化与多种形状转场）
// 目标器件：安路 EG4S20BG256
// ============================================================================
`timescale 1ns/1ps

// 转场双路合成（24位RGB），配合video_fade_transition使用：rgb_a=旧图（A路），rgb_b=新图（B路）。
// mix_active=0时直通rgb_a；mix_active=1时按shape_kind合成：
//   0 交叉淡化：rgb_a + ((rgb_b-rgb_a)*q)>>>8，每通道一个乘法（q=0逐位等于A，q=256逐位等于B）；
//   1~4 形状：形状区域C(q)内取rgb_b，其余取rgb_a；
//   5 燃烧纸张：见下文，与交叉淡化共用乘法器。
// 扫过区域C(q)随比例q（0~256）单调增大：q=0什么都没扫过，q=256整屏扫过。
// shape_in保留原语义（1=C(q)内可见），转场控制器恒给1；shape_in=0时可见区域取反。
// 三种形状（屏幕640x480，中心(320,240)）：
//   1 中间往两边：cdist < W，cdist为像素到中线的距离（0~319），W = q*320/256 = q + q>>2；
//   2 两边往中间：cdist >= 320-W，写成 cdist+W >= 320，不用减法；
//   3 轮子：从12点方向顺时针扫过角度θ = 2π*q/256。
//      以像素中心为准取 u = 2x-639（向右为正）、v = 479-2y（向上为正），u/v恒为奇数，不会落在轴上。
//      c = u*cosθ - v*sinθ = r*sin(φ-θ)（代码中为cross_v），φ为像素自12点顺时针的角度；c<0 即 φ在θ之前。
//      θ<π：扫过 ⇔ 右半屏(u>0) 且 c<0；θ≥π：扫过 ⇔ 右半屏 或 c<0；q=256时整屏扫过。
//      sin/cos查64点四分之一周期表（×256）。叉积在行内按像素累加2cosθ（行首装入 u*cosθ-v*sinθ 初值），v*sinθ按行累减2sinθ，
//      像素级只有加法和比较，不占乘法器。
// 光圈直接按"可见 ⇔ 度量 < vis"判断，vis = 进场q / 退场256-q（0~256）：
//   4 圆形光圈：度量 = u²+v²（到中心距离平方，半像素单位），阈值 R² ，R = vis*800/256 = vis*3 + vis>>3，
//      vis=256时R=800（中心到角），整屏可见。u²+v²按行/按像素增量累加（(u+2)² = u²+4u+4），
//      R²在vsync低电平期间用移位相加10拍算出，不占乘法器。
//   5 燃烧纸张（自下而上）：度量 m = (479-y) + 噪声/2，阈值 t = vis*19/8（0~608），d = t - m：
//      噪声 = (3*o64 + o16)>>2（0~255），o64/o16为格距64/16的格点哈希值噪声（双线性插值，见burn_noise_octave）；
//      d>=0 烧穿：A向B按 k=128+32d 过渡（d>=4 全B）；d<0 未烧：A向焦褐色按 k=230+10d 压暗（d<=-23 全A）；
//      火光：|d+1|<=6 时各通道再加 GLOW*(255-40|d+1|)/256（查表），饱和到255。
//      全屏度量 39~593，所以 q=0 逐位等于A、q=256 逐位等于B。
//      噪声与权重提前一像素算好寄存（行消隐期装入行首像素），像素路径与交叉淡化相同，只多一级饱和加法。
// 以下 6~10 号转场的定点模型见 sim/l64_trans_more/l64_model.py，与本模块公式一致：
//   6 方块溶解：屏幕分成40×30个16×16方块，块哈希 t（0~255）< vis 即可见：
//      x1 = 块序号*0x9E5 mod 4096（按块累加0x9E5、换块行累加40*0x9E5），t = ((x1^(x1>>6))*0x5A3 mod 4096)>>4；
//   7 横百叶窗：32 行一条，(行号 & 31) < vis>>3；
//   8 菱形光圈：|u|+|v| < R，R = 4vis + vis>>2 + vis>>3（0~1120，覆盖 |u|+|v| 最大 1118）；
//   9 五角星光圈：5 条直线 n_k·p < d 围成，至多违反 1 条即在星内（中心五边形 + 5 个星角），d = vis²>>6（0~1024）；
//      n_k 角度 = vis>>2 + 64 + {0,51,102,154,205}（256=一周，64=正上方，星形随进度旋转约90°），
//      n_k·p 与轮子一样按行/按像素累加（每条直线一组），帧首在场同步期间用一对正弦表分 5 拍算出 cos/sin；
//      星外 G=24（半像素）内为金色光带：A 向金色按 kg = m + m>>1 混合（m = min(vis,256-vis)，两端为0）；
//      d=1024 时中心五边形内切半径超过中心到角的距离 800，整屏为 B；
//  10 卷帘：卷筒底边 edge = 516 - (2vis + vis>>1 - vis>>6)（行，516 → -120）；edge-36 ≤ 行 < edge 为卷筒，
//      A 按行查表向黑/白混合（圆柱明暗 + 高光）；行 ≥ edge 为 B，紧贴卷筒下方 64 行按行查表压暗（投影），其余为 A。
//   光带、卷筒、投影都与交叉淡化共用乘法器 A + ((T-A)*k)>>>8，k 为每帧/每行常数。
//
// 时序：rgb_out为组合输出，与输入de同拍对齐。顶层把本模块放在读FIFO输出与像素寄存器之间
// （de/vsync/pixel_x用比显示像素早一拍的时序），输出打一拍后正好与原像素对齐，不增加像素延迟。
// 参数在帧边界（vsync下降沿）锁存，整帧使用同一组参数，不会出现上下半帧不一致。
module transition_shape_mask_24 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_a,           // 旧图（A路）
    input  wire [23:0] rgb_b,           // 新图（B路）
    input  wire [9:0]  pixel_x,
    input  wire        mix_active,      // 1=本帧双路合成
    input  wire [3:0]  shape_kind,      // 0=交叉淡化 1=中间往两边 2=两边往中间 3=轮子 4=光圈 5=燃烧
                                        // 6=溶解 7=横百叶窗 8=菱形光圈 9=五角星光圈 10=卷帘
    input  wire        shape_in,        // 1=C(q)内取B（恒1）
    input  wire [8:0]  shape_q,         // 新图比例 0~256
    output wire [23:0] rgb_out,
    output wire        mask_active      // 1=本像素正在合成
);
    // ---------- 帧边界锁存 ----------
    reg       vs_q;
    reg       de_q;
    wire      frame_start = vs_q && !vsync;
    reg       act_f;
    reg [3:0] kind_f;
    reg       in_f;
    reg [8:0] q_f;
    reg [9:0] t_f;       // 燃烧阈值 vis*19/8（0~608）
    reg [8:0] vis_f;     // 溶解/百叶窗/菱形/五角星/卷帘用的可见比例
    reg [10:0] dia_r_f;  // 菱形阈值 4vis + vis>>2 + vis>>3（0~1120）
    reg [10:0] star_d_f; // 五角星直线距离 vis²>>6（0~1024，半像素）
    reg [7:0]  star_kg_f;// 金色光带混合比例
    reg signed [10:0] roll_e_f;   // 卷帘卷筒底边行号（-120~516）

    wire [8:0] vis_now = shape_in ? shape_q : (9'd256 - shape_q);
    // vis*19 = vis*16 + vis*2 + vis
    wire [13:0] vis19  = {1'b0, vis_now, 4'd0} + {4'd0, vis_now, 1'b0} + {5'd0, vis_now};
    wire [10:0] dia_r  = {vis_now, 2'b00} + {4'd0, vis_now[8:2]} + {5'd0, vis_now[8:3]};
    wire [17:0] vis_sq = vis_now * vis_now;
    wire [7:0]  vis_m  = vis_now[8] ? 8'd0 : (vis_now[7] ? (9'd256 - vis_now) : vis_now[7:0]);   // min(vis,256-vis)
    wire signed [10:0] roll_e = 11'sd516 - $signed({1'b0, vis_now, 1'b0}) - $signed({3'd0, vis_now[8:1]})
                              + $signed({8'd0, vis_now[8:6]});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_q   <= 1'b1;
            de_q   <= 1'b0;
            act_f  <= 1'b0;
            kind_f <= 3'd0;
            in_f   <= 1'b0;
            q_f    <= 9'd0;
            t_f    <= 10'd0;
            vis_f     <= 9'd0;
            dia_r_f   <= 11'd0;
            star_d_f  <= 11'd0;
            star_kg_f <= 8'd0;
            roll_e_f  <= 11'sd516;
        end else begin
            vs_q <= vsync;
            de_q <= de;
            if (frame_start) begin
                act_f  <= mix_active;
                kind_f <= shape_kind;
                in_f   <= shape_in;
                q_f    <= shape_q;
                t_f    <= vis19[12:3];
                vis_f     <= vis_now;
                dia_r_f   <= dia_r;
                star_d_f  <= vis_sq[16:6];
                star_kg_f <= vis_m + {1'b0, vis_m[7:1]};
                roll_e_f  <= roll_e;
            end
        end
    end

    // ---------- 撕裂：到中线的距离与边界半宽 ----------
    wire [9:0] cdist10 = (pixel_x < 10'd320) ? (10'd319 - pixel_x) : (pixel_x - 10'd320);
    wire [8:0] cdist   = cdist10[8:0];                                 // 0~319
    wire [9:0] half_w = {1'b0, q_f} + {3'b000, q_f[8:2]};          // 0~320
    wire       cov_out = ({1'b0, cdist} < half_w);                   // 中间往两边
    wire       cov_in  = (({1'b0, cdist} + half_w) >= 10'd320);      // 两边往中间

    // ---------- 轮子：四分之一周期正弦表 ----------
    function [8:0] sin_tab;   // round(256*sin(2π*i/256))，i=0~64
        input [6:0] i;
        begin
            case (i)
                7'd0:  sin_tab = 9'd0;   7'd1:  sin_tab = 9'd6;   7'd2:  sin_tab = 9'd13;  7'd3:  sin_tab = 9'd19;
                7'd4:  sin_tab = 9'd25;  7'd5:  sin_tab = 9'd31;  7'd6:  sin_tab = 9'd38;  7'd7:  sin_tab = 9'd44;
                7'd8:  sin_tab = 9'd50;  7'd9:  sin_tab = 9'd56;  7'd10: sin_tab = 9'd62;  7'd11: sin_tab = 9'd68;
                7'd12: sin_tab = 9'd74;  7'd13: sin_tab = 9'd80;  7'd14: sin_tab = 9'd86;  7'd15: sin_tab = 9'd92;
                7'd16: sin_tab = 9'd98;  7'd17: sin_tab = 9'd104; 7'd18: sin_tab = 9'd109; 7'd19: sin_tab = 9'd115;
                7'd20: sin_tab = 9'd121; 7'd21: sin_tab = 9'd126; 7'd22: sin_tab = 9'd132; 7'd23: sin_tab = 9'd137;
                7'd24: sin_tab = 9'd142; 7'd25: sin_tab = 9'd147; 7'd26: sin_tab = 9'd152; 7'd27: sin_tab = 9'd157;
                7'd28: sin_tab = 9'd162; 7'd29: sin_tab = 9'd167; 7'd30: sin_tab = 9'd172; 7'd31: sin_tab = 9'd177;
                7'd32: sin_tab = 9'd181; 7'd33: sin_tab = 9'd185; 7'd34: sin_tab = 9'd190; 7'd35: sin_tab = 9'd194;
                7'd36: sin_tab = 9'd198; 7'd37: sin_tab = 9'd202; 7'd38: sin_tab = 9'd206; 7'd39: sin_tab = 9'd209;
                7'd40: sin_tab = 9'd213; 7'd41: sin_tab = 9'd216; 7'd42: sin_tab = 9'd220; 7'd43: sin_tab = 9'd223;
                7'd44: sin_tab = 9'd226; 7'd45: sin_tab = 9'd229; 7'd46: sin_tab = 9'd231; 7'd47: sin_tab = 9'd234;
                7'd48: sin_tab = 9'd237; 7'd49: sin_tab = 9'd239; 7'd50: sin_tab = 9'd241; 7'd51: sin_tab = 9'd243;
                7'd52: sin_tab = 9'd245; 7'd53: sin_tab = 9'd247; 7'd54: sin_tab = 9'd248; 7'd55: sin_tab = 9'd250;
                7'd56: sin_tab = 9'd251; 7'd57: sin_tab = 9'd252; 7'd58: sin_tab = 9'd253; 7'd59: sin_tab = 9'd254;
                7'd60: sin_tab = 9'd255; 7'd61: sin_tab = 9'd255; 7'd62: sin_tab = 9'd256; 7'd63: sin_tab = 9'd256;
                default: sin_tab = 9'd256;
            endcase
        end
    endfunction

    // 整周期 sin(2π*a/256)，有符号 -256~256
    function signed [10:0] sin_full;
        input [7:0] a;
        reg   [8:0] m;
        begin
            m = a[6] ? sin_tab(7'd64 - {1'b0, a[5:0]}) : sin_tab({1'b0, a[5:0]});
            sin_full = a[7] ? -$signed({2'b00, m}) : $signed({2'b00, m});
        end
    endfunction

    wire [7:0]         ang   = q_f[7:0];
    wire signed [10:0] sin_s = sin_full(ang);
    wire signed [10:0] cos_s = sin_full(ang + 8'd64);

    // 帧首 v=479：479*sin = 512s-32s-s；行首 u=-639：-639*cos = -(512c+128c-c)
    wire signed [21:0] sin22 = {{11{sin_s[10]}}, sin_s};
    wire signed [21:0] cos22 = {{11{cos_s[10]}}, cos_s};
    wire signed [21:0] vs_init = (sin22 <<< 9) - (sin22 <<< 5) - sin22;
    wire signed [21:0] uc_init = cos22 - (cos22 <<< 9) - (cos22 <<< 7);

    // 叉积直接累加：行消隐期装入 -639*cosθ - v*sinθ，像素期每拍加2cosθ，
    // 符号位直接取自寄存器，像素级路径上没有减法器。
    // 只有轮子帧（kind_f=3）用到叉积；act_f/kind_f只在帧首更新，场消隐期间会重新装初值，
    // 故非轮子帧停住累加器不影响结果，只省去每像素的加法翻转。
    wire whl_en = act_f && (kind_f == 3'd3);
    reg signed [21:0] vs_acc;    // v*sinθ，本行
    reg signed [21:0] cross_v;   // u*cosθ - v*sinθ，本像素
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_acc  <= 22'sd0;
            cross_v <= 22'sd0;
        end else if (whl_en) begin
            // 行号在!vsync期间清零（与各叠加层一致），此时参数已在帧边界锁存
            if (!vsync)
                vs_acc <= vs_init;
            else if (de_q && !de)
                vs_acc <= vs_acc - (sin22 <<< 1);   // 下一行 v减2
            // 行消隐有多拍，de下降沿那拍vs_acc刚更新，之后几拍会用新值重新装入
            if (!de)
                cross_v <= uc_init - vs_acc;
            else
                cross_v <= cross_v + (cos22 <<< 1);  // 下一像素 u加2
        end
    end

    wire u_pos   = (pixel_x >= 10'd320);
    wire c_neg   = cross_v[21];
    wire cov_whl = q_f[8] ? 1'b1 :
                   ang[7] ? (u_pos || c_neg) : (u_pos && c_neg);

    // ---------- 光圈：R²（vsync低电平期间移位相加）与 u²+v² 增量累加 ----------
    // R = vis*3 + vis>>3（0~800），用帧边界的输入直接算，与q_f同一组参数
    wire [9:0] r_now = {vis_now, 1'b0} + {1'b0, vis_now} + {4'b0000, vis_now[8:3]};
    reg  [19:0] r2_acc;      // R²，最大640000
    reg  [19:0] r2_a;
    reg  [9:0]  r2_b;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r2_acc <= 20'd0;
            r2_a   <= 20'd0;
            r2_b   <= 10'd0;
        end else if (frame_start) begin
            r2_acc <= 20'd0;
            r2_a   <= {10'd0, r_now};
            r2_b   <= r_now;
        end else if (r2_b != 10'd0) begin
            if (r2_b[0])
                r2_acc <= r2_acc + r2_a;
            r2_a <= {r2_a[18:0], 1'b0};
            r2_b <= {1'b0, r2_b[9:1]};
        end
    end

    // v²按行：帧首 v=479，v² = 229441，(v-2)² = v² + dv，dv = -4v+4 从-1912起每行+8
    // u²+v²按像素：行首 u=-639，d² = 408321 + v²，(u+2)² = u² + du，du = 4u+4 从-2552起每像素+8
    // 只有光圈帧（kind_f=4）用到 u²+v²，非光圈帧停住累加器（理由同轮子）
    wire iris_en = act_f && (kind_f == 3'd4);
    reg        [17:0] v2_acc;
    reg signed [12:0] dv_acc;
    reg        [19:0] d2_acc;
    reg signed [12:0] du_acc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v2_acc <= 18'd0;
            dv_acc <= 13'sd0;
            d2_acc <= 20'd0;
            du_acc <= 13'sd0;
        end else if (iris_en) begin
            if (!vsync) begin
                v2_acc <= 18'd229441;
                dv_acc <= -13'sd1912;
            end else if (de_q && !de) begin
                v2_acc <= v2_acc + {{5{dv_acc[12]}}, dv_acc};
                dv_acc <= dv_acc + 13'sd8;
            end
            if (!de) begin
                d2_acc <= 20'd408321 + {2'b00, v2_acc};
                du_acc <= -13'sd2552;
            end else begin
                d2_acc <= d2_acc + {{7{du_acc[12]}}, du_acc};
                du_acc <= du_acc + 13'sd8;
            end
        end
    end
    wire vis_iris = (d2_acc < r2_acc);

    // ---------- 燃烧纸张：行号、行消隐拍数、两个八度的噪声 ----------
    wire       burn_on = act_f && (kind_f == 3'd5);
    wire       row_end = de_q && !de;
    reg  [8:0] row_y;        // 当前行号 0~479
    reg  [3:0] hb_cnt;       // 行消隐（及场消隐后）已过拍数，饱和到15
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_y  <= 9'd0;
            hb_cnt <= 4'd0;
        end else begin
            if (!vsync)
                row_y <= 9'd0;
            else if (row_end)
                row_y <= row_y + 9'd1;
            if (de || !vsync)
                hb_cnt <= 4'd0;
            else if (hb_cnt != 4'd15)
                hb_cnt <= hb_cnt + 4'd1;
        end
    end

    // 行消隐期依次装入第0、1、2列（每列隔2拍：哈希寄存一拍、插值后写入），第8拍算行首像素权重，
    // 第9拍噪声前进到第1像素；像素期每拍算下一像素权重并前进。非燃烧帧噪声不翻转。
    wire bn_ld0 = burn_on && (hb_cnt == 4'd2);
    wire bn_ld1 = burn_on && (hb_cnt == 4'd4);
    wire bn_ld2 = burn_on && (hb_cnt == 4'd6);
    wire bn_pre = burn_on && (hb_cnt == 4'd8);
    wire bn_adv = burn_on && (de || (hb_cnt == 4'd9));

    wire [7:0] o64, o16;
    burn_noise_octave #(.SH(6), .SEED(12'h135), .KROW(12'hCD7)) u_oct64 (   // 11列*0x9E5
        .clk(clk), .rst_n(rst_n), .en(burn_on), .vsync(vsync), .row_end(row_end), .fy(row_y[5:0]),
        .ld0(bn_ld0), .ld1(bn_ld1), .ld2(bn_ld2), .adv(bn_adv), .o(o64));
    burn_noise_octave #(.SH(4), .SEED(12'h7A9), .KROW(12'h5AD)) u_oct16 (   // 41列*0x9E5
        .clk(clk), .rst_n(rst_n), .en(burn_on), .vsync(vsync), .row_end(row_end), .fy(row_y[3:0]),
        .ld0(bn_ld0), .ld1(bn_ld1), .ld2(bn_ld2), .adv(bn_adv), .o(o16));

    // 噪声 n = (3*o64+o16)>>2，度量 m = (479-y) + n>>1，d = t - m（-606~608）
    wire [9:0]         n_sum = {1'b0, o64, 1'b0} + {2'b00, o64} + {2'b00, o16};
    wire signed [11:0] bn_d  = $signed({2'b00, t_f}) + $signed({3'b000, row_y})
                             - $signed({5'd0, n_sum[9:3]}) - 12'sd479;
    wire               d_neg = bn_d[11];
    // 烧穿侧 k = 128+32d（d>=4 为256）；未烧侧 k = 230+10d = 230-10*(-d)（d<=-23 为0）
    wire [11:0]        nd    = -bn_d;
    wire [8:0]         k_new = (bn_d >= 12'sd4) ? 9'd256 : {2'b01, bn_d[1:0], 5'd0};
    wire [8:0]         k_old = (bn_d <= -12'sd23) ? 9'd0 :
                               (9'd230 - {1'b0, nd[4:0], 3'd0} - {3'd0, nd[4:0], 1'b0});
    // 火光：a = |d+1|，a<=6 时 g = 255-40a，各通道 GLOW*g>>8 查表（GLOW = 255,110,20）
    wire signed [11:0] bn_e  = bn_d + 12'sd1;
    wire [11:0]        e_abs = bn_e[11] ? -bn_e : bn_e;
    reg  [23:0]        glow_w;
    always @(*) begin
        case (e_abs)
            12'd0:   glow_w = {8'd254, 8'd109, 8'd19};
            12'd1:   glow_w = {8'd214, 8'd92,  8'd16};
            12'd2:   glow_w = {8'd174, 8'd75,  8'd13};
            12'd3:   glow_w = {8'd134, 8'd58,  8'd10};
            12'd4:   glow_w = {8'd94,  8'd40,  8'd7};
            12'd5:   glow_w = {8'd54,  8'd23,  8'd4};
            12'd6:   glow_w = {8'd14,  8'd6,   8'd1};
            default: glow_w = 24'd0;
        endcase
    end

    reg        bn_neg;      // 1=本像素未烧穿（目标色为焦褐）
    reg [8:0]  bn_k;
    reg [23:0] bn_glow;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bn_neg  <= 1'b0;
            bn_k    <= 9'd0;
            bn_glow <= 24'd0;
        end else if (bn_pre || (burn_on && de)) begin
            bn_neg  <= d_neg;
            bn_k    <= d_neg ? k_old : k_new;
            bn_glow <= glow_w;
        end
    end

    // ---------- 6 方块溶解：块哈希（带使能：非溶解帧不翻转）----------
    wire dis_en = act_f && (kind_f == 4'd6);
    localparam [11:0] DIS_C1   = 12'h9E5;   // 每块累加
    localparam [11:0] DIS_KROW = 12'hBC8;   // 40*0x9E5 mod 4096，每块行累加
    reg  [3:0]  row_lo;      // 行号低4位（块内行）
    reg  [11:0] x1_row;      // 本块行第0块的x1
    reg  [11:0] x1;          // 当前/下一块的x1
    reg  [7:0]  t_blk;       // 当前块阈值
    wire [11:0] x2 = x1 ^ {6'd0, x1[11:6]};
    // x2*0x5A3 mod 4096，0x5A3 = 2^10+2^8+2^7+2^5+2^1+2^0
    wire [11:0] x3 = x2 + {x2[10:0], 1'b0} + {x2[6:0], 5'd0}
                        + {x2[4:0], 7'd0} + {x2[3:0], 8'd0} + {x2[1:0], 10'd0};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_lo <= 4'd0;
            x1_row <= 12'd0;
            x1     <= 12'd0;
            t_blk  <= 8'd0;
        end else if (dis_en) begin
            if (!vsync) begin
                row_lo <= 4'd0;
                x1_row <= 12'd0;
            end else if (de_q && !de) begin
                row_lo <= row_lo + 4'd1;
                if (row_lo == 4'd15)
                    x1_row <= x1_row + DIS_KROW;
            end
            // 块内第14列提前换到下一块，t_blk再打一拍，下一块第0列正好生效
            if (!de)
                x1 <= x1_row;
            else if (pixel_x[3:0] == 4'd14)
                x1 <= x1 + DIS_C1;
            t_blk <= x3[11:4];
        end
    end
    wire vis_dis = ({1'b0, t_blk} < vis_f);

    // ---------- 7 横百叶窗 ----------
    wire vis_bl = ({1'b0, row_y[4:0]} < vis_f[8:3]);

    // ---------- 8 菱形光圈：|u| = 2*cdist+1，|v| 由行号得出 ----------
    wire [8:0]  vd9   = (row_y < 9'd240) ? (9'd239 - row_y) : (row_y - 9'd240);   // 到水平中线距离 0~239
    wire [10:0] dia_m = {1'b0, cdist, 1'b1} + {2'b00, vd9[7:0], 1'b1};             // |u|+|v|（cdist≤319、vd≤239）
    wire vis_dia = (dia_m < dia_r_f);

    // ---------- 9 五角星光圈：5 组直线累加器 ----------
    // 帧首（vsync下降沿）后用一对正弦表依次算 5 条直线法向的 sin/cos，场同步低电平期间装入行首初值。
    wire star_en = act_f && (kind_f == 4'd9);
    reg  [2:0] st_k;                          // 0~4 正在算第k条，5=算完
    wire [7:0] st_off = (st_k == 3'd1) ? 8'd51  : (st_k == 3'd2) ? 8'd102 :
                        (st_k == 3'd3) ? 8'd154 : (st_k == 3'd4) ? 8'd205 : 8'd0;
    wire [7:0] st_al  = {1'b0, vis_f[8:2]} + 8'd64 + st_off;
    wire signed [10:0] st_sin_n = sin_full(st_al);
    wire signed [10:0] st_cos_n = sin_full(st_al + 8'd64);
    reg  signed [10:0] st_sin [0:4];
    reg  signed [10:0] st_cos [0:4];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            st_k <= 3'd5;
        else if (frame_start)
            st_k <= 3'd0;
        else if (st_k != 3'd5)
            st_k <= st_k + 3'd1;
    end
    always @(posedge clk) begin               // 只在帧首后5拍写入，非星形帧不用
        if (st_k != 3'd5) begin
            st_sin[st_k] <= st_sin_n;
            st_cos[st_k] <= st_cos_n;
        end
    end
    wire signed [21:0] st_dlim  = $signed({3'd0, star_d_f, 8'd0});                       // d*256
    wire signed [21:0] st_glim  = $signed({3'd0, star_d_f + 11'd24, 8'd0});              // (d+G)*256
    wire [4:0] st_out, st_outg;               // 每条直线：1=在该直线外侧（违反）
    genvar sk;
    generate
        for (sk = 0; sk < 5; sk = sk + 1) begin : g_star
            wire signed [21:0] s22 = {{11{st_sin[sk][10]}}, st_sin[sk]};
            wire signed [21:0] c22 = {{11{st_cos[sk][10]}}, st_cos[sk]};
            // 帧首 v=479：479*sin = 512s-32s-s；行首 u=-639：-639*cos = -(512c+128c-c)
            wire signed [21:0] vs_i = (s22 <<< 9) - (s22 <<< 5) - s22;
            wire signed [21:0] uc_i = c22 - (c22 <<< 9) - (c22 <<< 7);
            reg  signed [21:0] vs_a;          // v*sin，本行
            reg  signed [21:0] acc;           // u*cos + v*sin，本像素
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    vs_a <= 22'sd0;
                    acc  <= 22'sd0;
                end else if (star_en) begin
                    if (!vsync)
                        vs_a <= vs_i;
                    else if (de_q && !de)
                        vs_a <= vs_a - (s22 <<< 1);   // 下一行 v减2
                    if (!de)
                        acc <= uc_i + vs_a;
                    else
                        acc <= acc + (c22 <<< 1);     // 下一像素 u加2
                end
            end
            assign st_out[sk]  = (acc >= st_dlim);
            assign st_outg[sk] = (acc >= st_glim);
        end
    endgenerate
    function le1;                             // 5位中至多1位为1
        input [4:0] b;
        begin
            le1 = ((b & (b - 5'd1)) == 5'd0);
        end
    endfunction
    wire star_in   = le1(st_out);
    wire star_band = !star_in && le1(st_outg);
    localparam [23:0] STAR_GOLD = 24'hFFD76E;   // 金色 (255,215,110)

    // ---------- 10 卷帘：按行查表（行号变化后一拍寄存，行消隐期即就绪）----------
    function [9:0] roll_band;                 // {1=向白/0=向黑, k}，卷筒内第e行（0~35）
        input [5:0] e;
        begin
            case (e)
            6'd0 : roll_band = {1'b0, 9'd135};
            6'd1 : roll_band = {1'b0, 9'd129};
            6'd2 : roll_band = {1'b0, 9'd120};
            6'd3 : roll_band = {1'b0, 9'd109};
            6'd4 : roll_band = {1'b0, 9'd98};
            6'd5 : roll_band = {1'b0, 9'd85};
            6'd6 : roll_band = {1'b0, 9'd71};
            6'd7 : roll_band = {1'b0, 9'd54};
            6'd8 : roll_band = {1'b0, 9'd32};
            6'd9 : roll_band = {1'b0, 9'd1};
            6'd10: roll_band = {1'b1, 9'd36};
            6'd11: roll_band = {1'b1, 9'd70};
            6'd12: roll_band = {1'b1, 9'd90};
            6'd13: roll_band = {1'b1, 9'd87};
            6'd14: roll_band = {1'b1, 9'd70};
            6'd15: roll_band = {1'b1, 9'd51};
            6'd16: roll_band = {1'b1, 9'd38};
            6'd17: roll_band = {1'b1, 9'd31};
            6'd18: roll_band = {1'b1, 9'd28};
            6'd19: roll_band = {1'b1, 9'd25};
            6'd20: roll_band = {1'b1, 9'd21};
            6'd21: roll_band = {1'b1, 9'd16};
            6'd22: roll_band = {1'b1, 9'd9};
            6'd23: roll_band = {1'b1, 9'd0};
            6'd24: roll_band = {1'b0, 9'd10};
            6'd25: roll_band = {1'b0, 9'd21};
            6'd26: roll_band = {1'b0, 9'd33};
            6'd27: roll_band = {1'b0, 9'd46};
            6'd28: roll_band = {1'b0, 9'd59};
            6'd29: roll_band = {1'b0, 9'd72};
            6'd30: roll_band = {1'b0, 9'd85};
            6'd31: roll_band = {1'b0, 9'd98};
            6'd32: roll_band = {1'b0, 9'd109};
            6'd33: roll_band = {1'b0, 9'd120};
            6'd34: roll_band = {1'b0, 9'd129};
            6'd35: roll_band = {1'b0, 9'd135};
            default: roll_band = 10'd0;
            endcase
        end
    endfunction
    function [8:0] roll_shadow;               // 投影压暗 k，卷筒下方第d行（0~63）
        input [5:0] d;
        begin
            case (d)
            6'd0 : roll_shadow = 9'd115;
            6'd1 : roll_shadow = 9'd107;
            6'd2 : roll_shadow = 9'd100;
            6'd3 : roll_shadow = 9'd93;
            6'd4 : roll_shadow = 9'd87;
            6'd5 : roll_shadow = 9'd81;
            6'd6 : roll_shadow = 9'd75;
            6'd7 : roll_shadow = 9'd70;
            6'd8 : roll_shadow = 9'd65;
            6'd9 : roll_shadow = 9'd61;
            6'd10: roll_shadow = 9'd56;
            6'd11: roll_shadow = 9'd53;
            6'd12: roll_shadow = 9'd49;
            6'd13: roll_shadow = 9'd46;
            6'd14: roll_shadow = 9'd42;
            6'd15: roll_shadow = 9'd39;
            6'd16: roll_shadow = 9'd37;
            6'd17: roll_shadow = 9'd34;
            6'd18: roll_shadow = 9'd32;
            6'd19: roll_shadow = 9'd30;
            6'd20: roll_shadow = 9'd28;
            6'd21: roll_shadow = 9'd26;
            6'd22: roll_shadow = 9'd24;
            6'd23: roll_shadow = 9'd22;
            6'd24: roll_shadow = 9'd21;
            6'd25: roll_shadow = 9'd19;
            6'd26: roll_shadow = 9'd18;
            6'd27: roll_shadow = 9'd17;
            6'd28: roll_shadow = 9'd16;
            6'd29: roll_shadow = 9'd15;
            6'd30: roll_shadow = 9'd14;
            6'd31: roll_shadow = 9'd13;
            6'd32: roll_shadow = 9'd12;
            6'd33: roll_shadow = 9'd11;
            6'd34: roll_shadow = 9'd10;
            6'd35: roll_shadow = 9'd9;
            6'd36: roll_shadow = 9'd9;
            6'd37: roll_shadow = 9'd8;
            6'd38: roll_shadow = 9'd8;
            6'd39: roll_shadow = 9'd7;
            6'd40: roll_shadow = 9'd7;
            6'd41: roll_shadow = 9'd6;
            6'd42: roll_shadow = 9'd6;
            6'd43: roll_shadow = 9'd5;
            6'd44: roll_shadow = 9'd5;
            6'd45: roll_shadow = 9'd5;
            6'd46: roll_shadow = 9'd4;
            6'd47: roll_shadow = 9'd4;
            6'd48: roll_shadow = 9'd4;
            6'd49: roll_shadow = 9'd3;
            6'd50: roll_shadow = 9'd3;
            6'd51: roll_shadow = 9'd3;
            6'd52: roll_shadow = 9'd3;
            6'd53: roll_shadow = 9'd3;
            6'd54: roll_shadow = 9'd2;
            6'd55: roll_shadow = 9'd2;
            6'd56: roll_shadow = 9'd2;
            6'd57: roll_shadow = 9'd2;
            6'd58: roll_shadow = 9'd2;
            6'd59: roll_shadow = 9'd2;
            6'd60: roll_shadow = 9'd2;
            6'd61: roll_shadow = 9'd1;
            6'd62: roll_shadow = 9'd1;
            6'd63: roll_shadow = 9'd1;
            default: roll_shadow = 9'd0;
            endcase
        end
    endfunction
    wire signed [11:0] roll_dy = $signed({3'd0, row_y}) - $signed({roll_e_f[10], roll_e_f});   // 行 - edge
    wire signed [11:0] roll_eb = roll_dy + 12'sd36;                                            // 行 - (edge-36)
    wire [9:0]         roll_bt = roll_band(roll_eb[5:0]);                                      // 卷筒行表（行在卷筒内时有效）
    reg        roll_band_r;    // 1=本行是卷筒
    reg        roll_b_r;       // 1=本行已揭开（显示B，可能带投影）
    reg        roll_w_r;       // 卷筒：1=向白 0=向黑
    reg [8:0]  roll_k_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            roll_band_r <= 1'b0;
            roll_b_r    <= 1'b0;
            roll_w_r    <= 1'b0;
            roll_k_r    <= 9'd0;
        end else if (act_f && (kind_f == 4'd10)) begin
            roll_band_r <= !roll_eb[11] && roll_dy[11];            // edge-36 ≤ 行 < edge
            roll_b_r    <= !roll_dy[11];                           // 行 ≥ edge
            roll_w_r    <= roll_bt[9];
            roll_k_r    <= roll_dy[11] ? roll_bt[8:0] :
                           (roll_dy < 12'sd64) ? roll_shadow(roll_dy[5:0]) : 9'd0;
        end
    end

    reg covered;
    always @(*) begin
        case (kind_f)
            4'd1:    covered = cov_out;
            4'd2:    covered = cov_in;
            default: covered = cov_whl;
        endcase
    end

    // 1~3 按扫过区域与进/退场换算；4/6/7/8 直接给出可见与否（0/5/9/10 不走这里）
    reg visible;
    always @(*) begin
        case (kind_f)
            4'd1, 4'd2, 4'd3: visible = in_f ? covered : !covered;
            4'd4:             visible = vis_iris;
            4'd6:             visible = vis_dis;
            4'd7:             visible = vis_bl;
            4'd8:             visible = vis_dia;
            default:          visible = 1'b0;
        endcase
    end
    // ---------- 交叉淡化/燃烧：A + ((T-A)*k)>>>8，非这两种帧乘法器输入清零 ----------
    // 交叉淡化 T=B、k=q；燃烧 T=B或焦褐、k=bn_k
    localparam [23:0] BURN_CHAR = 24'h1C0E06;   // 焦褐色 (28,14,6)
    // 五角星光带 T=金色、k=kg（A路）；卷帘卷筒 T=黑/白、k=行表（A路），投影 T=黑、k=行表（B路）
    wire       fade_on = act_f && (kind_f == 4'd0);
    wire       star_on = act_f && (kind_f == 4'd9);
    wire       roll_on = act_f && (kind_f == 4'd10);
    wire       star_mul = star_on && star_band;
    wire       roll_mul = roll_on && (roll_band_r || roll_b_r);
    wire       mul_on  = fade_on || burn_on || star_mul || roll_mul;
    wire [23:0] fa = !mul_on ? 24'd0 :
                     (roll_on && roll_b_r) ? rgb_b : rgb_a;
    wire [23:0] fb = fade_on  ? rgb_b :
                     burn_on  ? (bn_neg ? BURN_CHAR : rgb_b) :
                     star_mul ? STAR_GOLD :
                     roll_mul ? ((roll_band_r && roll_w_r) ? 24'hFFFFFF : 24'h000000) : 24'd0;
    wire [8:0]  fq = fade_on  ? q_f :
                     burn_on  ? bn_k :
                     star_mul ? {1'b0, star_kg_f} :
                     roll_mul ? roll_k_r : 9'd0;
    wire signed [8:0]  d_r = $signed({1'b0, fb[23:16]}) - $signed({1'b0, fa[23:16]});
    wire signed [8:0]  d_g = $signed({1'b0, fb[15:8]})  - $signed({1'b0, fa[15:8]});
    wire signed [8:0]  d_b = $signed({1'b0, fb[7:0]})   - $signed({1'b0, fa[7:0]});
    wire signed [9:0]  q_s = $signed({1'b0, fq});
    wire signed [18:0] p_r = d_r * q_s;
    wire signed [18:0] p_g = d_g * q_s;
    wire signed [18:0] p_b = d_b * q_s;
    // 结果恒在A、T之间（0~255），取低8位即可
    wire [9:0] o_r = {2'b00, fa[23:16]} + p_r[17:8];
    wire [9:0] o_g = {2'b00, fa[15:8]}  + p_g[17:8];
    wire [9:0] o_b = {2'b00, fa[7:0]}   + p_b[17:8];
    // 燃烧：加火光并饱和
    wire [8:0]  s_r = {1'b0, o_r[7:0]} + {1'b0, bn_glow[23:16]};
    wire [8:0]  s_g = {1'b0, o_g[7:0]} + {1'b0, bn_glow[15:8]};
    wire [8:0]  s_b = {1'b0, o_b[7:0]} + {1'b0, bn_glow[7:0]};
    wire [23:0] burn_rgb = {s_r[8] ? 8'hFF : s_r[7:0],
                            s_g[8] ? 8'hFF : s_g[7:0],
                            s_b[8] ? 8'hFF : s_b[7:0]};

    wire [23:0] mul_rgb = {o_r[7:0], o_g[7:0], o_b[7:0]};
    wire show_b = de && act_f && visible;
    assign rgb_out     = fade_on ? mul_rgb :
                         burn_on ? burn_rgb :
                         star_on ? (star_in ? rgb_b : star_mul ? mul_rgb : rgb_a) :
                         roll_on ? (roll_mul ? mul_rgb : rgb_a) :
                         show_b  ? rgb_b : rgb_a;
    assign mask_active = de && act_f;

endmodule

// 燃烧噪声的一个八度：格距 2^SH 的格点哈希值噪声，先在列上按行竖直插值，再在行内水平插值。
//   格点(i,j)的值 = hash(((j*列数 + i)*0x9E5 + SEED) mod 4096)，hash(x) = ((x^(x>>6))*0x5A3 mod 4096)>>4（0~255）；
//   本行各列竖直插值 vcol(i) = c(i,j) + floor((c(i,j+1)-c(i,j))*fy / 2^SH)，进入新格时才算再下一列（提前两列）；
//   水平插值 o = vl + floor((vr-vl)*fx / 2^SH)，行内每像素累加 vr-vl，只用加法。
// o 为当前位置的噪声；位置在行消隐期由 ld0/ld1/ld2 复位到行首，adv 每拍前进一个像素。
module burn_noise_octave #(
    parameter integer SH   = 6,
    parameter [11:0]  SEED = 12'h000,
    parameter [11:0]  KROW = 12'h000      // 每个格点行的序号增量 = 列数*0x9E5 mod 4096
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          en,          // 0=保持不翻转
    input  wire          vsync,
    input  wire          row_end,     // 行结束（行号加1）
    input  wire [SH-1:0] fy,          // 格内行号（行号低SH位）
    input  wire          ld0,         // 开始取第0列
    input  wire          ld1,         // vl=第0列，开始取第1列
    input  wire          ld2,         // vr=第1列，开始取第2列，位置回到行首
    input  wire          adv,         // 前进一个像素
    output wire [7:0]    o
);
    localparam [11:0] C1 = 12'h9E5;

    function [7:0] lat_hash;
        input [11:0] x1;
        reg   [11:0] x2, x3;
        begin
            x2 = x1 ^ {6'd0, x1[11:6]};
            // x2*0x5A3 mod 4096，0x5A3 = 2^10+2^8+2^7+2^5+2^1+2^0
            x3 = x2 + {x2[10:0], 1'b0} + {x2[6:0], 5'd0}
                    + {x2[4:0], 7'd0} + {x2[3:0], 8'd0} + {x2[1:0], 10'd0};
            lat_hash = x3[11:4];
        end
    endfunction

    reg  [11:0]          hrow;    // 本格点行第0列的序号哈希
    reg  [11:0]          hc;      // 正在取的列
    reg  [7:0]           h0, h1;  // 该列上、下两个格点的值
    reg  [7:0]           vl, vr;  // 当前格左、右两列的竖直插值
    reg  [SH-1:0]        fx;
    reg  signed [SH+9:0] acc;     // (vr-vl)*fx

    wire signed [8:0]    dh   = $signed({1'b0, h1}) - $signed({1'b0, h0});
    wire signed [SH+9:0] pv   = dh * $signed({1'b0, fy});
    wire [7:0]           vcol = h0 + pv[SH+7:SH];          // 结果在0~255，取低8位
    wire signed [SH+9:0] dv   = $signed({{SH{1'b0}}, 2'b00, vr}) - $signed({{SH{1'b0}}, 2'b00, vl});
    assign o = vl + acc[SH+7:SH];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hrow <= 12'd0;
            hc   <= 12'd0;
            h0   <= 8'd0;
            h1   <= 8'd0;
            vl   <= 8'd0;
            vr   <= 8'd0;
            fx   <= {SH{1'b0}};
            acc  <= {(SH+10){1'b0}};
        end else if (!vsync) begin
            hrow <= SEED;
        end else if (en) begin
            if (row_end && (&fy))
                hrow <= hrow + KROW;
            h0 <= lat_hash(hc);
            h1 <= lat_hash(hc + KROW);
            if (ld0)
                hc <= hrow;
            else if (ld1 || ld2 || (adv && (&fx)))
                hc <= hc + C1;
            if (ld1)
                vl <= vcol;
            if (ld2) begin
                vr  <= vcol;
                fx  <= {SH{1'b0}};
                acc <= {(SH+10){1'b0}};
            end else if (adv) begin
                if (&fx) begin
                    vl  <= vr;
                    vr  <= vcol;
                    fx  <= {SH{1'b0}};
                    acc <= {(SH+10){1'b0}};
                end else begin
                    fx  <= fx + 1'b1;
                    acc <= acc + dv;
                end
            end
        end
    end
endmodule
