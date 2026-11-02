// ============================================================================
// 文件名称：thumbnail_controller.v
// 模块名称：thumbnail_controller
// 功能描述：缩略图交互控制：全屏/缩略图模式切换、焦点移动与快速选择
// 目标器件：安路 EG4S20BG256
// ============================================================================
`timescale 1ns/1ps

// 缩略图交互控制器（全屏/缩略图模式切换 + 焦点移动 + 快速选择）
// 设计要点：
//   - 按键输入不是原始消抖脉冲，而是 media_policy 在缩略图模式下改路由后的命令脉冲；
//   - 本工程图片是"按需从TF卡加载到常驻bank"，没有预先全部加载，所以快速选择
//     不直接改 active_index，而是发 select_req 给 media_player_control：它把目标图
//     预加载到对应bank（缩略图照常显示），就绪后直接提交显示bank（硬切，不走转场），
//     等显示bank在读侧生效后发 select_done（接本模块 switch_grant 端口），此时切回全屏，
//     第一帧全屏就是新图；预加载失败也发 select_done，回到全屏旧图；
//   - 确认键的门控条件为"该位置扫描到了图片"（focus<image_count），
//     未加载的图也能被选中（选中即加载）；
//   - "帧边界生效"在像素域完成（thumbnail_view 在每帧最后一行结束时锁存 view_mode/
//     focus_index），本模块在 sd_card_clk 域，不需要 frame_start。
//
// 模块在 sd_card_clk 域，所有输入都是同域单周期脉冲/电平。
module thumbnail_controller (
    input  wire        clk,
    input  wire        rst,
    input  wire        key_right,       // 焦点右移（缩略图模式下KEY1短按）
    input  wire        key_left,        // 焦点左移（缩略图模式下KEY2长按）
    input  wire        key_confirm,     // 选中焦点并全屏（缩略图模式下KEY2短按）
    input  wire        key_mode,        // 全屏/缩略图切换（KEY1长按）
    input  wire        display_ready,   // 首图已提交（display_valid）
    input  wire [2:0]  image_count,     // 扫描到的图片数（0~4）
    input  wire [1:0]  current_index,   // 当前全屏显示的图片编号
    input  wire        switch_grant,    // 选图结束（media_player_control的select_done）
    input  wire        fade_busy,       // 转场进行中
    output reg         view_mode,       // 0=全屏 1=缩略图
    output reg  [1:0]  focus_index,     // 焦点位置（0=左上 1=右上 2=左下 3=右下）
    output reg         select_req,      // 快速选择请求（单周期脉冲）
    output reg  [1:0]  select_index     // 快速选择目标图片编号
);
    reg exit_pending;   // 已发出快速选择，等待选图结束再切回全屏

    // 焦点在"已扫描到的图片"范围内循环：右移到末尾回0，左移到0回末尾
    wire [2:0] focus_plus1  = {1'b0, focus_index} + 3'd1;
    wire [1:0] focus_next   = (focus_plus1 >= image_count) ? 2'd0 : focus_plus1[1:0];
    wire [1:0] focus_prev   = (focus_index == 2'd0) ? (image_count[1:0] - 2'd1) : (focus_index - 2'd1);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            view_mode    <= 1'b0;
            focus_index  <= 2'd0;
            select_req   <= 1'b0;
            select_index <= 2'd0;
            exit_pending <= 1'b0;
        end else begin
            select_req <= 1'b0;

            if (!display_ready) begin
                // 首图未提交/SD重新初始化：强制回全屏
                view_mode    <= 1'b0;
                exit_pending <= 1'b0;
            end else begin
                // === 模式键：全屏↔缩略图 ===
                if (key_mode) begin
                    if (!view_mode) begin
                        view_mode   <= 1'b1;
                        focus_index <= current_index;   // 进入时焦点落在当前图上
                    end else begin
                        view_mode   <= 1'b0;            // 返回全屏，不切换图片
                    end
                    exit_pending <= 1'b0;
                end

                // === 焦点移动：只在缩略图模式且未处于选择过程中响应 ===
                if (view_mode && !exit_pending && image_count != 3'd0) begin
                    if (key_right)
                        focus_index <= focus_next;
                    else if (key_left)
                        focus_index <= focus_prev;
                end

                // === 快速选择 ===
                if (view_mode && !exit_pending && key_confirm && !fade_busy) begin
                    if (focus_index == current_index) begin
                        view_mode <= 1'b0;              // 选的就是当前图：直接回全屏
                    end else if ({1'b0, focus_index} < image_count) begin
                        select_req   <= 1'b1;
                        select_index <= focus_index;
                        exit_pending <= 1'b1;
                    end
                end

                // === 选图结束：显示bank已是新图（或放弃仍为旧图），切回全屏 ===
                if (exit_pending && switch_grant) begin
                    view_mode    <= 1'b0;
                    exit_pending <= 1'b0;
                end
            end
        end
    end
endmodule
