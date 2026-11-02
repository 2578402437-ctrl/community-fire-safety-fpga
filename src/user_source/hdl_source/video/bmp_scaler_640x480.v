// ============================================================================
// 文件名称：bmp_scaler_640x480.v
// 模块名称：bmp_scaler_640x480
// 功能描述：任意分辨率BMP加载时按比例缩放到640×480（最近邻）
// 目标器件：安路 EG4S20BG256
// ============================================================================
`timescale 1ns/1ps

// 任意分辨率BMP → 640×480 加载时缩放（最近邻，sd_card_clk域）
//
// 解析BMP头里的真实宽高，按比例缩放到显示区域。
// 本工程SDRAM每个bank只有640×480×1字的空间（1920×1080原图放不下），帧读取又是
// 整帧顺序流式读出，所以缩放放在"TF卡→SDRAM"的加载路径上做：
// 无论源图多大，写进SDRAM的永远是恰好 DST_W×DST_H 个像素，显示/转场/缩略图链路完全不用改。
//
// 缩放方式（KEEP_ASPECT）：
//   1 = 保持宽高比（letterbox）：按较大的缩放比缩放，居中，空白处填黑；
//       小图放大、大图缩小都可以；
//   0 = 拉伸填充：直接拉伸到640×480。
//
// 映射（src = dst × src_w / dst_w，向下取整）全部用累加/比较实现，不用除法器：
//   列：Ax = dx*src_w、Bx = x_s*dst_w，源像素x_s被选中 ⇔ Ax < Bx + dst_w（缩小时每列最多选1次）；
//       放大时（src_w < dst_w）源行全部存进行缓冲，输出时用 ua*dst_w ≤ dx*src_w < (ua+1)*dst_w 求读地址；
//   行：Ay = j*src_h、By = y_s*dst_h，源行y_s对应的输出行 ⇔ Ay < By + dst_h（放大时一行可重复多次，缩小时可能0次）。
//   只有letterbox的目标尺寸 dst = src_h*640/src_w（或 src_w*480/src_h）需要一次除法，
//   用10拍移位减法在头解析完成后算出。
//
// 数据流：BMP像素（已去掉行尾4字节对齐填充）→ 像素FIFO(512) → 行缓冲(640) → 按输出行发出。
//   放大时一条源行要输出多次，输出比输入快得多，必须能暂停SD读取：FIFO占用超过HOLD_LEVEL
//   时hold=1，上层把它并进流读器看到的sector_busy，流读器就不发下一个扇区请求
//   （一个扇区最多512字节=171个像素，HOLD_LEVEL留足余量，FIFO不会溢出）。
// 输出：每4拍1个像素（25M像素/秒，一帧约12ms），避免冲满SDRAM写FIFO。
//
// 容错：头校验失败、文件被截断（像素没送够就EOF）时，剩下的部分全部填黑，
// 保证总输出永远是 DST_W×DST_H 个像素——帧写入一定能完成，上层能正常看到load_error并重试/放弃。
// 进入填黑/结束状态后把FIFO里剩余像素全部丢弃，保证流读器不会被hold卡死。
module bmp_scaler_640x480 #(
    parameter integer DST_W       = 640,
    parameter integer DST_H       = 480,
    parameter integer KEEP_ASPECT = 1,
    parameter integer FIFO_AW     = 9,     // 像素FIFO深度 = 2^FIFO_AW = 512
    parameter integer HOLD_LEVEL  = 256    // FIFO占用超过此值暂停SD读取：hold在扇区中途就会拉起，
                                           // 而流读器要读完当前扇区(最多171像素)才停，256+171<512
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,      // 新一次加载开始（streamer_start），清空全部状态
    input  wire        hdr_done,   // BMP头解析完成（单拍）
    input  wire        hdr_ok,     // 头校验结果，hdr_done那拍有效
    input  wire [15:0] src_w,      // 源图宽高（hdr_done起保持稳定）
    input  wire [15:0] src_h,
    input  wire        in_valid,   // 源像素（已去行填充），{R,G,B}
    input  wire [23:0] in_pixel,
    input  wire        src_eof,    // 文件流结束（streamer_done，单拍）
    output wire        hold,       // 1=暂停SD读取
    output reg         out_valid,  // 输出像素（单拍）
    output reg  [23:0] out_pixel
);
    localparam integer FIFO_DEPTH   = 1 << FIFO_AW;
    localparam integer FRAME_PIXELS = DST_W * DST_H;
    localparam [10:0]  DW  = DST_W;            // 带位宽的目标尺寸，避免对integer参数做位选
    localparam [10:0]  DH  = DST_H;
    localparam [9:0]   DW1 = DST_W - 1;
    localparam [9:0]   DH10 = DST_H;

    localparam [3:0] S_IDLE      = 4'd0,   // 等头解析完成
                     S_DIV       = 4'd1,   // letterbox：求目标尺寸
                     S_INIT      = 4'd2,   // 求偏移、清累加器
                     S_PRE       = 4'd3,   // 底部黑边（BMP自下而上，先出底部）
                     S_CAP_START = 4'd4,   // 开始收一条源行
                     S_CAP       = 4'd5,   // 从FIFO取像素
                     S_CAP_USE   = 4'd6,   // 写行缓冲
                     S_ROWS      = 4'd7,   // 这条源行要输出几行
                     S_POST      = 4'd8,   // 顶部黑边
                     S_EMIT      = 4'd9,   // 输出一整行640像素
                     S_FLUSH     = 4'd10,  // 出错/截断：剩余全部填黑
                     S_DONE      = 4'd11;

    reg [3:0]  state, ret_state;

    // ---------------- 像素FIFO（同步，寄存器读出） ----------------
    reg [23:0]        fifo_mem [0:FIFO_DEPTH-1];
    reg [FIFO_AW-1:0] fifo_wp, fifo_rp;
    reg [FIFO_AW:0]   fifo_cnt;
    reg [23:0]        fifo_dout;

    reg [15:0] x_s;                            // 当前源列
    wire fifo_empty = (fifo_cnt == 0);
    wire fifo_we    = in_valid && (fifo_cnt != FIFO_DEPTH);
    wire pop_cap    = (state == S_CAP) && (x_s != src_w) && !fifo_empty;
    wire pop_drop   = (state == S_FLUSH || state == S_DONE) && !fifo_empty;
    wire fifo_re    = pop_cap || pop_drop;

    assign hold = (fifo_cnt > HOLD_LEVEL);

    always @(posedge clk) begin
        if (fifo_we)
            fifo_mem[fifo_wp] <= in_pixel;
        if (fifo_re)
            fifo_dout <= fifo_mem[fifo_rp];
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            fifo_wp  <= {FIFO_AW{1'b0}};
            fifo_rp  <= {FIFO_AW{1'b0}};
            fifo_cnt <= {(FIFO_AW+1){1'b0}};
        end else if (start) begin
            fifo_wp  <= {FIFO_AW{1'b0}};
            fifo_rp  <= {FIFO_AW{1'b0}};
            fifo_cnt <= {(FIFO_AW+1){1'b0}};
        end else begin
            if (fifo_we) fifo_wp <= fifo_wp + 1'b1;
            if (fifo_re) fifo_rp <= fifo_rp + 1'b1;
            fifo_cnt <= fifo_cnt + {{FIFO_AW{1'b0}}, fifo_we} - {{FIFO_AW{1'b0}}, fifo_re};
        end
    end

    // ---------------- 行缓冲（一条输出行所需的源像素，最多DST_W个） ----------------
    reg [23:0] lb_mem [0:DST_W-1];
    reg        lb_we;
    reg [9:0]  lb_waddr, lb_raddr;
    reg [23:0] lb_wdata, lb_rdata;

    always @(posedge clk) begin
        if (lb_we)
            lb_mem[lb_waddr] <= lb_wdata;
        lb_rdata <= lb_mem[lb_raddr];
    end

    // ---------------- 缩放参数 ----------------
    reg [10:0] dst_w, dst_h;                   // 实际图像区域尺寸
    reg [10:0] off_x, off_y;                   // 黑边偏移
    reg        up_x;                           // 1=水平放大（src_w < dst_w）

    // letterbox除法：q = dividend / divisor，q < 1024
    reg        div_wide;                       // 1=按宽度撑满（3w ≥ 4h）
    reg [31:0] div_rem, div_dsh;
    reg [9:0]  div_q;
    reg [3:0]  div_i;
    wire       wide_now  = ({2'b0, src_w} + {1'b0, src_w, 1'b0}) >= {src_h, 2'b0};   // 3w ≥ 4h
    wire        div_bit  = (div_rem >= div_dsh);

    // ---------------- 扫描计数/累加器 ----------------
    reg [15:0] y_s;                            // 当前源行
    reg [9:0]  wp;                             // 缩小时行缓冲写指针（=已选中的目标列数）
    reg [31:0] ax, bx_h;                       // 列映射累加器（bx_h 预存 bx+dst_w，比较时不再现加）
    reg [31:0] ay, by_h;                       // 行映射累加器（by_h 预存 by+dst_h）
    reg [9:0]  k;                              // 已输出的画布行数（0~DST_H）
    reg [9:0]  c;                              // 当前输出列
    reg [1:0]  ph;                             // 输出相位
    reg        row_black;                      // 当前输出行全黑
    reg [9:0]  ua;                             // 放大时的行缓冲读地址
    reg [31:0] cx_n, dx_lim;                   // 放大时读地址累加器：cx_n=(dx+1)*src_w（预加一步），dx_lim=(ua+1)*dst_w
    reg [18:0] out_cnt;                        // 已输出像素数
    reg        eof_seen;

    wire       in_img   = !row_black && ({1'b0, c} >= off_x) && ({1'b0, c} < off_x + dst_w);
    wire [10:0] dx_now  = {1'b0, c} - off_x;
    wire       out_room = (out_cnt < FRAME_PIXELS);

    // 末行判断预寄存：src_h 在BMP头解析时写定，hdr_done之后才进入S_ROWS，晚1拍无影响
    reg [15:0] src_h_m1;
    always @(posedge clk or posedge rst) begin
        if (rst)
            src_h_m1 <= 16'hFFFF;
        else
            src_h_m1 <= src_h - 16'd1;
    end

    task launch_row;
        input black;
        input [3:0] ret;
        begin
            row_black <= black;
            ret_state <= ret;
            c         <= 10'd0;
            ph        <= 2'd0;
            ua        <= 10'd0;
            cx_n      <= {16'd0, src_w};
            dx_lim    <= {21'd0, dst_w};
            state     <= S_EMIT;
        end
    endtask

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state     <= S_IDLE;
            ret_state <= S_IDLE;
            out_valid <= 1'b0;
            out_pixel <= 24'd0;
            lb_we     <= 1'b0;
            lb_waddr  <= 10'd0;
            lb_raddr  <= 10'd0;
            lb_wdata  <= 24'd0;
            dst_w     <= DW;
            dst_h     <= DH;
            off_x     <= 11'd0;
            off_y     <= 11'd0;
            up_x      <= 1'b0;
            div_wide  <= 1'b0;
            div_rem   <= 32'd0;
            div_dsh   <= 32'd0;
            div_q     <= 10'd0;
            div_i     <= 4'd0;
            x_s       <= 16'd0;
            y_s       <= 16'd0;
            wp        <= 10'd0;
            ax        <= 32'd0;
            bx_h      <= 32'd0;
            ay        <= 32'd0;
            by_h      <= 32'd0;
            k         <= 10'd0;
            c         <= 10'd0;
            ph        <= 2'd0;
            row_black <= 1'b1;
            ua        <= 10'd0;
            cx_n      <= 32'd0;
            dx_lim    <= 32'd0;
            out_cnt   <= 19'd0;
            eof_seen  <= 1'b0;
        end else if (start) begin
            state     <= S_IDLE;
            out_valid <= 1'b0;
            lb_we     <= 1'b0;
            out_cnt   <= 19'd0;
            eof_seen  <= 1'b0;
            ph        <= 2'd0;
        end else begin
            out_valid <= 1'b0;
            lb_we     <= 1'b0;
            if (src_eof)
                eof_seen <= 1'b1;

            case (state)
                S_IDLE: begin
                    if (hdr_done) begin
                        if (!hdr_ok) begin
                            state <= S_FLUSH;
                            ph    <= 2'd0;
                        end else if (KEEP_ASPECT != 0) begin
                            // 3w ≥ 4h：宽图，宽度撑满，dst_h = src_h*640/src_w
                            // 否则：高图，高度撑满，dst_w = src_w*480/src_h
                            div_wide <= wide_now;
                            div_rem  <= wide_now ? ({16'd0, src_h} * DST_W) : ({16'd0, src_w} * DST_H);
                            div_dsh  <= (wide_now ? {16'd0, src_w} : {16'd0, src_h}) << 9;
                            div_q    <= 10'd0;
                            div_i    <= 4'd9;
                            state    <= S_DIV;
                        end else begin
                            dst_w <= DW;
                            dst_h <= DH;
                            state <= S_INIT;
                        end
                    end else if (eof_seen) begin
                        // 文件比BMP头还短：直接填黑
                        state <= S_FLUSH;
                        ph    <= 2'd0;
                    end
                end

                S_DIV: begin
                    if (div_bit)
                        div_rem <= div_rem - div_dsh;
                    div_q   <= {div_q[8:0], div_bit};
                    div_dsh <= div_dsh >> 1;
                    if (div_i == 4'd0) begin
                        // 结果至少为1像素
                        if (div_wide) begin
                            dst_w <= DW;
                            dst_h <= ({div_q[8:0], div_bit} == 10'd0) ? 11'd1 : {1'b0, div_q[8:0], div_bit};
                        end else begin
                            dst_h <= DH;
                            dst_w <= ({div_q[8:0], div_bit} == 10'd0) ? 11'd1 : {1'b0, div_q[8:0], div_bit};
                        end
                        state <= S_INIT;
                    end else
                        div_i <= div_i - 4'd1;
                end

                S_INIT: begin
                    off_x <= (DW - dst_w) >> 1;
                    off_y <= (DH - dst_h) >> 1;
                    up_x  <= ({5'd0, src_w} < {5'd0, dst_w});
                    y_s   <= 16'd0;
                    ay    <= 32'd0;
                    by_h  <= {21'd0, dst_h};
                    k     <= 10'd0;
                    state <= S_PRE;
                end

                S_PRE: begin
                    if ({1'b0, k} < off_y)
                        launch_row(1'b1, S_PRE);
                    else
                        state <= S_CAP_START;
                end

                S_CAP_START: begin
                    x_s   <= 16'd0;
                    wp    <= 10'd0;
                    ax    <= 32'd0;
                    bx_h  <= {21'd0, dst_w};
                    state <= S_CAP;
                end

                S_CAP: begin
                    if (x_s == src_w)
                        state <= S_ROWS;
                    else if (!fifo_empty)
                        state <= S_CAP_USE;           // pop_cap本拍弹出，下一拍fifo_dout有效
                    else if (eof_seen) begin
                        state <= S_FLUSH;             // 像素没送够文件就结束了：截断
                        ph    <= 2'd0;
                    end
                end

                S_CAP_USE: begin
                    if (up_x) begin
                        // 水平放大：源行整行存下（src_w < dst_w ≤ 640）
                        lb_we    <= 1'b1;
                        lb_waddr <= x_s[9:0];
                        lb_wdata <= fifo_dout;
                    end else if (ax < bx_h) begin
                        // 水平缩小/1:1：只存被选中的列
                        lb_we    <= 1'b1;
                        lb_waddr <= wp;
                        lb_wdata <= fifo_dout;
                        wp       <= wp + 10'd1;
                        ax       <= ax + {16'd0, src_w};
                    end
                    bx_h  <= bx_h + {21'd0, dst_w};
                    x_s   <= x_s + 16'd1;
                    state <= S_CAP;
                end

                S_ROWS: begin
                    if (ay < by_h) begin
                        ay <= ay + {16'd0, src_h};
                        launch_row(1'b0, S_ROWS);
                    end else begin
                        by_h <= by_h + {21'd0, dst_h};
                        if (y_s == src_h_m1)
                            state <= S_POST;
                        else begin
                            y_s   <= y_s + 16'd1;
                            state <= S_CAP_START;
                        end
                    end
                end

                S_POST: begin
                    if (k < DH10)
                        launch_row(1'b1, S_POST);
                    else
                        state <= S_DONE;
                end

                S_EMIT: begin
                    case (ph)
                        2'd0: begin
                            lb_raddr <= up_x ? ua : dx_now[9:0];
                            ph <= 2'd1;
                        end
                        2'd1: ph <= 2'd2;             // 本拍lb_rdata读出
                        2'd2: begin
                            if (out_room) begin
                                out_valid <= 1'b1;
                                out_pixel <= in_img ? lb_rdata : 24'd0;
                                out_cnt   <= out_cnt + 19'd1;
                            end
                            ph <= 2'd3;
                        end
                        default: begin
                            if (in_img && up_x) begin
                                cx_n <= cx_n + {16'd0, src_w};
                                if (cx_n >= dx_lim) begin
                                    ua     <= ua + 10'd1;
                                    dx_lim <= dx_lim + {21'd0, dst_w};
                                end
                            end
                            ph <= 2'd0;
                            if (c == DW1) begin
                                k     <= k + 10'd1;
                                state <= ret_state;
                            end else
                                c <= c + 10'd1;
                        end
                    endcase
                end

                S_FLUSH: begin
                    // 与正常输出同一节拍填黑，直到凑满一帧
                    if (!out_room)
                        state <= S_DONE;
                    else begin
                        ph <= ph + 2'd1;
                        if (ph == 2'd2) begin
                            out_valid <= 1'b1;
                            out_pixel <= 24'd0;
                            out_cnt   <= out_cnt + 19'd1;
                        end
                    end
                end

                default: ;   // S_DONE：只丢弃FIFO剩余像素，等下一次start
            endcase
        end
    end
endmodule
