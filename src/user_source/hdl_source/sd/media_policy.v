// ============================================================================
// 文件名称：media_policy.v
// 模块名称：media_policy
// 功能描述：媒体策略层：把按键状态翻译成播放命令（四层按键架构第三层）
// 目标器件：安路 EG4S20BG256
// ============================================================================
// 媒体策略决策层：根据按键状态决定执行什么操作
// 四层架构第三层：策略决策
//
// 功能：
// 1. 监听第二层的按键状态信息
// 2. 根据状态和系统条件，生成对应的控制命令
// 3. 所有输出都是1个时钟周期的脉冲

module media_policy #(
    // 长按KEY3时亮度调节间隔（单位：1ms节拍）
    parameter integer BRIGHTNESS_ADJUST_MS = 500
)(
    input  wire clk,
    input  wire rst,

    // === 来自 dual_key_long_hold_guard 的状态信息 ===
    input  wire [3:0]  key_state,           // 当前按键状态
    input  wire        key_state_changed,   // 状态转移事件

    // === 系统状态反馈（简化：仅用于决策前置条件）===
    input  wire        scan_done,           // SD扫描完成标志
    input  wire        display_valid,       // 显示是否有效
    input  wire        brightness_mode,     // 当前是否在亮度调节模式
    input  wire        view_mode,           // 0=全屏 1=缩略图（thumbnail_controller输出）

    // === 共享1ms节拍 ===
    input  wire        tick_1ms,            // 1ms节拍（单周期脉冲，仅在tick_req期间产生）
    output wire        tick_req,            // 亮度模式下KEY3长按连续调节时为1

    // === 策略决策输出（都是1个时钟周期脉冲） ===
    output reg         cmd_next_image,      // 下一张
    output reg         cmd_prev_image,      // 上一张
    output reg         cmd_toggle_autoplay, // 切换自动播放
    output reg         cmd_brightness_enter, // 进入亮度调节模式
    output reg         cmd_brightness_up,   // 亮度+1
    // === 缩略图交互命令 ===
    // 缩略图模式下按键改路由：KEY1短按=焦点右移，KEY2长按=焦点左移，KEY2短按=确认选中；
    // KEY1长按在两种模式下都是模式切换。
    output reg         cmd_toggle_view,     // 全屏/缩略图切换（KEY1长按）
    output reg         cmd_focus_next,      // 焦点右移
    output reg         cmd_focus_prev,      // 焦点左移
    output reg         cmd_focus_confirm    // 确认选中
);

// === 状态定义（与第二层一致）===
localparam [3:0] STATE_IDLE         = 4'd0;
localparam [3:0] STATE_KEY1_SINGLE  = 4'd1;
localparam [3:0] STATE_KEY2_SINGLE  = 4'd2;
localparam [3:0] STATE_KEY2_LONG    = 4'd3;
localparam [3:0] STATE_KEY3_SINGLE  = 4'd4;
localparam [3:0] STATE_KEY3_LONG    = 4'd5;
localparam [3:0] STATE_KEY1_LONG    = 4'd8;

// === 亮度调节时的节奏控制 ===
// 在长按调亮度时，不能每个时钟都增减，需要控制调节速度
// 使用计数器实现：每BRIGHTNESS_ADJUST_MS个1ms节拍产生一次亮度调节脉冲
localparam integer BA_W = $clog2(BRIGHTNESS_ADJUST_MS);
reg [BA_W-1:0] brightness_adjust_cnt;
wire brightness_adjusting = (key_state == STATE_KEY3_LONG) && brightness_mode;
assign tick_req = brightness_adjusting;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        cmd_next_image       <= 1'b0;
        cmd_prev_image       <= 1'b0;
        cmd_toggle_autoplay  <= 1'b0;
        cmd_brightness_enter <= 1'b0;
        cmd_brightness_up    <= 1'b0;
        cmd_toggle_view      <= 1'b0;
        cmd_focus_next       <= 1'b0;
        cmd_focus_prev       <= 1'b0;
        cmd_focus_confirm    <= 1'b0;
        brightness_adjust_cnt <= {BA_W{1'b0}};
    end else begin
        // === 清除所有输出脉冲（每个周期只产生1个周期宽） ===
        cmd_next_image       <= 1'b0;
        cmd_prev_image       <= 1'b0;
        cmd_toggle_autoplay  <= 1'b0;
        cmd_brightness_enter <= 1'b0;
        cmd_brightness_up    <= 1'b0;
        cmd_toggle_view      <= 1'b0;
        cmd_focus_next       <= 1'b0;
        cmd_focus_prev       <= 1'b0;
        cmd_focus_confirm    <= 1'b0;

        // === 亮度调节计数 ===
        if (brightness_adjusting) begin
            if (tick_1ms) begin
                if (brightness_adjust_cnt >= BRIGHTNESS_ADJUST_MS - 1)
                    brightness_adjust_cnt <= {BA_W{1'b0}};
                else
                    brightness_adjust_cnt <= brightness_adjust_cnt + 1'b1;
            end
        end else begin
            brightness_adjust_cnt <= {BA_W{1'b0}};
        end

        // === 策略决策：根据按键状态生成命令 ===

        // === 下一张：KEY1单按 ===
        // 条件检查（是否有图片）交给 media_player_control
        // 缩略图模式下改为焦点右移
        if (key_state == STATE_KEY1_SINGLE && scan_done) begin
            if (view_mode)
                cmd_focus_next <= 1'b1;
            else
                cmd_next_image <= 1'b1;
        end

        // === 全屏/缩略图切换：KEY1长按（首图显示后才有意义）===
        if (key_state == STATE_KEY1_LONG && scan_done && display_valid) begin
            cmd_toggle_view <= 1'b1;
        end

        // === 上一张：KEY2长按（只在进入长按状态时产生一个脉冲）===
        // 关键：加上 key_state_changed 条件，防止持续产生命令
        // 缩略图模式下改为焦点左移
        if (key_state == STATE_KEY2_LONG && key_state_changed && scan_done) begin
            if (view_mode)
                cmd_focus_prev <= 1'b1;
            else
                cmd_prev_image <= 1'b1;
        end

        // === 切换自动播放：KEY2短按 ===
        // 缩略图模式下改为确认选中
        if (key_state == STATE_KEY2_SINGLE && scan_done) begin
            if (view_mode)
                cmd_focus_confirm <= 1'b1;
            else
                cmd_toggle_autoplay <= 1'b1;
        end

        // === 进入/退出亮度模式：KEY3短按 ===
        if (key_state == STATE_KEY3_SINGLE && scan_done) begin
            cmd_brightness_enter <= 1'b1;
        end

        // === 调节亮度：KEY3长按，每500ms调节一次 ===
        // 在亮度模式下，通过计数器控制调节频率
        if (brightness_adjusting) begin
            if (tick_1ms && brightness_adjust_cnt >= BRIGHTNESS_ADJUST_MS - 1) begin
                // 长按期间单向递增，每次达到间隔就产生一个亮度+1脉冲
                cmd_brightness_up <= 1'b1;
            end
        end
    end
end

endmodule
