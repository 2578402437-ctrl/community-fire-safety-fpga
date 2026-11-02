// ============================================================================
// 文件名称：sd_card_bmp_v2.v
// 模块名称：sd_card_bmp_v2
// 功能描述：SD卡媒体播放子系统：按键处理、图片加载、WAV播放与掉电保存的集成模块
// 目标器件：安路 EG4S20BG256
// ============================================================================
// 集成四层按键处理架构的SD卡BMP媒体播放模块
// 架构：dual_key_chord_router → dual_key_long_hold_guard → media_policy → media_player_control

module sd_card_bmp_v2 #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4,
    parameter integer AUTO_PLAY_MS      = 2500,
    parameter integer LOAD_TIMEOUT_MS   = 6000,    // 大图(如1920×1080约6MB)读取需2~3秒，超时阈值过小会误判超时
    parameter integer FRAME_PIXELS      = 307200,  // 640*480，一帧的像素数
    parameter integer MAX_RETRIES       = 1,       // BMP内容错误/加载超时的重试次数上限
    // === 任意分辨率适配 ===
    parameter integer KEEP_ASPECT       = 1,       // 1=保持宽高比（黑边居中） 0=拉伸到640×480
    parameter integer MAX_SRC_DIM       = 2048,    // 源图宽高上限（2048×2048约12MB，再大读取时间过长）
    // === WAV音频流式播放 ===
    // 音频数据区间（PC工具转码后的裸16位PCM，48kHz单声道，小端序），
    // 由使用者根据实际TF卡布局填写。默认0/0表示未配置，功能保持关闭，
    // 不影响图片浏览功能。
    // WAV_START_LBA/WAV_TOTAL_SECTORS为背景音乐（拨码全关时循环播放），
    // 另有两段报警音：SW1/SW2/SW1+SW2拨上播ALARM1，SW3拨上播ALARM2（SW3优先）。
    // 某段未配置（扇区数为0）时，对应拨码状态下不播放WAV（回落到琶音）。
    parameter [31:0]  WAV_START_LBA     = 32'd0,
    parameter [31:0]  WAV_TOTAL_SECTORS = 32'd0,
    parameter [31:0]  WAV_ALARM1_START_LBA     = 32'd0,
    parameter [31:0]  WAV_ALARM1_TOTAL_SECTORS = 32'd0,
    parameter [31:0]  WAV_ALARM2_START_LBA     = 32'd0,
    parameter [31:0]  WAV_ALARM2_TOTAL_SECTORS = 32'd0,
    // 四个栏目的"背景音乐+宣传语音"预混段：首张浏览图提交后按当前图片编号0~3播放，
    // 代替背景音乐；某段未配置（扇区数为0）时该栏目回落到背景音乐。
    parameter [31:0]  WAV_COL0_START_LBA     = 32'd0,
    parameter [31:0]  WAV_COL0_TOTAL_SECTORS = 32'd0,
    parameter [31:0]  WAV_COL1_START_LBA     = 32'd0,
    parameter [31:0]  WAV_COL1_TOTAL_SECTORS = 32'd0,
    parameter [31:0]  WAV_COL2_START_LBA     = 32'd0,
    parameter [31:0]  WAV_COL2_TOTAL_SECTORS = 32'd0,
    parameter [31:0]  WAV_COL3_START_LBA     = 32'd0,
    parameter [31:0]  WAV_COL3_TOTAL_SECTORS = 32'd0,
    // 每段一遍语音的采样数（0=该栏目不跟随语音，自动播放按AUTO_PLAY_MS定时）
    parameter [31:0]  WAV_COL0_VOICE_SAMPLES = 32'd0,
    parameter [31:0]  WAV_COL1_VOICE_SAMPLES = 32'd0,
    parameter [31:0]  WAV_COL2_VOICE_SAMPLES = 32'd0,
    parameter [31:0]  WAV_COL3_VOICE_SAMPLES = 32'd0,
    // 开机问候（背景乐+问候语音预混的裸PCM段），开机动画开始行走时播一遍；0=不播
    parameter [31:0]  WAV_INTRO_START_LBA     = 32'd0,
    parameter [31:0]  WAV_INTRO_TOTAL_SECTORS = 32'd0
)(
    input                       clk,
    input                       rst,
    input                       sdram_ready,   // SDRAM初始化完成（已跨时钟域同步到本域）
    input                       key_next,      // KEY1: 下一张
    input                       key_auto,      // KEY2: 上一张/自动播放
    input                       key_vol,       // KEY3: 亮度调节
    input  [2:0]                sw_in,         // 拨码开关SW1~SW3（异步，拨上=1），选择SW*.BMP直显

    input  [15:0]               bmp_width,     // 显示分辨率（缩放目标），源图分辨率可与之不同
    input  [15:0]               bmp_height,
    output wire                 display_valid,

    input                       write_finish_toggle,
    output wire [1:0]           write_buf_idx,
    output wire [1:0]           disp_buf_idx,
    output wire [3:0]           state_code,

    // === 转场控制握手（与顶层video_fade_transition，同clk域）===
    input  wire                 switch_grant,       // 转场合成完成（整幅新图），提交显示bank
    input  wire                 fade_busy_in,       // 转场进行中，忽略新的手动切换请求
    output wire                 switch_request,     // 切换请求脉冲（新图已就绪，触发转场合成）
    output wire                 disp_commit_toggle, // disp_buf_idx每次真正提交时翻转
    output wire [1:0]           prev_disp_buf_idx,  // disp_buf_idx的前一周期影子值
    output wire [1:0]           mix_buf_idx,        // 转场B路bank号（目标图）

    // OSD状态叠加用：当前图片序号/自动播放/错误码
    output wire [1:0]           osd_img_idx,
    output wire                 osd_auto_play_en,
    output wire [7:0]           osd_error_code,
    output wire                 osd_sw_hold,    // 1=拨码硬切模式，顶层据此隐藏OSD与滚动字幕
    output wire                 osd_sw_shown_valid, // 1=SW*.BMP已真正显示（clk域），顶层据此做紧急元素闪烁
    output wire [1:0]           osd_sw_shown_idx,   // 当前显示的SW图 0=SW1 1=SW2 2=SW3 3=SW12（clk域）
    output wire                 osd_sw_on_screen,   // 1=屏幕上正显示SW图（clk域），顶层据此让亮度固定最大
    output wire                 osd_wav_alarm,      // 1=当前播放报警曲目（clk域），顶层据此让音量固定最大
    output wire [1:0]           osd_nav_idx,        // 导航栏目标栏目（clk域），顶层同步后驱动消防员行走导航栏
    // === 开机动画背景握手（BG.BMP）===
    output wire                 intro_bg_shown,     // 1=显示bank里是BG.BMP（首图提交前，clk域）
    output wire                 intro_pic_ready,    // 1=PIC1已加载完、等开机动画放行提交（clk域）
    output wire                 first_committed,    // 1=首张浏览图已提交（clk域）
    input  wire                 intro_commit_req,   // 开机动画请求提交首图（video_clk域电平，本模块内同步）
    input  wire                 intro_walk,         // 开机动画消防员行走中（video_clk域电平，本模块内同步）
    output wire [3:0]           brightness_level, // KEY3亮度等级0~15（clk域），顶层同步后折进转场alpha
    output wire                 brightness_mode,  // 1=亮度调节模式（clk域），顶层据此显示中央亮度进度条
    output wire [3:0]           volume_level,     // KEY3音量等级0~15（clk域），顶层同步后作用于音频增益
    output wire                 volume_mode,      // 1=音量调节模式（clk域），顶层据此显示中央音量进度条
    output wire                 sd_ready,         // SD卡初始化完成（clk域），顶层据此判断是否显示SD卡故障提示图

    // === 板载用户 SPI Flash（W25Q64），掉电保存亮度/音量等级 ===
    output wire                 flash_cs_n,
    output wire                 flash_sclk,
    output wire                 flash_mosi,
    input  wire                 flash_miso,

    // === 缩略图显示状态（本clk域，顶层同步到video_clk域）===
    output wire                 view_mode,      // 0=全屏 1=缩略图
    output wire [1:0]           focus_index,    // 缩略图焦点位置
    output wire [3:0]           image_complete, // 各bank是否持有已加载完成的图片

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO,

    // 诊断：dbg_page选页，dbg_digits为6个4位十六进制数字（[23:20]显示在最左）
    input  wire [1:0]           dbg_page,
    output wire [23:0]          dbg_digits,

    // === WAV音频流式播放接口（读侧为独立时钟域） ===
    input  wire                 rd_clk,          // 音频链时钟（本工程为video_clk）
    input  wire                 rd_rst_n,        // 音频链复位（本工程为video_rst_n）
    input  wire                 sample_tick,     // 约48kHz采样节拍（rd_clk域）
    output wire signed [15:0]   wav_sample_out,  // rd_clk域，16位有符号PCM样本
    output wire                 wav_sample_valid,
    output wire                 wav_stream_active
);

// ============= 四层架构信号定义 =============

// 第一层输出：dual_key_chord_router
wire  next_event;
wire  view_toggle_event;   // KEY1长按
wire  prev_event;
wire  autoplay_toggle_event;
wire  brightness_enter_event;
wire  brightness_adjust_event;
wire  key2_released_event;
wire  key3_released_event;

// 共享1ms节拍：各层计时请求与节拍
wire  key_tick_req;
wire  policy_tick_req;
wire  mpc_tick_req;
reg   tick_1ms;

// 第二层输出：dual_key_long_hold_guard
wire [3:0]  key_state;
wire        key_state_changed;

// 第三层输出：media_policy
wire  cmd_next_image;
wire  cmd_prev_image;
wire  cmd_toggle_autoplay;
wire  cmd_brightness_enter;
wire  cmd_brightness_up;
wire  cmd_toggle_view;     // 缩略图交互命令
wire  cmd_focus_next;
wire  cmd_focus_prev;
wire  cmd_focus_confirm;

// thumbnail_controller输出 / media_player_control输出
wire         tc_select_req;
wire         mpc_select_done;   // 缩略图选图结束（硬切完成或放弃）
wire [1:0]   tc_select_index;
wire [2:0]   mpc_image_count;

// 第四层输出：media_player_control
wire         mpc_scan_start_pulse;
wire         mpc_load_start_pulse;
wire [31:0]  mpc_load_sector;
wire [1:0]   mpc_write_buf_idx;
wire [1:0]   mpc_disp_buf_idx;
wire [1:0]   mpc_img_idx;
wire [3:0]   mpc_brightness_level;
wire         mpc_brightness_mode;
wire [3:0]   mpc_volume_level;
wire         mpc_volume_mode;
wire         mpc_display_valid;
wire         mpc_auto_play_en;
wire         col_voice_sync_en, col_voice_track_ok, col_voice_gap;   // 自动播放跟随栏目语音（定义见WAV曲目选择之后）
wire [3:0]   mpc_state_code;
wire [7:0]   mpc_last_error_code;

// 拨码开关直显
wire [3:0]   scan_sw_valid;            // 扫描到的SW1/SW2/SW3/SW12.BMP
wire [31:0]  sw0_cluster, sw1_cluster, sw2_cluster, sw3_cluster;
wire [31:0]  sw0_size,    sw1_size,    sw2_size,    sw3_size;
wire         sw_hold;

// 开机动画背景 BG.BMP
wire         scan_bg_valid;
wire [31:0]  bg_cluster, bg_size;
reg  [1:0]   intro_req_sync;           // intro_commit_req 两级同步
reg  [1:0]   intro_walk_sync;          // intro_walk 两级同步
always @(posedge clk or posedge rst) begin
    if (rst) begin
        intro_req_sync  <= 2'b00;
        intro_walk_sync <= 2'b00;
    end else begin
        intro_req_sync  <= {intro_req_sync[0], intro_commit_req};
        intro_walk_sync <= {intro_walk_sync[0], intro_walk};
    end
end
reg          sw_sel_valid;
reg  [1:0]   sw_sel_idx;

// === BMP内容级错误（头校验/像素完整性），由下方BMP解码逻辑驱动 ===
wire         bmp_load_error;
wire [7:0]   bmp_load_error_code;

// ============= 底层模块信号 =============
wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire             sd_init_done;

// 送给media_player_control的信号
reg              bmp_data_wr_en;
reg  [23:0]      bmp_data;
wire             bmp_ready;
reg              scan_done;
reg              scan_found_valid;
reg  [31:0]      scan_found_sector;
wire [2:0]       scan_found_total;

// ============= 输出连接 =============
assign write_en   = bmp_data_wr_en;
assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};

assign write_buf_idx  = mpc_write_buf_idx;
assign disp_buf_idx   = mpc_disp_buf_idx;
assign display_valid  = mpc_display_valid;
assign state_code     = mpc_state_code;

assign osd_img_idx      = mpc_img_idx;
assign sd_ready         = sd_init_done;
assign osd_auto_play_en = mpc_auto_play_en;
assign osd_sw_hold      = sw_hold;
assign brightness_level = mpc_brightness_level;
assign brightness_mode  = mpc_brightness_mode;
assign volume_level     = mpc_volume_level;
assign volume_mode      = mpc_volume_mode;

// ============= 第一层：双键事件路由 =============
// 从原始按键信号生成标准化事件，包含消抖逻辑
dual_key_chord_router #(
    .CLK_FREQ_HZ              (CLK_FREQ_HZ),
    .SHORT_PRESS_MS           (30),
    .LONG_PRESS_MS            (500),
    .DEBOUNCE_MS              (20),
    .RELEASE_GUARD_MS         (150)
) u_dual_key_chord_router (
    .clk                      (clk),
    .rst                      (rst),
    .key1_in                  (key_next),
    .key2_in                  (key_auto),
    .key3_in                  (key_vol),
    .tick_1ms                 (tick_1ms),
    .tick_req                 (key_tick_req),
    .next_event               (next_event),
    .view_toggle_event        (view_toggle_event),
    .prev_event               (prev_event),
    .autoplay_toggle_event    (autoplay_toggle_event),
    .brightness_enter_event   (brightness_enter_event),
    .brightness_adjust_event  (brightness_adjust_event),
    .key2_released_event      (key2_released_event),
    .key3_released_event      (key3_released_event)
);

// ============= 第二层：长按保护 =============
dual_key_long_hold_guard u_dual_key_long_hold_guard (
    .clk                      (clk),
    .rst                      (rst),
    .next_event               (next_event),
    .view_toggle_event        (view_toggle_event),
    .prev_event               (prev_event),
    .autoplay_toggle_event    (autoplay_toggle_event),
    .brightness_enter_event   (brightness_enter_event),
    .brightness_adjust_event  (brightness_adjust_event),
    .key2_released_event      (key2_released_event),
    .key3_released_event      (key3_released_event),
    .key_state                (key_state),
    .key_state_changed        (key_state_changed)
);

// ============= 第三层：媒体策略 =============
media_policy u_media_policy (
    .clk                      (clk),
    .rst                      (rst),
    .key_state                (key_state),
    .key_state_changed        (key_state_changed),
    .scan_done                (scan_done),
    .display_valid            (mpc_display_valid),
    .brightness_mode          (mpc_brightness_mode | mpc_volume_mode),  // 两种调节模式共用KEY3长按连续调节
    .view_mode                (view_mode),
    .tick_1ms                 (tick_1ms),
    .tick_req                 (policy_tick_req),
    .cmd_next_image           (cmd_next_image),
    .cmd_prev_image           (cmd_prev_image),
    .cmd_toggle_autoplay      (cmd_toggle_autoplay),
    .cmd_brightness_enter     (cmd_brightness_enter),
    .cmd_brightness_up        (cmd_brightness_up),
    .cmd_toggle_view          (cmd_toggle_view),
    .cmd_focus_next           (cmd_focus_next),
    .cmd_focus_prev           (cmd_focus_prev),
    .cmd_focus_confirm        (cmd_focus_confirm)
);

// ============= 缩略图交互控制（第三层与第四层之间）=============
// 管理全屏/缩略图模式和焦点；快速选择发select_req给第四层，第四层预加载后硬切，
// 再用select_done通知本模块回全屏（接在原switch_grant端口上）。
thumbnail_controller u_thumbnail_controller (
    .clk                      (clk),
    .rst                      (rst),
    .key_right                (cmd_focus_next),
    .key_left                 (cmd_focus_prev),
    .key_confirm              (cmd_focus_confirm),
    .key_mode                 (cmd_toggle_view),
    .display_ready            (mpc_display_valid && !sw_hold),   // 拨码模式下强制回全屏
    .image_count              (mpc_image_count),
    .current_index            (mpc_img_idx),
    .switch_grant             (mpc_select_done),
    .fade_busy                (fade_busy_in),
    .view_mode                (view_mode),
    .focus_index              (focus_index),
    .select_req               (tc_select_req),
    .select_index             (tc_select_index)
);

// ============= 亮度/音量掉电保存 =============
// 上电读回上次保存的等级送执行层；之后等级变化并停手2秒自动写入Flash。
wire       cfg_load;
wire [3:0] cfg_brightness;
wire [3:0] cfg_volume;

level_flash_store #(
    .CLK_FREQ_HZ      (CLK_FREQ_HZ)
) u_level_flash_store (
    .clk              (clk),
    .rst              (rst),
    .brightness_level (mpc_brightness_level),
    .volume_level     (mpc_volume_level),
    .cfg_load         (cfg_load),
    .cfg_brightness   (cfg_brightness),
    .cfg_volume       (cfg_volume),
    .flash_cs_n       (flash_cs_n),
    .flash_sclk       (flash_sclk),
    .flash_mosi       (flash_mosi),
    .flash_miso       (flash_miso)
);

// ============= 第四层：媒体播放执行 =============
media_player_control #(
    .CLK_FREQ_HZ              (CLK_FREQ_HZ),
    .AUTO_PLAY_MS             (AUTO_PLAY_MS),
    .LOAD_TIMEOUT_MS          (LOAD_TIMEOUT_MS),
    .MAX_RETRIES              (MAX_RETRIES)
) u_media_player_control (
    .clk                      (clk),
    .rst                      (rst),
    .cmd_next_image           (cmd_next_image),
    .cmd_prev_image           (cmd_prev_image),
    .cmd_toggle_autoplay      (cmd_toggle_autoplay),
    .cmd_brightness_enter     (cmd_brightness_enter),
    .cmd_brightness_up        (cmd_brightness_up),
    .cfg_load                 (cfg_load),
    .cfg_brightness           (cfg_brightness),
    .cfg_volume               (cfg_volume),
    .tick_1ms                 (tick_1ms),
    .tick_req                 (mpc_tick_req),
    .cmd_select_image         (tc_select_req),
    .sw_sel_valid             (sw_sel_valid),
    .sw_sel_idx               (sw_sel_idx),
    .sw_hold                  (sw_hold),
    .sw_shown_valid           (osd_sw_shown_valid),
    .sw_shown_idx             (osd_sw_shown_idx),
    .sw_on_screen             (osd_sw_on_screen),
    .nav_target_idx           (osd_nav_idx),
    .bg_valid                 (scan_bg_valid),
    .intro_commit_req         (intro_req_sync[1]),
    .intro_bg_shown           (intro_bg_shown),
    .intro_pic_ready          (intro_pic_ready),
    .first_committed          (first_committed),
    .select_index             (tc_select_index),
    .view_mode                (view_mode),
    .scan_found_valid         (scan_found_valid),
    .scan_found_sector        (scan_found_sector),
    .scan_found_total         (scan_found_total),
    .sd_init_done             (sd_init_done),
    .bmp_ready                (bmp_ready),
    .sdram_ready              (sdram_ready),
    .scan_done                (scan_done),
    .write_finish_toggle      (write_finish_toggle),
    .bmp_data_wr_en           (bmp_data_wr_en),
    .bmp_data                 (bmp_data),
    .load_error               (bmp_load_error),
    .bmp_error_code           (bmp_load_error_code),
    .write_buf_idx            (mpc_write_buf_idx),
    .disp_buf_idx             (mpc_disp_buf_idx),
    .img_idx                  (mpc_img_idx),
    .brightness_level         (mpc_brightness_level),
    .brightness_mode          (mpc_brightness_mode),
    .volume_level             (mpc_volume_level),
    .volume_mode              (mpc_volume_mode),
    .display_valid            (mpc_display_valid),
    .auto_play_en             (mpc_auto_play_en),
    .scan_start_pulse         (mpc_scan_start_pulse),
    .load_start_pulse         (mpc_load_start_pulse),
    .load_sector              (mpc_load_sector),
    .state_code               (mpc_state_code),
    .last_error_code          (mpc_last_error_code),
    .image_complete           (image_complete),
    .image_count              (mpc_image_count),

    .switch_grant             (switch_grant),
    .fade_busy_in             (fade_busy_in),
    .switch_request           (switch_request),
    .disp_commit_toggle       (disp_commit_toggle),
    .prev_disp_buf_idx        (prev_disp_buf_idx),
    .mix_buf_idx              (mix_buf_idx),
    .select_done              (mpc_select_done),
    .voice_sync_en            (col_voice_sync_en),
    .voice_track_ok           (col_voice_track_ok),
    .voice_gap                (col_voice_gap)
);

// ============= 拨码开关 → SW*.BMP 直显 =============
// 开关两级同步后消抖20ms；按优先级解析：
//   SW3拨上 → SW3.BMP；否则SW1+SW2都拨上 → SW12.BMP；否则SW1 → SW1.BMP；否则SW2 → SW2.BMP；
//   全部拨下 → 回到PIC1~4浏览。对应文件不存在时当作没拨（保持浏览）。
localparam integer SW_DEBOUNCE_MS = 20;
reg [2:0]  sw_meta, sw_sync, sw_stable;
reg [4:0]  sw_db_cnt;          // 1ms节拍计数

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sw_meta   <= 3'd0;
        sw_sync   <= 3'd0;
        sw_stable <= 3'd0;
        sw_db_cnt <= 5'd0;
    end else begin
        sw_meta <= sw_in;
        sw_sync <= sw_meta;
        if (sw_sync == sw_stable)
            sw_db_cnt <= 5'd0;
        else if (tick_1ms) begin
            if (sw_db_cnt >= SW_DEBOUNCE_MS - 1) begin
                sw_stable <= sw_sync;
                sw_db_cnt <= 5'd0;
            end else
                sw_db_cnt <= sw_db_cnt + 5'd1;
        end
    end
end

// ============= 共享1ms节拍（按需运行）=============
// 按键消抖/长按、拨码消抖、亮度连调、自动轮播、加载超时共用同一个分频器。
// 没有任何模块请求时分频计数器清零停止；请求开始后满1ms产生第一个节拍。
localparam integer TICK_DIV = CLK_FREQ_HZ / 1000;
localparam integer TICK_W   = $clog2(TICK_DIV);
reg  [TICK_W-1:0] tick_div_cnt;
wire tick_req_any = key_tick_req || policy_tick_req || mpc_tick_req || (sw_sync != sw_stable);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        tick_div_cnt <= {TICK_W{1'b0}};
        tick_1ms     <= 1'b0;
    end else if (!tick_req_any) begin
        tick_div_cnt <= {TICK_W{1'b0}};
        tick_1ms     <= 1'b0;
    end else if (tick_div_cnt == TICK_DIV - 1) begin
        tick_div_cnt <= {TICK_W{1'b0}};
        tick_1ms     <= 1'b1;
    end else begin
        tick_div_cnt <= tick_div_cnt + 1'b1;
        tick_1ms     <= 1'b0;
    end
end

always @(*) begin
    sw_sel_valid = 1'b0;
    sw_sel_idx   = 2'd0;
    if (sw_stable[2]) begin
        sw_sel_valid = scan_sw_valid[2];  sw_sel_idx = 2'd2;      // SW3
    end else if (sw_stable[0] && sw_stable[1]) begin
        sw_sel_valid = scan_sw_valid[3];  sw_sel_idx = 2'd3;      // SW1+SW2
    end else if (sw_stable[0]) begin
        sw_sel_valid = scan_sw_valid[0];  sw_sel_idx = 2'd0;      // SW1
    end else if (sw_stable[1]) begin
        sw_sel_valid = scan_sw_valid[1];  sw_sel_idx = 2'd1;      // SW2
    end
end

// =====================================================================
// FAT32文件系统读取集成层
//
// 本集成层需要完成以下4处适配，否则会出现"有声音、永久黑屏"：
//
//   1. write_req握手：本层必须驱动SDRAM帧写请求的握手
//      （举write_req → 等write_req_ack → 再送像素）。若无驱动者，
//      frame_fifo_write会永远停在S_IDLE：不锁写地址、不发突发、
//      write_finish永不触发 → display_valid恒0 → 画面被钉死成全黑。
//
//   2. scan_done脉冲转电平：fat32_volume_scanner的scan_done只有1个周期
//      （ST_FINISH置1后立刻回ST_IDLE），而
//      media_player_control按电平使用（cmd_next_image && scan_done），
//      直连会让按键切换和上电自动加载全部失效。
//
//   3. bmp_ready极性：ready需在空闲时为1（上电即为1），
//      media_player_control靠它触发上电扫描（!scan_kicked && bmp_ready）。
//      FAT32的file_done是"读完"脉冲，上电为0，不能直接作为ready，
//      这里取 sd_init_done && 源空闲。
//
//   4. 资源发现脉冲串：media_player_control用scan_found_valid脉冲逐个
//      缓存img_sector0~3并累加img_found_count，而扫描器是4组并行寄存器。
//      这里把resource_valid展开成脉冲串，scan_found_sector传"资源序号"
//      作为不透明句柄，再由句柄查簇号/文件大小。
// =====================================================================

// ---- 扫描器输出 ----
wire        scanner_busy;
wire        scanner_done_pulse;
wire [7:0]  scanner_fs_error;
wire [7:0]  streamer_fs_error;
wire [7:0]  scanner_spc;
wire [31:0] scanner_fat_start;
wire [31:0] scanner_data_start;
wire [31:0] scanner_max_cluster;
wire [3:0]  scan_resource_valid;
wire [31:0] img_cluster0, img_cluster1, img_cluster2, img_cluster3;
wire [31:0] img_size0, img_size1, img_size2, img_size3;

// mpc_last_error_code是BMP内容级错误（头校验失败/像素截断/加载超时），
// 与scanner_fs_error/streamer_fs_error同属"8位诊断码，多个来源OR"的风格，
// 取值特意避开FAT32层已用的0x10、0x20~0x26（见下方BMP_ERR_*定义）。
assign osd_error_code = scanner_fs_error | streamer_fs_error | mpc_last_error_code;

// ---- 流读器输出 ----
wire        streamer_busy;
wire        streamer_done_pulse;
wire        streamer_byte_valid;
wire [7:0]  streamer_byte;

// ---- 扇区读接口（扫描器 / 流读器 / 仲裁后）----
wire        scanner_sector_req,  streamer_sector_req;
wire [31:0] scanner_sector_lba,  streamer_sector_lba;
wire        arb_sector_req;
wire [31:0] arb_sector_lba;
wire        arb_sector_busy;
wire        arb_sector_valid;
wire [7:0]  arb_sector_byte;
wire [8:0]  arb_sector_byte_index;
wire        arb_sector_done;
wire [7:0]  arb_sector_error;

// ---- 扇区读仲裁（扫描/流读/WAV播放三选一，按扇区轮换） ----
// 扫描器扫描时优先级最高；图片流读器与WAV播放器同时要总线时按扇区交替
// （读完一个图片扇区就让WAV读一个），只有一方要时全给它。WAV只在环形缓冲
// 能放下一整个扇区时才请求，缓冲满后自然让出，因此图片加载只慢约WAV码率
// 所占的带宽（约8%），加载图片期间不再断音。缩放器像素FIFO快满（scaler_hold）
// 时流读器发不出请求，此时WAV可以直接用总线。
//
// 三者共享同一条物理SPI总线，一次扇区传输是原子的（sd_sector_adapter内部
// busy_reg拉高到sector_done之间不能换人），owner只在没有已提交传输时才能切换。
// 握手差异决定了哪些请求可以被让出：
//   扫描器、流读器："看到!busy"的下一拍才打1拍sector_req，看到!busy就已认定请求
//   被接收——这一拍的请求不能丢，所以它们的sector_req为1时封锁切换（arb_locked）；
//   WAV播放器：sector_req是组合电平，在WS_REQ里一直等到!busy才前进，被让出时
//   只是继续等待，可以安全地被抢占。
// 切换那一拍（owner_change）对所有请求方都给busy=1，并屏蔽送往适配器的请求，
// 保证没有一方在这一拍认为自己的请求已被接收。
//
// 非总线主人看到的sector_busy必须是1（而不是0）：各请求方都是"看到!busy
// 就认为请求已被接收、转入等待done"，若给非主人0，它会在请求根本没送到
// 适配器时就进入等待态并永远等不到done，造成死锁。
localparam OWN_SCAN = 2'd0, OWN_IMG = 2'd1, OWN_WAV = 2'd2;

wire        wav_sector_req;
wire [31:0] wav_sector_lba;
wire        wav_stream_end_wr;
wire        wav_stream_idle_wr;
wire        scaler_hold;      // 缩放器像素FIFO快满，暂停SD读取

reg        bus_committed;
reg [1:0]  bus_owner;
reg        last_img;          // 最近一次被接收的扇区请求来自流读器（用于与WAV交替）
reg        wav_want_r;        // wav_sector_req打一拍：只用于选owner，不让WAV请求经过选owner逻辑再到适配器

// WAV请求是电平，被接收前一直保持，晚一拍判定不会丢；本拍刚被接收的请求不再算（避免读完后多判一次）
wire image_wants_bus = streamer_sector_req || (streamer_busy && !scaler_hold);
wire wav_wants_bus   = wav_want_r;

wire sel_scan = (bus_owner == OWN_SCAN);
wire sel_img  = (bus_owner == OWN_IMG);
wire sel_wav  = (bus_owner == OWN_WAV);

wire arb_req_raw = sel_scan ? scanner_sector_req :
                   sel_img  ? streamer_sector_req : wav_sector_req;
wire arb_locked  = bus_committed || (arb_req_raw && !sel_wav);

reg  [1:0] owner_next;
always @(*) begin
    if (scanner_busy)
        owner_next = OWN_SCAN;
    else if (image_wants_bus && wav_wants_bus)
        owner_next = last_img ? OWN_WAV : OWN_IMG;
    else if (image_wants_bus)
        owner_next = OWN_IMG;
    else if (wav_wants_bus)
        owner_next = OWN_WAV;
    else
        owner_next = bus_owner;   // 三者都不请求：保持原owner
end
wire owner_change = !arb_locked && (owner_next != bus_owner);

assign arb_sector_req = arb_req_raw && !owner_change;
assign arb_sector_lba = sel_scan ? scanner_sector_lba :
                        sel_img  ? streamer_sector_lba : wav_sector_lba;

// 各请求方看到的busy：不是主人、或本拍正在换主人，都为1
wire grant_busy_scan = !(sel_scan && !owner_change) || arb_sector_busy;
wire grant_busy_img  = !(sel_img  && !owner_change) || arb_sector_busy;
wire grant_busy_wav  = !(sel_wav  && !owner_change) || arb_sector_busy;

always @(posedge clk or posedge rst) begin
    if (rst)
        bus_committed <= 1'b0;
    else if (arb_sector_done)
        bus_committed <= 1'b0;
    else if (arb_sector_req)
        bus_committed <= 1'b1;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bus_owner  <= OWN_SCAN;
        last_img   <= 1'b0;
        wav_want_r <= 1'b0;
    end else begin
        wav_want_r <= wav_sector_req && !(sel_wav && arb_sector_req && !arb_sector_busy);
        if (owner_change)
            bus_owner <= owner_next;
        if (arb_sector_req && !arb_sector_busy)
            last_img <= sel_img;
    end
end

// ============= FAT32卷扫描器 =============
fat32_volume_scanner u_scanner (
    .clk                 (clk),
    .rst_n               (~rst),
    .scan_start          (mpc_scan_start_pulse),
    .scan_busy           (scanner_busy),
    .scan_done           (scanner_done_pulse),
    .fs_error            (scanner_fs_error),
    .partition_lba       (),
    .sectors_per_cluster (scanner_spc),
    .fat_start_lba       (scanner_fat_start),
    .data_start_lba      (scanner_data_start),
    .max_cluster         (scanner_max_cluster),
    .resource_valid      (scan_resource_valid),
    .resource0_cluster   (img_cluster0),
    .resource1_cluster   (img_cluster1),
    .resource2_cluster   (img_cluster2),
    .resource3_cluster   (img_cluster3),
    .resource0_size      (img_size0),
    .resource1_size      (img_size1),
    .resource2_size      (img_size2),
    .resource3_size      (img_size3),
    .sw_valid            (scan_sw_valid),
    .sw0_cluster         (sw0_cluster),
    .sw1_cluster         (sw1_cluster),
    .sw2_cluster         (sw2_cluster),
    .sw3_cluster         (sw3_cluster),
    .sw0_size            (sw0_size),
    .sw1_size            (sw1_size),
    .sw2_size            (sw2_size),
    .sw3_size            (sw3_size),
    .bg_valid            (scan_bg_valid),
    .bg_cluster          (bg_cluster),
    .bg_size             (bg_size),
    .sector_req          (scanner_sector_req),
    .sector_lba          (scanner_sector_lba),
    .sector_busy         (grant_busy_scan),
    .sector_valid        (sel_scan ? arb_sector_valid : 1'b0),
    .sector_byte         (arb_sector_byte),
    .sector_byte_index   (arb_sector_byte_index),
    .sector_done         (sel_scan ? arb_sector_done : 1'b0),
    .sector_error        (arb_sector_error)
);

// ============= FAT32文件流读取器 =============
// load_cluster/load_file_size由mpc_load_sector（资源句柄）查表得到
// 句柄bit2=1表示拨码开关图片SW1/SW2/SW3/SW12（低2位为序号），bit3=1表示开机背景BG.BMP
wire [1:0]  load_handle    = mpc_load_sector[1:0];
wire        load_handle_sw = mpc_load_sector[2];
wire        load_handle_bg = mpc_load_sector[3];
wire [31:0] load_cluster   = load_handle_bg ? bg_cluster :
                             load_handle_sw ?
                             ((load_handle == 2'd0) ? sw0_cluster :
                              (load_handle == 2'd1) ? sw1_cluster :
                              (load_handle == 2'd2) ? sw2_cluster : sw3_cluster) :
                             ((load_handle == 2'd0) ? img_cluster0 :
                              (load_handle == 2'd1) ? img_cluster1 :
                              (load_handle == 2'd2) ? img_cluster2 : img_cluster3);
wire [31:0] load_file_size = load_handle_bg ? bg_size :
                             load_handle_sw ?
                             ((load_handle == 2'd0) ? sw0_size :
                              (load_handle == 2'd1) ? sw1_size :
                              (load_handle == 2'd2) ? sw2_size : sw3_size) :
                             ((load_handle == 2'd0) ? img_size0 :
                              (load_handle == 2'd1) ? img_size1 :
                              (load_handle == 2'd2) ? img_size2 : img_size3);

reg  streamer_start;

fat32_file_streamer u_streamer (
    .clk                 (clk),
    .rst_n               (~rst),
    .file_start          (streamer_start),
    .first_cluster       (load_cluster),
    .file_size           (load_file_size),
    .sectors_per_cluster (scanner_spc),
    .fat_start_lba       (scanner_fat_start),
    .data_start_lba      (scanner_data_start),
    .max_cluster         (scanner_max_cluster),
    .file_busy           (streamer_busy),
    .file_done           (streamer_done_pulse),
    .file_valid          (streamer_byte_valid),
    .file_byte           (streamer_byte),
    .file_byte_offset    (),
    .fs_error            (streamer_fs_error),
    .sector_req          (streamer_sector_req),
    .sector_lba          (streamer_sector_lba),
    // 缩放器像素FIFO快满时(scaler_hold)让流读器以为总线忙，暂停发下一个扇区请求。
    // 只在两次扇区之间生效（流读器只在ST_DATA_REQ/ST_FAT_REQ看busy），不会打断进行中的传输。
    .sector_busy         (grant_busy_img | scaler_hold),
    .sector_valid        (sel_img ? arb_sector_valid : 1'b0),
    .sector_byte         (arb_sector_byte),
    .sector_byte_index   (arb_sector_byte_index),
    .sector_done         (sel_img ? arb_sector_done : 1'b0),
    .sector_error        (arb_sector_error)
);

// ============= WAV音频流式播放器（共享同一条SD物理总线） =============
wire signed [15:0] wav_sample_out_w;
wire               wav_sample_valid_w;
wire               wav_stream_active_w;

reg wav_play_enable;

// ---- 按拨码开关选择曲目（优先级与SW*.BMP选图一致：SW3 > SW1/SW2） ----
// 拨码全关时：开机动画期间（首图未提交）放背景音乐，之后按当前图片编号放对应栏目段，
// 换图提交后img_idx改变即从新栏目段起点播放。
// 开机动画消防员开始行走时换成开机问候（曲目3）从头播一遍，播完或被打断后回背景音乐，首图提交后照旧换栏目段。
localparam [2:0] WAV_TRK_BGM = 3'd0, WAV_TRK_ALARM1 = 3'd1, WAV_TRK_ALARM2 = 3'd2,
                 WAV_TRK_INTRO = 3'd3,
                 WAV_TRK_COL0 = 3'd4;   // 4~7 = 栏目0~3
reg        intro_walk_seen;   // 开机动画已开始行走（保持到复位）
reg        intro_played;      // 开机问候已播完或被打断（只播一遍）
reg  [31:0] col_req_total;
always @(*) begin
    case (mpc_img_idx)
        2'd0:    col_req_total = WAV_COL0_TOTAL_SECTORS;
        2'd1:    col_req_total = WAV_COL1_TOTAL_SECTORS;
        2'd2:    col_req_total = WAV_COL2_TOTAL_SECTORS;
        default: col_req_total = WAV_COL3_TOTAL_SECTORS;
    endcase
end
wire [2:0] wav_track_req = sw_stable[2]   ? WAV_TRK_ALARM2 :
                           |sw_stable[1:0] ? WAV_TRK_ALARM1 :
                           (first_committed && col_req_total != 32'd0) ? {1'b1, mpc_img_idx} :
                           (!first_committed && intro_walk_seen && !intro_played &&
                            WAV_INTRO_TOTAL_SECTORS != 32'd0) ? WAV_TRK_INTRO : WAV_TRK_BGM;
reg  [2:0] wav_track;   // 当前正在播放（或即将播放）的曲目，只在播放器空闲时更新
assign osd_wav_alarm = (wav_track == WAV_TRK_ALARM1) || (wav_track == WAV_TRK_ALARM2);

reg  [31:0] wav_track_lba, wav_track_total, wav_req_total;
always @(*) begin
    case (wav_track)
        WAV_TRK_ALARM1: begin wav_track_lba = WAV_ALARM1_START_LBA; wav_track_total = WAV_ALARM1_TOTAL_SECTORS; end
        WAV_TRK_ALARM2: begin wav_track_lba = WAV_ALARM2_START_LBA; wav_track_total = WAV_ALARM2_TOTAL_SECTORS; end
        WAV_TRK_INTRO:  begin wav_track_lba = WAV_INTRO_START_LBA;  wav_track_total = WAV_INTRO_TOTAL_SECTORS;  end
        3'd4:           begin wav_track_lba = WAV_COL0_START_LBA;   wav_track_total = WAV_COL0_TOTAL_SECTORS;   end
        3'd5:           begin wav_track_lba = WAV_COL1_START_LBA;   wav_track_total = WAV_COL1_TOTAL_SECTORS;   end
        3'd6:           begin wav_track_lba = WAV_COL2_START_LBA;   wav_track_total = WAV_COL2_TOTAL_SECTORS;   end
        3'd7:           begin wav_track_lba = WAV_COL3_START_LBA;   wav_track_total = WAV_COL3_TOTAL_SECTORS;   end
        default:        begin wav_track_lba = WAV_START_LBA;        wav_track_total = WAV_TOTAL_SECTORS;        end
    endcase
    case (wav_track_req)
        WAV_TRK_ALARM1: wav_req_total = WAV_ALARM1_TOTAL_SECTORS;
        WAV_TRK_ALARM2: wav_req_total = WAV_ALARM2_TOTAL_SECTORS;
        WAV_TRK_BGM:    wav_req_total = WAV_TOTAL_SECTORS;
        WAV_TRK_INTRO:  wav_req_total = WAV_INTRO_TOTAL_SECTORS;
        default:        wav_req_total = col_req_total;
    endcase
end

wav_stream_player #(
    .ADDR_WIDTH         (12),
    .SAMPLES_PER_SECTOR (256)
) u_wav_stream_player (
    .wr_clk             (clk),
    .wr_rst_n           (~rst),
    .play_enable        (wav_play_enable),
    .start_lba          (wav_track_lba),
    .total_sectors      (wav_track_total),
    .sector_req         (wav_sector_req),
    .sector_lba         (wav_sector_lba),
    .sector_busy        (grant_busy_wav),
    .sector_valid       (sel_wav ? arb_sector_valid : 1'b0),
    .sector_byte        (arb_sector_byte),
    .sector_byte_index  (arb_sector_byte_index),
    .sector_done        (sel_wav ? arb_sector_done : 1'b0),
    .sector_error       (arb_sector_error),
    .stream_end_wr      (wav_stream_end_wr),
    .stream_idle_wr     (wav_stream_idle_wr),

    .rd_clk             (rd_clk),
    .rd_rst_n           (rd_rst_n),
    .sample_tick        (sample_tick),
    .sample_out         (wav_sample_out_w),
    .sample_valid       (wav_sample_valid_w),
    .sample_ready       (1'b1),         // 本工程HDMI音频链无反压，下游恒就绪

    .sample_counter     (),
    .stream_active       (wav_stream_active_w),
    .stream_end          (),
    .buffer_low          ()
);

assign wav_sample_out    = wav_sample_out_w;
assign wav_sample_valid  = wav_sample_valid_w;
assign wav_stream_active = wav_stream_active_w;

// 自动循环播放：WAV_TOTAL_SECTORS配置为非0即在SDRAM就绪后开播；
// wav_stream_player读到stream_end_wr（wr_clk域电平，与本控制逻辑同域，
// 不需要跨时钟域同步）后，先把play_enable拉低1拍让写侧状态机WS_END
// 回到WS_IDLE，再重新拉高即可从start_lba重新开始，实现循环播放。
// 若未配置音频区间（WAV_TOTAL_SECTORS==0），wav_play_enable不会被拉高，
// wav_stream_player停留在WS_IDLE，对图片浏览功能零影响。
//
// 换曲：拨码目标曲目与当前曲目不同时拉低play_enable，播放器收完当前扇区
// 回到WS_IDLE（stream_idle_wr=1）后，再锁存新曲目并重新拉高，从新曲目起点播放。
// 报警音与背景音乐一样循环播放，直到拨码改变。
always @(posedge clk or posedge rst) begin
    if (rst) begin
        wav_play_enable <= 1'b0;
        wav_track       <= WAV_TRK_BGM;
    end else if (!wav_play_enable) begin
        if (sdram_ready && wav_stream_idle_wr && wav_req_total != 32'd0) begin
            wav_track       <= wav_track_req;
            wav_play_enable <= 1'b1;
        end
    end else if (wav_stream_end_wr || wav_track_req != wav_track) begin
        wav_play_enable <= 1'b0;
    end
end

// 开机问候只播一遍——行走开始即登记；正在播问候时播完（WS_END）或要换走（拨码/首图提交），记为已播
always @(posedge clk or posedge rst) begin
    if (rst) begin
        intro_walk_seen <= 1'b0;
        intro_played    <= 1'b0;
    end else begin
        if (intro_walk_sync[1])
            intro_walk_seen <= 1'b1;
        if (wav_play_enable && wav_track == WAV_TRK_INTRO &&
            (wav_stream_end_wr || wav_track_req != WAV_TRK_INTRO))
            intro_played <= 1'b1;
    end
end

// ---- 自动播放跟随栏目语音 ----
// 栏目段布局（tools/convert/voice_column/make_column_audio.py）：[前导1.5s][语音][5s][语音][5s][语音][3.5s]，语音长度=WAV_COLn_VOICE_SAMPLES。
// 播放器已读扇区数（sector_lba−起始LBA，领先实际播放不超过环形缓冲约85ms）落在
// "某遍语音结束后0.3s ~ 4.5s"内时 col_voice_gap=1，自动播放此时切下一张（正常即第一遍读完后）。
localparam integer COL_LEAD_SMP = 72000;    // 前导1.5s
localparam integer COL_GAP_SMP  = 240000;   // 两遍语音间隔5s
localparam integer COL_SKIP_SMP = 14400;    // 语音结束后再等0.3s（盖住缓冲领先量）
localparam integer COL_WIN_SMP  = 201600;   // 间隔窗口长4.2s
function col_gap_hit;
    input [15:0] off_sec;   // 本段已读扇区数（每扇区256采样）
    input [31:0] nv;        // 一遍语音采样数（常数）
    integer k;
    reg [31:0] s_sec;
    begin
        col_gap_hit = 1'b0;
        for (k = 0; k < 3; k = k + 1) begin
            s_sec = (COL_LEAD_SMP + k * (nv + COL_GAP_SMP) + nv + COL_SKIP_SMP) >> 8;
            if (nv != 32'd0 && off_sec >= s_sec[15:0] && off_sec < s_sec[15:0] + (COL_WIN_SMP >> 8))
                col_gap_hit = 1'b1;
        end
    end
endfunction

wire [15:0] wav_off_sec = wav_sector_lba[15:0] - wav_track_lba[15:0];   // 段长<65536扇区，取低16位相减即可
// 结果寄存一拍，同时记下是哪一段算出的（col_gap_trk_r），只有与当前段一致才有效，
// 避免换段那一拍把旧段（正处在间隔里）的结果当成新段的间隔而连续切图两次。
// 播放器 WS_IDLE 时 sector_lba 还是上一段的地址（下一拍才装入新段起点），这一拍也不算。
reg         col_gap_hit_r;
reg  [2:0]  col_gap_trk_r;
reg         col_gap_hit_n;
always @(*) begin
    case (wav_track[1:0])   // 每个分支的语音长度都是常数，比较边界在综合期算好
        2'd0:    col_gap_hit_n = col_gap_hit(wav_off_sec, WAV_COL0_VOICE_SAMPLES);
        2'd1:    col_gap_hit_n = col_gap_hit(wav_off_sec, WAV_COL1_VOICE_SAMPLES);
        2'd2:    col_gap_hit_n = col_gap_hit(wav_off_sec, WAV_COL2_VOICE_SAMPLES);
        default: col_gap_hit_n = col_gap_hit(wav_off_sec, WAV_COL3_VOICE_SAMPLES);
    endcase
end
always @(posedge clk or posedge rst) begin
    if (rst) begin
        col_gap_hit_r <= 1'b0;
        col_gap_trk_r <= WAV_TRK_BGM;
    end else begin
        col_gap_hit_r <= col_gap_hit_n && !wav_stream_idle_wr;
        col_gap_trk_r <= wav_track;
    end
end
reg  [31:0] col_req_voice;
always @(*) begin
    case (mpc_img_idx)
        2'd0:    col_req_voice = WAV_COL0_VOICE_SAMPLES;
        2'd1:    col_req_voice = WAV_COL1_VOICE_SAMPLES;
        2'd2:    col_req_voice = WAV_COL2_VOICE_SAMPLES;
        default: col_req_voice = WAV_COL3_VOICE_SAMPLES;
    endcase
end
// 当前图配置了栏目段和语音长度 → 自动播放跟随语音
assign col_voice_sync_en  = first_committed && col_req_total != 32'd0 && col_req_voice != 32'd0;
// 播放器正在放当前图自己的栏目段（换图提交后、新段开播前为0）
assign col_voice_track_ok = wav_play_enable && !wav_stream_end_wr && wav_track == {1'b1, mpc_img_idx};
assign col_voice_gap      = col_voice_track_ok && col_gap_hit_r && (col_gap_trk_r == wav_track);

// ============= SD卡扇区接口适配层 =============
sd_sector_adapter u_adapter (
    .clk                    (clk),
    .rst_n                  (~rst),
    .sector_req             (arb_sector_req),
    .sector_lba             (arb_sector_lba),
    .sector_busy            (arb_sector_busy),
    .sector_valid           (arb_sector_valid),
    .sector_byte            (arb_sector_byte),
    .sector_byte_index      (arb_sector_byte_index),
    .sector_done            (arb_sector_done),
    .sector_error           (arb_sector_error),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_end        (sd_sec_read_end)
);

// =====================================================================
// 适配1：SDRAM帧写请求握手 + 源加载时序
//
// frame_fifo_write的协议：write_req保持1直到write_req_ack=1，撤销req后
// 它才离开S_ACK（复位FIFO、锁存写地址/长度）进入S_CHECK_FIFO开始收数据。
// 所以必须等ack撤销之后再放像素，否则头几个像素会被FIFO复位吃掉。
// =====================================================================
localparam SRC_IDLE    = 3'd0;
localparam SRC_REQ     = 3'd1;  // 举write_req，等ack
localparam SRC_ACK     = 3'd2;  // 撤req，等ack落下
localparam SRC_WAITSRC = 3'd3;  // 等流读器回到空闲
localparam SRC_STREAM  = 3'd4;  // 送字节流

reg [2:0] src_state;
reg       write_req_r;

assign write_req = write_req_r;

// 加载触发。超时重试时media_player_control会再发一次load_start_pulse，
// 此时src_state不在IDLE，必须允许无条件重启，否则永远卡在SRC_STREAM。
// 重发write_req是安全的：frame_fifo_write在S_CHECK_FIFO/S_WRITE_BURST_END
// 看到write_req会回到S_ACK重新复位FIFO。
wire load_kick = mpc_load_start_pulse;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        src_state      <= SRC_IDLE;
        write_req_r    <= 1'b0;
        streamer_start <= 1'b0;
    end else begin
        streamer_start <= 1'b0;

        if (load_kick) begin
            write_req_r <= 1'b1;
            src_state   <= SRC_REQ;
        end else begin
            case (src_state)
                SRC_REQ: if (write_req_ack) begin
                    write_req_r <= 1'b0;
                    src_state   <= SRC_ACK;
                end
                SRC_ACK: if (!write_req_ack) begin
                    src_state <= SRC_WAITSRC;
                end
                SRC_WAITSRC: if (!streamer_busy) begin
                    streamer_start <= 1'b1;
                    src_state      <= SRC_STREAM;
                end
                SRC_STREAM: if (streamer_done_pulse) begin
                    src_state <= SRC_IDLE;
                end
                default: src_state <= SRC_IDLE;
            endcase
        end
    end
end

// =====================================================================
// 适配3：bmp_ready —— 空闲即为1的ready语义
//   · 上电：SD未初始化 → 0，初始化完成且空闲 → 1，触发上电扫描
//   · 加载中：0
//   · 整帧像素送完：1 → media_player_control置source_done_seen，等帧写完提交
// load_kick同拍并入busy，关掉"load_busy已置1而源还没启动"的一拍窗口。
//
// 关键：判据必须是"整帧像素已送出"，绝不能等streamer的file_done。
// media_player_control要求source_done_seen在write_finish_pulse
// 那一拍就已为1（该脉冲是toggle边沿检测出的单拍信号，错过即永久丢失），
// 而streamer在数据字节读完后还要再读一个完整FAT扇区做EOF校验
// （ST_FAT_REQ→WAIT→PARSE，512字节×约32周期≈1.6万拍）。write_finish在
// 最后一个像素进FIFO后很快就跨时钟域送达，会比file_done早一万多拍，
// 于是source_done_seen迟到、脉冲被错过、帧永远提交不了 → 永久黑屏。
//
// frame_sent一定早于write_finish：frame_fifo_write要收满FRAME_PIXELS个
// 像素才进S_END，而frame_sent就是第FRAME_PIXELS个像素送出的那一拍，
// 之后还需排空FIFO并跨时钟域同步，因此不存在反向竞争。
// =====================================================================
// 本帧已送入FIFO的像素数（同时用于诊断页3显示）
reg [23:0] pixel_cnt;
always @(posedge clk or posedge rst) begin
    if (rst)
        pixel_cnt <= 24'd0;
    else if (streamer_start)
        pixel_cnt <= 24'd0;
    else if (bmp_data_wr_en && pixel_cnt != {24{1'b1}})
        pixel_cnt <= pixel_cnt + 24'd1;
end

reg frame_sent;
always @(posedge clk or posedge rst) begin
    if (rst)
        frame_sent <= 1'b0;
    else if (streamer_start)
        frame_sent <= 1'b0;
    else if (bmp_data_wr_en && (pixel_cnt + 24'd1 >= FRAME_PIXELS[23:0]))
        frame_sent <= 1'b1;
    // 不用streamer_done_pulse兜底置1：
    // 缩放器在头错误/截断时会自动把剩余部分填黑，任何情况下都一定输出满
    // FRAME_PIXELS个像素，上面的正常条件总会成立；而且缩放器输出比SD读取滞后，
    // file_done到来时帧可能还没写完，用它兜底反而会提前释放bmp_ready。
    // 流读器根本没启动/卡死的情况由media_player_control的加载超时处理。
end

wire source_busy = scanner_busy ||
                   ((src_state != SRC_IDLE || load_kick) && !frame_sent);
assign bmp_ready = sd_init_done && !source_busy;

// =====================================================================
// 适配2+4：scan_done脉冲转电平 + 资源发现脉冲串
// 扫描器给出的4组并行结果，在这里展开成media_player_control期望的
// "每找到一张发一个scan_found_valid脉冲"。scan_found_sector传资源序号
// （0~3）作为句柄，media_player_control会把它压缩缓存到img_sector0~3，
// 加载时原样还给我们，再由句柄查簇号。缺图时序号自动压缩，
// 例如缺PIC3则句柄序列为0,1,3，img_found_count=3，切换顺序仍然正确。
// 电平scan_done必须等脉冲串发完再举起，否则media_player_control会在
// img_found_count还没累加完时就触发首图加载。
// =====================================================================
localparam SF_IDLE = 2'd0;
localparam SF_EMIT = 2'd1;
localparam SF_DONE = 2'd2;

reg [1:0] sf_state;
reg [1:0] sf_idx;
reg [2:0] found_total_r;

assign scan_found_total = found_total_r;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sf_state          <= SF_IDLE;
        sf_idx            <= 2'd0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_done         <= 1'b0;
        found_total_r     <= 3'd0;
    end else begin
        scan_found_valid <= 1'b0;

        // 新一轮扫描开始：清电平
        if (mpc_scan_start_pulse) begin
            scan_done     <= 1'b0;
            found_total_r <= 3'd0;
            sf_state      <= SF_IDLE;
        end else begin
            case (sf_state)
                SF_IDLE: if (scanner_done_pulse) begin
                    sf_idx   <= 2'd0;
                    sf_state <= SF_EMIT;
                end

                SF_EMIT: begin
                    if (scan_resource_valid[sf_idx]) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= {30'd0, sf_idx};
                        found_total_r     <= found_total_r + 3'd1;
                    end
                    if (sf_idx == 2'd3)
                        sf_state <= SF_DONE;
                    else
                        sf_idx <= sf_idx + 2'd1;
                end

                // 等最后一个脉冲被media_player_control吃掉，再举电平
                SF_DONE: begin
                    scan_done <= 1'b1;
                    sf_state  <= SF_IDLE;
                end

                default: sf_state <= SF_IDLE;
            endcase
        end
    end
end

// =====================================================================
// BMP头解析 + 字节流拼RGB
//
// 头解析：偏移10~13的4字节小端序为像素数据偏移量。用独立的移位寄存器
// 累加，在第13字节收齐后做范围校验再提交给data_offset——这样比较式
// 一直拿到的是稳定值，且异常值不会让状态机永久卡在读头阶段。
//
// RGB拼装：第3字节到齐即完成一个像素并把计数回绕到0，不浪费任何字节；
// wr_en与data同拍寄存。
// =====================================================================
reg [1:0]  byte_state;     // 0=空闲, 1=读BMP头, 2=拼RGB
reg [15:0] bmp_byte_cnt;
reg [31:0] data_offset;
reg [31:0] hdr_shift;
reg [1:0]  rgb_byte_cnt;   // 0=B, 1=G, 2=R

// 从BMP头解析出的实际图像参数：宽/高/位深用于诊断页观测，
// 同时也是header_ok严格校验的输入
reg [15:0] bmp_hdr_width;
reg [15:0] bmp_hdr_height;
reg [15:0] bmp_hdr_bpp;

// 签名(0-1)、DIB头大小(14-15)、平面数(26-27)、压缩方式(30-31)四个字段，
// 均只取32位字段的低16位——真实BMP这些字段的值都很小
// （dib_size=40、planes=1、compression=0），高16位不为0本身就说明格式
// 异常，跟着低16位一起在header_ok里判掉即可，不需要额外捕获高16位。
reg [7:0]  bmp_hdr_sig0;
reg [7:0]  bmp_hdr_sig1;
reg [15:0] bmp_hdr_dib_size;
reg [15:0] bmp_hdr_planes;
reg [15:0] bmp_hdr_compression;

// 下界取26（14字节文件头+最小12字节DIB头）：data_offset在第13字节提交、
// 第14拍才生效，若小于15则切换点会晚一拍。真实BMP不会小于26。
wire [31:0] hdr_offset_next = {streamer_byte, hdr_shift[31:8]};
wire        hdr_offset_ok   = (hdr_offset_next >= 32'd26) &&
                              (hdr_offset_next <= 32'd4096);

// 头阶段吃掉data_offset个字节（索引0..data_offset-1）后切到像素阶段。
// hdr_last_byte表示"当前字节是最后一个头字节"，等价于 (bmp_byte_cnt+1) >= data_offset。
// 用寄存器实现：收下每个头字节的同一拍，预先算出下一个字节是否为最后一个头字节，
// 即 (bmp_byte_cnt+1)+1 >= data_offset：
//   - 复位/streamer_start：计数=0、data_offset=54，清0；
//   - bmp_byte_cnt<=13 的字节：data_offset为初值54，或在第13字节当拍写入>=26的新值
//     （hdr_offset_ok下界26，不合格回落54），下一字节的结果恒为0；
//   - bmp_byte_cnt>=14 的字节：data_offset已固定，直接用当前值比较。
// 只在头阶段使用（所有使用点都与byte_state==1相与）。
reg hdr_last_byte;

// BMP严格校验，9项条件构成严格的header_match：
// data_offset>=54（内容校验，比上面hdr_offset_ok的>=26更严）、
// load_file_size是FAT32目录项给出的真实文件大小，比重新解析BMP头里
// 偏移2-5的file_len字段更可信，直接用它做"文件大小够不够装下所有像素"
// 的校验，省掉再解析一个字段。header_ok只在hdr_last_byte那一拍被采样
// （见下方load_bad always块），此时偏移0-33的所有字段必然已经读到——
// 若data_offset<54导致hdr_last_byte提前到来，data_offset>=54这一项本身
// 就会先判失败，不依赖尚未读到的字段。
// 宽高要求在1~MAX_SRC_DIM之间，并用真实宽高
// （含行尾4字节对齐填充）校验文件大小。高度只支持正值（标准自下而上BMP），
// 负高度（自上而下）会因bmp_hdr_height[15]=1而超出上限被判错。
// 每行字节数 = (宽*3 + 3) & ~3
//
// 校验分4级寄存器流水，每拍连续计算：
//   第1拍 行字节数 → 第2拍 ×高 → 第3拍 文件大小比较 → 第4拍 汇总header_ok。
// 结果比字段晚4拍：字段最晚在第31字节写完，header_ok最早在第53字节
// （data_offset>=54）才被采样，中间至少隔22个字节（每字节至少1拍），流水已排空；
// data_offset<54时它在第13字节就已写定，到最早的采样点第25字节也隔了12拍，
// data_offset>=54这一项先判失败。
// 宽高合法时不超过MAX_SRC_DIM，乘法只取低13位（要求MAX_SRC_DIM<=8191）；
// 超限的宽高已被下面的<=MAX_SRC_DIM判掉，截断不影响结论。
wire [14:0] hdr_w3 = {2'b0, bmp_hdr_width[12:0]} + {1'b0, bmp_hdr_width[12:0], 1'b0};   // 宽×3
reg  [14:0] hdr_row_bytes_r;    // 行字节数（≤24576）
reg  [27:0] hdr_pix_bytes_r;    // 行字节数×高（像素区总字节数）
reg         hdr_size_ok_r;      // 文件大小够装下 头 + 全部像素
reg         header_ok_r;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        hdr_row_bytes_r <= 15'd0;
        hdr_pix_bytes_r <= 28'd0;
        hdr_size_ok_r   <= 1'b0;
        header_ok_r     <= 1'b0;
    end else begin
        hdr_row_bytes_r <= (hdr_w3 + 15'd3) & 15'h7FFC;
        hdr_pix_bytes_r <= hdr_row_bytes_r * bmp_hdr_height[12:0];
        hdr_size_ok_r   <= (load_file_size >= data_offset + {4'd0, hdr_pix_bytes_r});
        header_ok_r     <= (bmp_hdr_sig0 == 8'h42) && (bmp_hdr_sig1 == 8'h4D) &&      // "BM"
                           (bmp_hdr_dib_size >= 16'd40) &&
                           (bmp_hdr_width  != 16'd0) && (bmp_hdr_width  <= MAX_SRC_DIM) &&
                           (bmp_hdr_height != 16'd0) && (bmp_hdr_height <= MAX_SRC_DIM) &&
                           (bmp_hdr_planes == 16'd1) &&
                           (bmp_hdr_bpp    == 16'd24) &&
                           (bmp_hdr_compression == 16'd0) &&
                           (data_offset >= 32'd54) &&
                           hdr_size_ok_r;
    end
end

wire header_ok = header_ok_r;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        byte_state           <= 2'd0;
        bmp_byte_cnt         <= 16'd0;
        hdr_last_byte        <= 1'b0;
        data_offset          <= 32'd54;
        hdr_shift            <= 32'd0;
        rgb_byte_cnt         <= 2'd0;
        bmp_hdr_width        <= 16'd0;
        bmp_hdr_height       <= 16'd0;
        bmp_hdr_bpp          <= 16'd0;
        bmp_hdr_sig0         <= 8'd0;
        bmp_hdr_sig1         <= 8'd0;
        bmp_hdr_dib_size     <= 16'd0;
        bmp_hdr_planes       <= 16'd0;
        bmp_hdr_compression  <= 16'd0;
    end else if (streamer_start) begin
        byte_state           <= 2'd1;
        bmp_byte_cnt         <= 16'd0;
        hdr_last_byte        <= 1'b0;
        data_offset          <= 32'd54;
        hdr_shift            <= 32'd0;
        rgb_byte_cnt         <= 2'd0;
        bmp_hdr_width        <= 16'd0;
        bmp_hdr_height       <= 16'd0;
        bmp_hdr_bpp          <= 16'd0;
        bmp_hdr_sig0         <= 8'd0;
        bmp_hdr_sig1         <= 8'd0;
        bmp_hdr_dib_size     <= 16'd0;
        bmp_hdr_planes       <= 16'd0;
        bmp_hdr_compression  <= 16'd0;
    end else if (streamer_byte_valid) begin
        case (byte_state)
            2'd1: begin
                if (bmp_byte_cnt >= 16'd10 && bmp_byte_cnt <= 16'd13) begin
                    hdr_shift <= hdr_offset_next;
                    if (bmp_byte_cnt == 16'd13)
                        data_offset <= hdr_offset_ok ? hdr_offset_next : 32'd54;
                end

                // 抓取签名(0-1)、DIB头大小(14-15)、宽(18-19)、高(22-23)、
                // 平面数(26-27)、位深(28-29)、压缩方式(30-31)，只取低16位够用
                case (bmp_byte_cnt)
                    16'd0:  bmp_hdr_sig0                <= streamer_byte;
                    16'd1:  bmp_hdr_sig1                <= streamer_byte;
                    16'd14: bmp_hdr_dib_size[7:0]        <= streamer_byte;
                    16'd15: bmp_hdr_dib_size[15:8]       <= streamer_byte;
                    16'd18: bmp_hdr_width[7:0]           <= streamer_byte;
                    16'd19: bmp_hdr_width[15:8]          <= streamer_byte;
                    16'd22: bmp_hdr_height[7:0]          <= streamer_byte;
                    16'd23: bmp_hdr_height[15:8]         <= streamer_byte;
                    16'd26: bmp_hdr_planes[7:0]          <= streamer_byte;
                    16'd27: bmp_hdr_planes[15:8]         <= streamer_byte;
                    16'd28: bmp_hdr_bpp[7:0]              <= streamer_byte;
                    16'd29: bmp_hdr_bpp[15:8]             <= streamer_byte;
                    16'd30: bmp_hdr_compression[7:0]      <= streamer_byte;
                    16'd31: bmp_hdr_compression[15:8]     <= streamer_byte;
                    default: ;
                endcase

                bmp_byte_cnt <= bmp_byte_cnt + 16'd1;
                hdr_last_byte <= (bmp_byte_cnt >= 16'd14) &&
                                 ((bmp_byte_cnt + 16'd2) >= data_offset[15:0]);

                if (hdr_last_byte) begin
                    byte_state   <= 2'd2;
                    rgb_byte_cnt <= 2'd0;
                end
            end
            2'd2: begin
                rgb_byte_cnt <= (rgb_byte_cnt == 2'd2) ? 2'd0 : (rgb_byte_cnt + 2'd1);
            end
            default: ;
        endcase
    end
end

// =====================================================================
// 错误检测（头校验失败 / 像素截断），独立always块，与上面的头解析和
// 像素组装逻辑解耦。load_bad是"本次加载是否已判定失败"的
// sticky标志，streamer_start时清零，media_player_control在
// write_finish_pulse那一拍采样，采样之后到下一次streamer_start之前
// 这个值不会变，所以不需要额外的pulse/seen握手。
//
// fat32_file_streamer没有中止接口，头校验失败后文件仍会被读到底——
// 这里只是尽早锁定错误结论。
// =====================================================================
localparam [7:0] BMP_ERR_HEADER    = 8'h30;
localparam [7:0] BMP_ERR_TRUNCATED = 8'h32;

reg        load_bad;
reg [7:0]  load_error_code;

// 截断判断用的源像素计数（在下方像素输出段计数，声明放在使用之前）
reg  [23:0] src_pix_cnt;      // 已收源像素总数（截断判断用）
wire [23:0] src_pix_total = bmp_hdr_width * bmp_hdr_height;

assign bmp_load_error      = load_bad;
assign bmp_load_error_code = load_error_code;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        load_bad        <= 1'b0;
        load_error_code <= 8'h00;
    end else if (streamer_start) begin
        load_bad        <= 1'b0;
        load_error_code <= 8'h00;
    end else begin
        // 头刚读完那一拍判定：header_ok此时读到的是稳定值（见上方header_ok注释）
        if (streamer_byte_valid && byte_state == 2'd1 && hdr_last_byte && !header_ok) begin
            load_bad        <= 1'b1;
            load_error_code <= BMP_ERR_HEADER;
        end

        // 文件流真正结束时兜底：像素凑不满一帧，或FAT32层本身读出了错误，
        // 都归为"帧不完整"——只有在还没被头校验判过的情况下才覆盖，
        // 避免把已经确定的头错误码被截断码覆盖掉
        // 像素数按源图真实宽高判断（src_pix_cnt是去掉行填充后的源像素数）
        if (streamer_done_pulse && !load_bad &&
            (src_pix_cnt < src_pix_total || streamer_fs_error != 8'h00)) begin
            load_bad        <= 1'b1;
            load_error_code <= BMP_ERR_TRUNCATED;
        end
    end
end

// 像素输出：BMP按BGR顺序存储，第3字节到齐时输出一个24位RGB源像素。
// 源图宽度不是4的倍数时每行末尾有0~3字节对齐填充，这里按真实宽度
// 数像素，凑满一行后跳过填充字节，再送给缩放器；缩放器输出的640×480像素
// 才是最终写进SDRAM的数据（bmp_data_wr_en/bmp_data）。
wire        pixel_byte_valid = streamer_byte_valid && (byte_state == 2'd2);
// 行尾填充只取决于(宽×3)的低2位，而(宽×3)[1:0] == (宽[1:0]×3)[1:0]，用2位运算求得
wire [1:0]  row_bytes_low2   = bmp_hdr_width[1:0] + {bmp_hdr_width[0], 1'b0};     // (宽×3) mod 4
wire [1:0]  row_pad_bytes    = 2'd0 - row_bytes_low2;                                // 0~3

reg         src_pix_valid;
reg  [23:0] src_pix;
reg  [15:0] src_col;          // 当前行已收像素数
reg  [1:0]  pad_left;         // 当前行剩余要跳过的填充字节
reg  [7:0]  pix_b, pix_g;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        src_pix_valid <= 1'b0;
        src_pix       <= 24'd0;
        src_col       <= 16'd0;
        pad_left      <= 2'd0;
        src_pix_cnt   <= 24'd0;
        pix_b         <= 8'd0;
        pix_g         <= 8'd0;
    end else if (streamer_start) begin
        src_pix_valid <= 1'b0;
        src_col       <= 16'd0;
        pad_left      <= 2'd0;
        src_pix_cnt   <= 24'd0;
    end else begin
        src_pix_valid <= 1'b0;
        if (pixel_byte_valid) begin
            if (pad_left != 2'd0) begin
                pad_left <= pad_left - 2'd1;            // 跳过行尾填充
            end else begin
                case (rgb_byte_cnt)
                    2'd0: pix_b <= streamer_byte;       // B
                    2'd1: pix_g <= streamer_byte;       // G
                    default: begin                      // R：一个像素到齐
                        src_pix       <= {streamer_byte, pix_g, pix_b};
                        src_pix_valid <= 1'b1;
                        if (src_pix_cnt != {24{1'b1}})
                            src_pix_cnt <= src_pix_cnt + 24'd1;
                        if (src_col == bmp_hdr_width - 16'd1) begin
                            src_col  <= 16'd0;
                            pad_left <= row_pad_bytes;
                        end else
                            src_col  <= src_col + 16'd1;
                    end
                endcase
            end
        end
    end
end

// ---- 加载时缩放到640×480 ----
// 头解析完成那一拍（hdr_last_byte）把校验结果交给缩放器；
// 头错误/截断时缩放器自动把剩余部分填黑，保证写满一帧，上层照常收到load_error。
wire hdr_done_pulse = streamer_byte_valid && (byte_state == 2'd1) && hdr_last_byte;
wire        scaler_out_valid;
wire [23:0] scaler_out_pixel;

bmp_scaler_640x480 #(
    .DST_W       (640),
    .DST_H       (480),
    .KEEP_ASPECT (KEEP_ASPECT)
) u_bmp_scaler (
    .clk        (clk),
    .rst        (rst),
    .start      (streamer_start),
    .hdr_done   (hdr_done_pulse),
    .hdr_ok     (header_ok),
    .src_w      (bmp_hdr_width),
    .src_h      (bmp_hdr_height),
    .in_valid   (src_pix_valid),
    .in_pixel   (src_pix),
    .src_eof    (streamer_done_pulse),
    .hold       (scaler_hold),
    .out_valid  (scaler_out_valid),
    .out_pixel  (scaler_out_pixel)
);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_data_wr_en <= 1'b0;
        bmp_data       <= 24'd0;
    end else begin
        bmp_data_wr_en <= scaler_out_valid;
        if (scaler_out_valid)
            bmp_data   <= scaler_out_pixel;
    end
end

// =====================================================================
// 诊断：把FAT32流水线的关键状态编码到数码管，由dbg_page选页
//
//   页0 (dbg_page=0)：[stage][resource_valid][sw_valid][开关][fs_err 2位]
//     sw_valid：扫描到的SW文件，bit0=SW1 bit1=SW2 bit2=SW3 bit3=SW12，4个都在=F
//     开关：消抖后的开关状态，bit0=SW1 bit1=SW2 bit2=SW3，拨上对应位为1
//     fs_err：scanner_err | streamer_err（两者合并为一个错误码）
//   页1 (dbg_page=1)：[BMP宽 3位][BMP高 3位]   —— 例：640x480显示 2801E0
//   页2 (dbg_page=2)：[位深 2位][数据偏移 4位] —— 24位/54字节应显示 180036
//   页3 (dbg_page=3)：[实际送入SDRAM的像素数 6位] —— 整帧需 04B000
//
// 页1~3用于定位"stage=8（字节流读完但整帧写不满）"：header_ok会
// 校验签名/DIB头大小/宽高/平面数/位深/压缩方式/像素偏移/文件大小，
// 不符就置位load_bad→BMP_ERR_HEADER。这几页数码管诊断用来方便肉眼
// 核对header_ok判断依据的原始字段。
// 若页1宽或高为0、超过MAX_SRC_DIM，或页2位深不是18，则header_ok判失败。
//
// stage（页0最左1位）——流水线走到哪一步就停在哪个值：
//   0 = SD卡未初始化（sd_init_done=0）→ SPI/接线/卡本身问题
//   1 = SD已初始化，但上电扫描还没被触发 → bmp_ready或scan_kicked逻辑问题
//   2 = 扫描器正在跑（停在这里=扫描器卡死，看扇区读是否有响应）
//   3 = 扫描结束但一张都没找到（resource_valid=0）→ 看scanner_err
//   4 = 扫描结束、找到了文件，但还没发起加载 → media_player_control没动
//   5 = 正在等SDRAM帧写请求握手（write_req已举，等write_req_ack）
//   6 = 握手完成，等流读器空闲
//   7 = 流读器正在读文件字节流（停在这里=流读器卡死或FAT链出错）
//   8 = 像素在送但还没凑满整帧（停在这里=图片格式不对，像素数不足307200）
//   9 = 整帧像素已送出，等write_finish提交（停在这里=帧写入或提交握手问题）
//   F = 首帧已提交成功（此时本应有画面）
//
// scanner_err / streamer_err 为各自的fs_error：
//   10=扇区读错 20=引导签名非0x55AA 21=BPB参数不支持 22=根目录找不到PIC1~4.BMP
//   23=FAT环 24=簇号越界 25=提前EOF 26=遍历簇数超限
// =====================================================================
wire [3:0] dbg_stage;

// 页选：0=流水线状态 1=BMP宽高 2=位深+数据偏移 3=实际像素数
assign dbg_digits =
    (dbg_page == 2'd0) ? {dbg_stage, scan_resource_valid,
                          scan_sw_valid, {1'b0, sw_stable},
                          scanner_fs_error | streamer_fs_error} :
    (dbg_page == 2'd1) ? {bmp_hdr_width[11:0], bmp_hdr_height[11:0]} :
    (dbg_page == 2'd2) ? {bmp_hdr_bpp[7:0], data_offset[15:0]} :
                         pixel_cnt;

assign dbg_stage = (!sd_init_done)                          ? 4'h0 :
                   mpc_display_valid                        ? 4'hF :
                   scanner_busy                             ? 4'h2 :
                   (src_state == SRC_REQ)                   ? 4'h5 :
                   (src_state == SRC_ACK ||
                    src_state == SRC_WAITSRC)               ? 4'h6 :
                   (src_state == SRC_STREAM)                ? 4'h7 :
                   (!scan_done)                             ? 4'h1 :
                   (scan_resource_valid == 4'd0)            ? 4'h3 :
                   (found_total_r != 0 && byte_state == 2'd2 &&
                    !frame_sent)                            ? 4'h8 :
                   (found_total_r != 0 && frame_sent)        ? 4'h9 :
                   4'h4;

// ============= SD卡控制模块 =============
sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

endmodule
