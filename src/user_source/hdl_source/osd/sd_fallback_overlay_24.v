// ============================================================================
// 文件名称：sd_fallback_overlay_24.v
// 模块名称：sd_fallback_overlay_24
// 功能描述：SD卡故障提示图叠加层（片上1位ROM）
// 目标器件：安路 EG4S20BG256
// ============================================================================
`timescale 1ns/1ps

// SD卡故障提示图（24位RGB叠加层，放在显示链路最末端）。
// SD卡持续ABSENT_FRAMES帧没有初始化成功时，整屏显示片上ROM里的提示图
// （橙底白字"SD卡损坏 请联系技术人员"），盖住其后所有画面；SD卡初始化成功后立即撤销。
//
// 不经过SDRAM帧缓存、不占写端口：ROM存320×240单色位图（1=前景色、0=底色），
// 显示时按2×2最近邻放大到640×480。数据由 tools/convert/make_fallback_1bit.py 生成，
// 换图时重跑该脚本，并把脚本打印的底色/前景色同步到BG_COLOR/FG_COLOR。
//
// 时序：与其他叠加层相同，像素路径不增加流水线延迟，不影响HDMI数据岛
// 调度器依赖的video_x/video_de对齐。ROM为同步读（1拍延迟），故按"下一个像素"的
// 列号提前一拍给地址：每个ROM字覆盖屏幕上32个像素，行消隐期预取下一行第0字。
// 行号由本地vsync/de重建；显示使能只在帧边界更新，画面不会出现半帧提示图。
//
// INIT_FILE 为 $readmemh 的相对路径：TD综合时工作目录是 td_project/xxx_Runs/syn_1。
// ROM不加ram_style，由TD按默认推断（约10块BRAM9K），不使用BRAM32K。
module sd_fallback_overlay_24 #(
    parameter integer ABSENT_FRAMES = 90,           // 约1.5秒@60Hz：上电后SD卡初始化正常远小于此时间
    parameter [23:0]  BG_COLOR      = 24'hE44C0B,   // 底色（橙）
    parameter [23:0]  FG_COLOR      = 24'hFDFDFD,   // 前景色（白）
    parameter         INIT_FILE     = "../../../user_source/hdl_source/rom/sd_fallback_1bit.hex"
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [9:0]  pixel_x,
    input  wire        sd_ready,        // SD卡初始化完成（已同步到本时钟域）
    output wire [23:0] rgb_out,
    output wire        fallback_active
);
    localparam integer SRC_W         = 320;
    localparam integer SRC_H         = 240;
    localparam integer WORDS_PER_ROW = SRC_W / 16;           // 20
    localparam integer ROM_DEPTH     = WORDS_PER_ROW * SRC_H; // 4800

    // ---------- 行号重建（与各叠加层一致）----------
    reg [11:0] line_y;
    reg de_q;
    reg vs_q;
    wire frame_start = vs_q && !vsync;

    // ---------- 帧级状态：SD卡缺失计时与显示使能 ----------
    reg [6:0] absent_cnt;
    reg       show_frame;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_y     <= 12'd0;
            de_q       <= 1'b0;
            vs_q       <= 1'b1;
            absent_cnt <= 7'd0;
            show_frame <= 1'b0;
        end else begin
            de_q <= de;
            vs_q <= vsync;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;

            if (frame_start) begin
                if (sd_ready) begin
                    absent_cnt <= 7'd0;
                    show_frame <= 1'b0;
                end else if (absent_cnt >= ABSENT_FRAMES) begin
                    show_frame <= 1'b1;
                end else begin
                    absent_cnt <= absent_cnt + 1'b1;
                end
            end
        end
    end

    // ---------- 位图ROM：同步读，1拍延迟 ----------
    reg [15:0] mem [0:ROM_DEPTH-1];
    reg [15:0] rom_q;

    initial begin
        $readmemh(INIT_FILE, mem);
    end

    // 下一个像素的列号：有效期内为pixel_x+1，消隐期为下一行第0列
    wire [10:0] next_x   = de ? ({1'b0, pixel_x} + 11'd1) : 11'd0;
    wire [7:0]  src_row  = line_y[8:1];                           // 2:1 行放大
    wire [12:0] row_base = {src_row, 4'b0000} + {src_row, 2'b00}; // src_row*20
    wire [12:0] rom_addr = row_base + {7'd0, next_x[10:5]};       // 每字32个屏幕像素

    // 读使能：只在提示图显示期间读ROM，平时ROM不翻转（rom_q只在show时被使用）
    always @(posedge clk) begin
        if (show_frame)
            rom_q <= mem[rom_addr];
    end

    // 字内bit15为最左像素；屏幕每2个像素对应1个ROM像素
    wire pix_on = rom_q[~pixel_x[4:1]];

    wire show = show_frame && de;
    assign rgb_out         = show ? (pix_on ? FG_COLOR : BG_COLOR) : rgb_in;
    assign fallback_active = show_frame;

endmodule
