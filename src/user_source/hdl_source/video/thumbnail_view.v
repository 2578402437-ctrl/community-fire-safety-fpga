// ============================================================================
// 文件名称：thumbnail_view.v
// 模块名称：thumbnail_view
// 功能描述：缩略图显示通路：读使能门控、格子着色与焦点边框
// 目标器件：安路 EG4S20BG256
// ============================================================================
`timescale 1ns/1ps

// 缩略图显示通路（video_clk域）
//
// 本工程的帧读取是"每帧从一个bank顺序流式读出"（frame_fifo_read + video_delay），
// 不能按坐标随机取像素。所以缩略图这样实现：
//   ① mem侧（frame_fifo_read缩略图模式）：每条屏幕行读2个源行（左格图+右格图，
//      源行号=局部行*步长），每个源行640字顺序读出，写FIFO时每步长个像素只留1个，
//      FIFO里正好按显示顺序排好"左格像素+右格像素"；
//   ② 像素侧（本模块）：只在缩略图区域（x<2*THUMB_WIDTH且y<2*THUMB_HEIGHT）弹FIFO，
//      区域外/未加载格子/焦点边框在输出端直接着色。
// 默认每格320×240（2:1缩小），2×2正好铺满640×480全屏；改成160×120则只占左上角320×240区域。
// 两侧必须对同一帧使用同一个模式：本模块在"每帧最后一行有效像素结束"时锁存
// view_mode（比read_req发出早约10行），view_mode_frame 再由frame_fifo_read在
// S_ACK期间采样，两侧不会错帧。
// 转场双路读请求mix_req用同一时刻锁存为mix_mode_frame（mem侧据此决定本帧是否读B路，
// 且缩略图帧不读B路），再按同一延迟链给出B路读FIFO门控mix_rd，保证两侧同帧。
//
// 时序对齐（与video_delay一致）：输入de/vs为video_delay的输入端（第0拍），
// video_delay在第19拍读FIFO（read_en=de_d[18]），第21拍输出像素（de_r=de_d[20]）。
// 本模块在第0拍算坐标和各标志，用21位移位寄存器分别取[18]、[20]对齐。
module thumbnail_view #(
    parameter integer THUMB_WIDTH   = 320,
    parameter integer THUMB_HEIGHT  = 240,
    parameter integer V_ACTIVE      = 480,
    parameter [23:0]  BORDER_COLOR  = 24'hFFD700,   // 焦点边框：金黄色
    parameter [23:0]  PENDING_COLOR = 24'h303030    // 未加载格子占位：深灰
) (
    input  wire        clk,
    input  wire        rst_n,
    // 第0拍时序（video_timing_data输出，未经video_delay）
    input  wire        vs_in,
    input  wire        de_in,
    // 控制量（sd_card_clk域，模块内两级同步）
    input  wire        view_mode_async,
    input  wire [1:0]  focus_async,
    input  wire [3:0]  image_complete_async,
    // 读FIFO使能门控：video_delay的read_en（第19拍）→ 门控后送frame_read_write
    input  wire        read_en_in,
    output wire        read_en_out,
    // 像素：video_delay输出（第21拍）→ 缩略图着色后
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out,
    // 本帧实际生效的模式（给mem域frame_fifo_read同步采样）
    output reg         view_mode_frame,
    // 本帧模式按像素管线对齐后的版本，供双路读的B路门控与选择：
    //   thumb_rd = 与read_en_out同拍（第19拍），thumb_px = 与rgb_out同拍（第21拍）
    output wire        thumb_rd,
    output wire        thumb_px,
    // 转场双路读：mix_req为video_clk域电平（转场进行中），按帧锁存后给mem域；
    // mix_rd与read_en_out同拍，=1表示本帧B路读FIFO有数据、需要同步弹出
    input  wire        mix_req,
    output reg         mix_mode_frame,
    output wire        mix_rd
);
    // ---------------- 跨时钟域同步（慢变化电平，逐位两级打拍） ----------------
    reg       view_meta, view_sync;
    reg [1:0] focus_meta, focus_sync;
    reg [3:0] cpl_meta, cpl_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            view_meta <= 1'b0;  view_sync <= 1'b0;
            focus_meta <= 2'd0; focus_sync <= 2'd0;
            cpl_meta <= 4'd0;   cpl_sync <= 4'd0;
        end else begin
            view_meta <= view_mode_async;       view_sync <= view_meta;
            focus_meta <= focus_async;          focus_sync <= focus_meta;
            cpl_meta <= image_complete_async;   cpl_sync <= cpl_meta;
        end
    end

    // ---------------- 第0拍坐标重建 ----------------
    reg        de_d, vs_d;
    reg [11:0] x_cnt, y_cnt;
    wire       de_fall = de_d & ~de_in;
    wire       vs_fall = vs_d & ~vs_in;      // 场同步低有效，下降沿=同步开始（消隐期内）

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_d <= 1'b0;
            vs_d <= 1'b1;
            x_cnt <= 12'd0;
            y_cnt <= 12'd0;
        end else begin
            de_d <= de_in;
            vs_d <= vs_in;
            if (!de_in)
                x_cnt <= 12'd0;
            else
                x_cnt <= x_cnt + 12'd1;
            if (vs_fall)
                y_cnt <= 12'd0;
            else if (de_fall)
                y_cnt <= y_cnt + 12'd1;
        end
    end

    // ---------------- 帧边界锁存：最后一行有效像素结束时生效 ----------------
    reg [1:0] focus_frame;
    reg [3:0] cpl_frame;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            view_mode_frame <= 1'b0;
            focus_frame     <= 2'd0;
            cpl_frame       <= 4'd0;
            mix_mode_frame  <= 1'b0;
        end else if (de_fall && y_cnt == V_ACTIVE - 1) begin
            view_mode_frame <= view_sync;
            focus_frame     <= focus_sync;
            cpl_frame       <= cpl_sync;
            mix_mode_frame  <= mix_req;
        end
    end

    // ---------------- 布局与缩放坐标映射 ----------------
    // image_complete给全1：让未加载的格子也有thumb_de和焦点边框（显示占位色），
    // 加载状态在下面用cpl_frame[source_index]单独判断——本工程图片按需加载，
    // 焦点停在未加载的图上时也必须看得到焦点框。
    wire       lay_thumb_de;
    wire [1:0] lay_source_index;
    wire       lay_focus_border;

    thumbnail_layout #(
        .DISPLAY_WIDTH  (640),
        .DISPLAY_HEIGHT (480),
        .THUMB_WIDTH    (THUMB_WIDTH),
        .THUMB_HEIGHT   (THUMB_HEIGHT)
    ) u_thumbnail_layout (
        .in_de          (de_in),
        .pixel_x        (x_cnt),
        .pixel_y        (y_cnt),
        .focus_index    (focus_frame),
        .image_complete (4'b1111),
        .thumb_de       (lay_thumb_de),
        .source_index   (lay_source_index),
        .source_x       (),
        .source_y       (),
        .focus_border   (lay_focus_border)
    );

    // 第0拍各标志
    wire region0 = de_in && (x_cnt < 2 * THUMB_WIDTH) && (y_cnt < 2 * THUMB_HEIGHT);
    wire rdgate0 = view_mode_frame ? region0 : 1'b1;   // 全屏模式不门控
    wire thumb0  = view_mode_frame;
    wire tile0   = view_mode_frame & lay_thumb_de;
    wire border0 = view_mode_frame & lay_focus_border;
    wire loaded0 = cpl_frame[lay_source_index];
    wire mixrd0  = mix_mode_frame & ~view_mode_frame;   // 与mem侧 mix_en & ~thumb_mode 一致

    // ---------------- 延迟对齐 ----------------
    reg [20:0] rdgate_sr, thumb_sr, tile_sr, border_sr, loaded_sr;
    reg [18:0] mixrd_sr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mixrd_sr  <= 19'd0;
            rdgate_sr <= 21'd0;
            thumb_sr  <= 21'd0;
            tile_sr   <= 21'd0;
            border_sr <= 21'd0;
            loaded_sr <= 21'd0;
        end else begin
            mixrd_sr  <= {mixrd_sr[17:0],  mixrd0};
            rdgate_sr <= {rdgate_sr[19:0], rdgate0};
            thumb_sr  <= {thumb_sr[19:0],  thumb0};
            tile_sr   <= {tile_sr[19:0],   tile0};
            border_sr <= {border_sr[19:0], border0};
            loaded_sr <= {loaded_sr[19:0], loaded0};
        end
    end

    assign read_en_out = read_en_in & rdgate_sr[18];
    assign thumb_rd    = thumb_sr[18];
    assign mix_rd      = mixrd_sr[18];
    assign thumb_px    = thumb_sr[20];

    assign rgb_out = !thumb_sr[20]  ? rgb_in :          // 全屏：原样通过
                     border_sr[20]  ? BORDER_COLOR :    // 焦点边框
                     !tile_sr[20]   ? 24'd0 :           // 缩略图区域外：黑
                     loaded_sr[20]  ? rgb_in :          // 已加载：缩略图像素
                                      PENDING_COLOR;    // 未加载：占位
endmodule
