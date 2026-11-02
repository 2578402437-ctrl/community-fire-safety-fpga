// ============================================================================
// 文件名称：dual_key_long_hold_guard.v
// 模块名称：dual_key_long_hold_guard
// 功能描述：按键长按保护与状态管理（四层按键架构第二层）
// 目标器件：安路 EG4S20BG256
// ============================================================================
// 长按保护层：维护完整的按键状态机，跟踪按键生命周期
// 四层架构第二层：长按保护和状态管理
//
// 功能：
// 1. 维护按键状态机（IDLE, KEY1_SINGLE, KEY1_LONG, KEY2_SINGLE, KEY2_LONG, KEY3_SINGLE, KEY3_LONG）
// 2. 允许新按键中断旧按键状态
// 3. 为策略层提供稳定的状态信息

module dual_key_long_hold_guard #(
    parameter integer CLK_FREQ_HZ           = 100_000_000
)(
    input  wire clk,
    input  wire rst,

    // === 来自 dual_key_chord_router 的标准化事件 ===
    input  wire next_event,                 // KEY1短按
    input  wire view_toggle_event,          // KEY1长按（全屏/缩略图切换）
    input  wire prev_event,                 // KEY2长按（上一张）
    input  wire autoplay_toggle_event,      // KEY2短按（自动播放）
    input  wire brightness_enter_event,     // KEY3短按（进入亮度）
    input  wire brightness_adjust_event,    // KEY3长按（调节亮度）
    input  wire key2_released_event,        // KEY2释放事件
    input  wire key3_released_event,        // KEY3长按后释放事件

    // === 状态输出 ===
    output reg [3:0]   key_state,           // 当前按键状态
    output reg         key_state_changed    // 状态转移事件（1个周期脉冲）
);

// === 状态定义（编码与 media_policy 一致，6/7 两个组合键状态不再使用） ===
localparam [3:0] STATE_IDLE         = 4'd0;
localparam [3:0] STATE_KEY1_SINGLE  = 4'd1;
localparam [3:0] STATE_KEY2_SINGLE  = 4'd2;
localparam [3:0] STATE_KEY2_LONG    = 4'd3;
localparam [3:0] STATE_KEY3_SINGLE  = 4'd4;
localparam [3:0] STATE_KEY3_LONG    = 4'd5;
localparam [3:0] STATE_KEY1_LONG    = 4'd8;   // KEY1长按（脉冲态，下一拍回IDLE）

always @(posedge clk or posedge rst) begin
    if (rst) begin
        key_state           <= STATE_IDLE;
        key_state_changed   <= 1'b0;
    end else begin
        // === 清除脉冲信号（每个周期只产生1个周期宽） ===
        key_state_changed   <= 1'b0;

        // === 状态机主逻辑 ===
        case (key_state)
            STATE_IDLE: begin
                // 从IDLE状态，各种事件可以转移到对应状态
                if (next_event) begin
                    key_state <= STATE_KEY1_SINGLE;
                    key_state_changed <= 1'b1;
                end
                else if (view_toggle_event) begin
                    key_state <= STATE_KEY1_LONG;
                    key_state_changed <= 1'b1;
                end
                else if (prev_event) begin
                    key_state <= STATE_KEY2_LONG;
                    key_state_changed <= 1'b1;
                end
                else if (autoplay_toggle_event) begin
                    key_state <= STATE_KEY2_SINGLE;
                    key_state_changed <= 1'b1;
                end
                else if (brightness_enter_event) begin
                    key_state <= STATE_KEY3_SINGLE;
                    key_state_changed <= 1'b1;
                end
                else if (brightness_adjust_event) begin
                    key_state <= STATE_KEY3_LONG;
                    key_state_changed <= 1'b1;
                end
            end

            STATE_KEY1_SINGLE: begin
                // KEY1单按后立即返回IDLE（KEY1事件是脉冲，不需要等待释放）
                key_state <= STATE_IDLE;
                key_state_changed <= 1'b1;
            end

            STATE_KEY1_LONG: begin
                // KEY1长按事件也是脉冲，进入后立即返回IDLE
                key_state <= STATE_IDLE;
                key_state_changed <= 1'b1;
            end

            STATE_KEY2_SINGLE: begin
                // KEY2短按后立即返回IDLE
                key_state <= STATE_IDLE;
                key_state_changed <= 1'b1;
            end

            STATE_KEY2_LONG: begin
                // KEY2长按状态下，检测KEY2释放
                if (key2_released_event) begin
                    key_state <= STATE_IDLE;
                    key_state_changed <= 1'b1;
                end
                else if (next_event) begin
                    key_state <= STATE_KEY1_SINGLE;
                    key_state_changed <= 1'b1;
                end
                else if (view_toggle_event) begin
                    key_state <= STATE_KEY1_LONG;
                    key_state_changed <= 1'b1;
                end
                else if (brightness_enter_event) begin
                    key_state <= STATE_KEY3_SINGLE;
                    key_state_changed <= 1'b1;
                end
                else if (brightness_adjust_event) begin
                    key_state <= STATE_KEY3_LONG;
                    key_state_changed <= 1'b1;
                end
                // 否则继续保持KEY2_LONG状态（长按可能还在继续）
            end

            STATE_KEY3_SINGLE: begin
                // KEY3短按后立即返回IDLE
                key_state <= STATE_IDLE;
                key_state_changed <= 1'b1;
            end

            STATE_KEY3_LONG: begin
                // KEY3长按状态下，KEY3松开回IDLE（否则松手后亮度仍会持续调节），也可被其他按键中断
                if (key3_released_event) begin
                    key_state <= STATE_IDLE;
                    key_state_changed <= 1'b1;
                end
                else if (next_event) begin
                    key_state <= STATE_KEY1_SINGLE;
                    key_state_changed <= 1'b1;
                end
                else if (view_toggle_event) begin
                    key_state <= STATE_KEY1_LONG;
                    key_state_changed <= 1'b1;
                end
                else if (prev_event) begin
                    key_state <= STATE_KEY2_LONG;
                    key_state_changed <= 1'b1;
                end
                else if (autoplay_toggle_event) begin
                    key_state <= STATE_KEY2_SINGLE;
                    key_state_changed <= 1'b1;
                end
                // 否则继续保持KEY3_LONG状态
            end

            default: begin
                key_state <= STATE_IDLE;
            end
        endcase
    end
end

endmodule
