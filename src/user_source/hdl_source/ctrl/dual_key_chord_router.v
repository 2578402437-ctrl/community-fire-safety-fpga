// ============================================================================
// 文件名称：dual_key_chord_router.v
// 模块名称：dual_key_chord_router
// 功能描述：按键事件路由层：消抖并生成短按/长按事件（四层按键架构第一层）
// 目标器件：安路 EG4S20BG256
// ============================================================================
// 双键事件路由器：从原始按键信号生成标准化事件
// 四层架构第一层：事件路由层
//
// 功能：
// 1. 从原始按键信号进行消抖处理
// 2. 检测按键事件（短按、长按、组合按）
// 3. 生成标准化的1个时钟周期脉冲事件
// 4. 防止短按被长按误触发
// 5. 消抖与长按计时以共享1ms节拍tick_1ms计数；需要计时时拉高tick_req请求节拍
// 6. 短按须消抖后按住满SHORT_PRESS_MS；长按松手后RELEASE_GUARD_MS内不认短按（滤松手回弹）

module dual_key_chord_router #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter integer SHORT_PRESS_MS    = 30,      // 短按阈值（消抖后按住时长）
    parameter integer LONG_PRESS_MS     = 500,     // 长按阈值
    parameter integer DEBOUNCE_MS       = 20,      // 消抖时间
    parameter integer RELEASE_GUARD_MS  = 150      // 长按松手后屏蔽短按时间
)(
    input  wire clk,
    input  wire rst,

    // === 原始按键输入（低有效）===
    input  wire key1_in,                    // KEY1
    input  wire key2_in,                    // KEY2
    input  wire key3_in,                    // KEY3

    // === 共享1ms节拍 ===
    input  wire tick_1ms,                   // 1ms节拍（单周期脉冲，仅在tick_req期间产生）
    output wire tick_req,                   // 有按键在消抖或等待长按时为1

    // === 标准化事件输出（都是1个时钟周期的脉冲）===
    output reg  next_event,                 // 下一张（KEY1短按，松开时触发）
    output reg  view_toggle_event,          // 全屏/缩略图切换（KEY1长按）
    output reg  prev_event,                 // 上一张（KEY2长按）
    output reg  autoplay_toggle_event,      // 自动播放切换（KEY2短按）
    output reg  brightness_enter_event,     // 进入亮度调节（KEY3短按）
    output reg  brightness_adjust_event,    // 调节亮度（KEY3长按）
    output reg  key2_released_event,        // KEY2释放事件
    output reg  key3_released_event         // KEY3长按后释放事件（亮度调节结束）
);

// 计数单位为1ms节拍
localparam integer DB_W = $clog2(DEBOUNCE_MS + 1);
localparam integer LP_W = $clog2(LONG_PRESS_MS + 1);
localparam integer GD_W = $clog2(RELEASE_GUARD_MS + 1);

// === 防护标记 ===
reg key1_long_detected;
reg key2_long_detected;
reg key3_long_detected;

// === KEY1 ===
reg [1:0]  k1_sync;
reg        k1_stable;
reg [DB_W-1:0] k1_cnt;
reg        k1_last;
reg [LP_W-1:0] k1_duration;
reg        k1_long_marked;

// === KEY2 ===
reg [1:0]  k2_sync;
reg        k2_stable;
reg [DB_W-1:0] k2_cnt;
reg        k2_last;
reg [LP_W-1:0] k2_duration;
reg        k2_long_marked;

// === KEY3 ===
reg [1:0]  k3_sync;
reg        k3_stable;
reg [DB_W-1:0] k3_cnt;
reg        k3_last;
reg [LP_W-1:0] k3_duration;
reg        k3_long_marked;

// === 长按松手后屏蔽计时（非0期间不认短按）===
reg [GD_W-1:0] k1_guard;
reg [GD_W-1:0] k2_guard;
reg [GD_W-1:0] k3_guard;

// 电平正在变化（消抖中）、按下后尚未判定长按、或处于松手屏蔽期时需要节拍
assign tick_req = (k1_sync[1] != k1_stable) || (!k1_stable && !k1_long_marked) || (k1_guard != 0) ||
                  (k2_sync[1] != k2_stable) || (!k2_stable && !k2_long_marked) || (k2_guard != 0) ||
                  (k3_sync[1] != k3_stable) || (!k3_stable && !k3_long_marked) || (k3_guard != 0);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        next_event               <= 1'b0;
        view_toggle_event        <= 1'b0;
        prev_event               <= 1'b0;
        autoplay_toggle_event    <= 1'b0;
        brightness_enter_event   <= 1'b0;
        brightness_adjust_event  <= 1'b0;
        key3_released_event      <= 1'b0;

        key1_long_detected <= 1'b0;
        key2_long_detected <= 1'b0;
        key3_long_detected <= 1'b0;

        k1_sync <= 2'b11; k1_stable <= 1'b1; k1_cnt <= {DB_W{1'b0}}; k1_last <= 1'b1;
        k1_duration <= {LP_W{1'b0}}; k1_long_marked <= 1'b0;
        k2_sync <= 2'b11; k2_stable <= 1'b1; k2_cnt <= {DB_W{1'b0}}; k2_last <= 1'b1;
        k2_duration <= {LP_W{1'b0}}; k2_long_marked <= 1'b0;
        k3_sync <= 2'b11; k3_stable <= 1'b1; k3_cnt <= {DB_W{1'b0}}; k3_last <= 1'b1;
        k3_duration <= {LP_W{1'b0}}; k3_long_marked <= 1'b0;
        k1_guard <= {GD_W{1'b0}}; k2_guard <= {GD_W{1'b0}}; k3_guard <= {GD_W{1'b0}};
    end else begin
        // === 清除所有输出脉冲 ===
        next_event               <= 1'b0;
        view_toggle_event        <= 1'b0;
        prev_event               <= 1'b0;
        autoplay_toggle_event    <= 1'b0;
        brightness_enter_event   <= 1'b0;
        brightness_adjust_event  <= 1'b0;
        key2_released_event      <= 1'b0;
        key3_released_event      <= 1'b0;

        // === KEY1 消抖 ===
        k1_sync <= {k1_sync[0], key1_in};
        if (k1_sync[1] == k1_stable) begin
            k1_cnt <= {DB_W{1'b0}};
        end else begin
            if (tick_1ms) begin
                if (k1_cnt >= DEBOUNCE_MS - 1) begin
                    k1_stable <= k1_sync[1];
                    k1_cnt <= {DB_W{1'b0}};
                end else begin
                    k1_cnt <= k1_cnt + 1'b1;
                end
            end
        end

        // KEY1 区分短按/长按：短按在
        // "松开时且未达到长按"时触发（与KEY2同一套写法），长按在按住满LONG_PRESS_MS时触发一次。
        if (!k1_stable) begin
            if (tick_1ms && k1_duration < LONG_PRESS_MS)
                k1_duration <= k1_duration + 1'b1;
            if (k1_duration >= LONG_PRESS_MS && !k1_long_marked) begin
                view_toggle_event <= 1'b1;
                k1_long_marked <= 1'b1;
                key1_long_detected <= 1'b1;
            end
        end else begin
            if (!k1_last && !k1_long_marked && k1_duration >= SHORT_PRESS_MS && k1_guard == 0)
                next_event <= 1'b1;
            k1_duration <= {LP_W{1'b0}};
            k1_long_marked <= 1'b0;
        end

        // 长按松手起屏蔽RELEASE_GUARD_MS，期间回弹出的短按不触发
        if (k1_stable && !k1_last && k1_long_marked)
            k1_guard <= RELEASE_GUARD_MS;
        else if (tick_1ms && k1_guard != 0)
            k1_guard <= k1_guard - 1'b1;

        if (k1_stable && key1_long_detected)
            key1_long_detected <= 1'b0;
        k1_last <= k1_stable;

        // === KEY2 消抖 ===
        k2_sync <= {k2_sync[0], key2_in};
        if (k2_sync[1] == k2_stable) begin
            k2_cnt <= {DB_W{1'b0}};
        end else begin
            if (tick_1ms) begin
                if (k2_cnt >= DEBOUNCE_MS - 1) begin
                    k2_stable <= k2_sync[1];
                    k2_cnt <= {DB_W{1'b0}};
                end else begin
                    k2_cnt <= k2_cnt + 1'b1;
                end
            end
        end

        // KEY2 按下时累计时长
        if (!k2_stable) begin
            if (tick_1ms && k2_duration < LONG_PRESS_MS)
                k2_duration <= k2_duration + 1'b1;
            // 达到长按时间且未标记过长按时，产生长按脉冲并标记
            if (k2_duration >= LONG_PRESS_MS && !k2_long_marked) begin
                prev_event <= 1'b1;      // 产生一个时钟周期的脉冲
                k2_long_marked <= 1'b1;  // 标记已触发，防止重复
                key2_long_detected <= 1'b1;
            end
        end else begin  // KEY2松开
            // 短按逻辑：如果长按标记未置1，说明是短按
            if (!k2_last && !k2_long_marked && k2_duration >= SHORT_PRESS_MS && k2_guard == 0)
                autoplay_toggle_event <= 1'b1;
            // 长按松开逻辑：如果长按标记已置1，产生释放事件
            else if (!k2_last && k2_long_marked)
                key2_released_event <= 1'b1;
            k2_duration <= {LP_W{1'b0}};
            k2_long_marked <= 1'b0;
        end

        if (k2_stable && !k2_last && k2_long_marked)
            k2_guard <= RELEASE_GUARD_MS;
        else if (tick_1ms && k2_guard != 0)
            k2_guard <= k2_guard - 1'b1;

        if (k2_stable && key2_long_detected)
            key2_long_detected <= 1'b0;
        k2_last <= k2_stable;

        // === KEY3 消抖 ===
        k3_sync <= {k3_sync[0], key3_in};
        if (k3_sync[1] == k3_stable) begin
            k3_cnt <= {DB_W{1'b0}};
        end else begin
            if (tick_1ms) begin
                if (k3_cnt >= DEBOUNCE_MS - 1) begin
                    k3_stable <= k3_sync[1];
                    k3_cnt <= {DB_W{1'b0}};
                end else begin
                    k3_cnt <= k3_cnt + 1'b1;
                end
            end
        end

        // KEY3 按下时累计时长
        if (!k3_stable) begin
            if (tick_1ms && k3_duration < LONG_PRESS_MS)
                k3_duration <= k3_duration + 1'b1;
            if (k3_duration >= LONG_PRESS_MS && !k3_long_marked) begin
                if (k2_stable)
                    brightness_adjust_event <= 1'b1;  // 单独KEY3长按（按住KEY2时不算）
                k3_long_marked <= 1'b1;
                key3_long_detected <= 1'b1;
            end
        end else begin
            if (!k3_last && !k3_long_marked && k2_stable && k3_duration >= SHORT_PRESS_MS && k3_guard == 0)
                brightness_enter_event <= 1'b1;  // 短按
            // 长按松开：通知第二层退出KEY3_LONG，停止连续调节亮度
            else if (!k3_last && k3_long_marked)
                key3_released_event <= 1'b1;
            k3_duration <= {LP_W{1'b0}};
            k3_long_marked <= 1'b0;
        end

        if (k3_stable && !k3_last && k3_long_marked)
            k3_guard <= RELEASE_GUARD_MS;
        else if (tick_1ms && k3_guard != 0)
            k3_guard <= k3_guard - 1'b1;

        if (k3_stable && key3_long_detected)
            key3_long_detected <= 1'b0;
        k3_last <= k3_stable;
    end
end

endmodule
