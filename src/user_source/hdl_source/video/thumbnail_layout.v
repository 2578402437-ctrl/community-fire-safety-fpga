// ============================================================================
// 文件名称：thumbnail_layout.v
// 模块名称：thumbnail_layout
// 功能描述：2×2缩略图布局坐标映射（纯组合逻辑）
// 目标器件：安路 EG4S20BG256
// ============================================================================
`timescale 1ns/1ps

// 2×2缩略图布局 + 4:1最近邻缩放坐标映射（纯组合逻辑）
//
// 屏幕左上 320×240 区域分成 2×2 个 160×120 的格子：
//   左上=图0  右上=图1
//   左下=图2  右下=图3
// 其余区域 thumb_de=0（上游输出黑色）。
//
// 说明（见 thumbnail_view.v）：
//   本工程的帧读取是"整帧顺序流式读出"，不能按 source_x/source_y
//   随机取像素，所以 source_x/source_y 只作
//   观测用；同样的映射（source_x=local_x*4，source_y=local_y*4）由
//   frame_fifo_read 的缩略图读地址序列 + 每4个像素保留1个的FIFO写抽取实现。
module thumbnail_layout #(
    parameter integer DISPLAY_WIDTH = 640,
    parameter integer DISPLAY_HEIGHT = 480,
    parameter integer THUMB_WIDTH = 160,
    parameter integer THUMB_HEIGHT = 120
) (
    input  wire        in_de,
    input  wire [11:0] pixel_x,
    input  wire [11:0] pixel_y,
    input  wire [1:0]  focus_index,     // 当前焦点格子（0~3）
    input  wire [3:0]  image_complete,  // 每位对应一张图是否已加载完成
    output reg         thumb_de,        // 当前像素落在已加载的缩略图格子内
    output reg  [1:0]  source_index,    // 当前像素属于哪张图
    output reg  [9:0]  source_x,        // 源图坐标（最近邻：local_x*4）
    output reg  [9:0]  source_y,        // 源图坐标（最近邻：local_y*4）
    output reg         focus_border     // 焦点格子最外圈2像素边框
);
    integer window_x;
    integer window_y;
    integer local_x;
    integer local_y;
    always @* begin
        thumb_de = 1'b0;
        source_index = 2'd0;
        source_x = 10'd0;
        source_y = 10'd0;
        focus_border = 1'b0;
        // 赋默认值，避免综合出锁存器（组合always块内的integer中间变量）
        window_x = 0;
        window_y = 0;
        local_x = 0;
        local_y = 0;
        if (in_de && pixel_x < DISPLAY_WIDTH && pixel_y < DISPLAY_HEIGHT) begin
            // 第一步：先看y定上下排（下排基础索引2），再看x定左右列（右列+1）
            source_index = (pixel_y >= THUMB_HEIGHT) ? 2'd2 : 2'd0;
            if (pixel_x >= THUMB_WIDTH)
                source_index = source_index + 1'b1;
            // 第二步：当前格子左上角坐标
            window_x = (pixel_x >= THUMB_WIDTH) ? THUMB_WIDTH : 0;
            window_y = (pixel_y >= THUMB_HEIGHT) ? THUMB_HEIGHT : 0;
            // 第三步：格子内局部坐标
            local_x = pixel_x - window_x;
            local_y = pixel_y - window_y;
            // 第四步：在格子内且图片已加载才显示
            if (local_x < THUMB_WIDTH && local_y < THUMB_HEIGHT && image_complete[source_index]) begin
                thumb_de = 1'b1;
                // 最近邻4:1缩小：每4个源像素取1个
                source_x = local_x * (640 / THUMB_WIDTH);
                source_y = local_y * (480 / THUMB_HEIGHT);
                // 焦点边框：焦点格子的最外圈2像素
                focus_border = source_index == focus_index &&
                               (local_x < 2 || local_y < 2 ||
                                local_x >= THUMB_WIDTH-2 || local_y >= THUMB_HEIGHT-2);
            end
        end
    end
endmodule
