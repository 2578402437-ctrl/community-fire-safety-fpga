// ============================================================================
// 文件名称：top_tf_hdmi_audio_v2.v
// 模块名称：top
// 功能描述：系统顶层：时钟复位、SD卡媒体播放、SDRAM帧缓存、视频叠加链路、音频混合与HDMI 1.4b输出
// 目标器件：安路 EG4S20BG256
// ============================================================================
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 下一张
    input                       key2,           // 自动播放 开/关（支持短按和长按）
    input                       key3,           // 亮度/音量调节（B1）：短按循环 正常→亮度模式→音量模式→正常，模式内长按每500ms升一级，15后回绕0
    input  [3:0]                sw,             // SW1/SW2/SW3 拨码开关，选择SW*.BMP直显；SW4拨上=显示音频波形

    output [5:0]                seg_sel,
    output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso,

    // 板载用户 SPI Flash W25Q64（掉电保存亮度/音量）
    output                      flash_cs_n,
    output                      flash_sclk,
    output                      flash_mosi,
    input                       flash_miso,
    output                      flash_wp_n,
    output                      flash_hold_n
);

assign flash_wp_n   = 1'b1;   // 不用写保护/保持，固定拉高
assign flash_hold_n = 1'b1;

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;
parameter BUF2_ADDR     = FRAME_PIXELS * 2;
parameter BUF3_ADDR     = FRAME_PIXELS * 3;

// 缩略图每格尺寸。320×240=2×2铺满全屏（2:1最近邻）；160×120=左上角布局（4:1）。
// 读侧(frame_read_write)和显示侧(thumbnail_view)必须用同一组参数。
localparam THUMB_W    = 320;
localparam THUMB_H    = 240;
localparam THUMB_STEP = 640 / THUMB_W;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire        display_valid;

wire [3:0]  state_code;
wire [6:0]  seg_data_0;

// FAT32诊断信号
wire [23:0] dbg_digits;

// 播放状态信号（sd_card_clk域产生）；auto_play_en/error_code原供左上角OSD，OSD删除后仅保留端口连接
wire [1:0]  osd_img_idx_raw;
wire        osd_auto_play_en_raw;
wire [7:0]  osd_error_code_raw;

wire [1:0]  osd_img_idx_sync;

wire [23:0] vout_data_subtitle;       // 滚动字幕叠加结果
wire        osd_sw_hold_raw;          // 拨码硬切模式（sd_card_clk域）
wire        osd_sw_shown_valid_raw;   // SW*.BMP已真正显示（sd_card_clk域），供紧急元素闪烁
wire [1:0]  osd_sw_shown_idx_raw;     // 当前显示的SW图编号（sd_card_clk域）
wire        osd_sw_on_screen_raw;     // 屏幕上正显示SW图（sd_card_clk域），亮度固定最大
wire        osd_wav_alarm_raw;        // 正在播放报警曲目（sd_card_clk域），音量固定最大
wire [1:0]  osd_nav_idx_raw;          // 导航栏目标栏目（sd_card_clk域）
wire [23:0] vout_data_nav;            // 消防员行走导航栏叠加结果
wire [1:0]  nav_cur_idx;              // 消防员已到达的栏目（video_clk域），选择滚动字幕句子
wire        nav_step_pulse;           // 消防员落脚脉冲（video_clk域），驱动脚步声
wire        nav_step_side;            // 落脚是哪只脚
wire        intro_active;             // 开机动画进行中（video_clk域，帧边界更新）
wire        intro_step_pulse;         // 开机动画消防员落脚脉冲（video_clk域），驱动脚步声
wire        intro_step_side;          // 开机动画落脚是哪条腿
wire        intro_commit_req;         // 开机动画请求提交首图（video_clk域）
wire        intro_walk_active;        // 开机动画消防员行走中（video_clk域），触发开机问候语音
wire        intro_bg_shown_raw;       // 显示bank里是BG.BMP（sd_card_clk域）
wire        intro_pic_ready_raw;      // PIC1已加载完、等开机动画放行（sd_card_clk域）
wire        first_committed_raw;      // 首张浏览图已提交（sd_card_clk域）
wire [3:0]  brightness_level_raw;     // KEY3亮度等级0~15（sd_card_clk域）
wire        brightness_mode_raw;      // KEY3亮度调节模式（sd_card_clk域）
wire [3:0]  volume_level_raw;         // KEY3音量等级0~15（sd_card_clk域）
wire        volume_mode_raw;          // KEY3音量调节模式（sd_card_clk域）
wire [23:0] vout_data_bright_bar;     // 中央亮度进度条叠加结果
wire        sd_ready_raw;             // SD卡初始化完成（sd_card_clk域），供故障提示图判断
wire [23:0] vout_data_fallback;       // SD卡故障提示图叠加结果（最终送HDMI）

// 缩略图（sd_card_clk域产生，thumbnail_view内部同步到video_clk域）
wire        thumb_view_mode_raw;
wire [1:0]  thumb_focus_raw;
wire [3:0]  thumb_image_complete_raw;
wire        thumb_view_mode_frame;     // video_clk域，本帧实际生效的模式（给frame_read_write）
wire        video_read_en_thumb;       // 缩略图模式下按区域门控后的读FIFO使能
wire [23:0] vout_data_thumb;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;
wire [31:0] video_read_data_b;        // 双路读B路读数据
wire        thumb_rd_px;              // 本帧缩略图模式，与读使能同拍
wire        thumb_out_px;             // 本帧缩略图模式，与像素输出同拍
wire        mix_active;               // 转场双路合成中（video_clk域，video_fade_transition输出）
wire        mix_read_frame;           // 本帧是否双路读（按帧锁存，给frame_read_write）
wire        mix_rd_px;                // 本帧B路读FIFO需弹出，与读使能同拍

// 转场控制握手
wire        switch_grant;
wire        fade_busy_in;
wire        switch_request;
wire        disp_commit_toggle;
wire [1:0]  prev_disp_buf_idx;
wire [1:0]  mix_buf_idx;              // 转场B路bank号（sd_card_clk域，mem域内部两级同步）
wire        vs_pre, de_pre;           // 比vs/de早一拍，与读FIFO输出同拍

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 音频发射相关
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire        acr_valid;

// WAV流式播放相关
wire               wav_sample_tick;
wire signed [15:0] wav_sample_out;
wire               wav_sample_valid;
wire               wav_stream_active;
wire               arp_audio_valid;
wire signed [23:0] arp_audio_left, arp_audio_right;
wire               mix_audio_valid;
wire signed [23:0] mix_audio_left, mix_audio_right;
wire        [7:0]  fade_gain_aud;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 复位：外部复位按键 + 两个PLL都锁定，任一未满足系统保持复位；
// 每个时钟域各配一个reset_sync，异步压下、本域时钟同步释放。
wire sys_pll_lock, video_pll_lock;
wire ext_rst_n = rst_n & sys_pll_lock & video_pll_lock;

wire sdcard_rst_n, mem_rst_n, video_rst_n;

reset_sync u_sdcard_reset (
    .clk        (sd_card_clk),
    .ext_rst_n  (ext_rst_n),
    .rst_n_sync (sdcard_rst_n)
);

reset_sync u_mem_reset (
    .clk        (ext_mem_clk),
    .ext_rst_n  (ext_rst_n),
    .rst_n_sync (mem_rst_n)
);

reset_sync u_video_reset (
    .clk        (video_clk),
    .ext_rst_n  (ext_rst_n),
    .rst_n_sync (video_rst_n)
);

sys_pll sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .reset      (~rst_n),
    .locked     (sys_pll_lock)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .reset      (~rst_n),
    .locked     (video_pll_lock)
);

// SDRAM初始化完成信号（ext_mem_clk域）同步到sd_card_clk域，
// 供TF卡扫描等待SDRAM就绪后再启动
wire sdram_init_done_sd;
sync_2ff u_sdram_init_sync (
    .clk        (sd_card_clk),
    .rst_n      (sdcard_rst_n),
    .async_in   (Sdr_init_done),
    .sync_out   (sdram_init_done_sd)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or negedge mem_rst_n) begin
    if (!mem_rst_n)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// ===================== TF 多图扫描与缓存（双缓冲） =====================
sd_card_bmp_v2 #(
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd4),
    .FRAME_PIXELS      (FRAME_PIXELS),
    // WAV音频数据区间：起始物理扇区与扇区数，0/0=关闭，不影响图片浏览功能；
    // 区间应位于SCAN_MAX_SECTOR之后，避开图片扫描区间。
    // 三段音频由tools/convert/make_audio_bank.py打包成audio_bank.pcm，
    // 以卷内偏移140000一次写入（物理LBA = 卷内偏移 + 分区起始扇区8192）。
    // 背景音乐：舒缓钢琴曲（拨码全关，循环）
    .WAV_START_LBA     (32'd148192),
    .WAV_TOTAL_SECTORS (32'd11381),
    // 报警音1：fire-alarm-15s（SW1/SW2/SW1+SW2）
    .WAV_ALARM1_START_LBA     (32'd159576),
    .WAV_ALARM1_TOTAL_SECTORS (32'd2813),
    // 报警音2：deafening-alarm-sound-15s（SW3，优先级最高）
    .WAV_ALARM2_START_LBA     (32'd162392),
    .WAV_ALARM2_TOTAL_SECTORS (32'd2813),
    // 四个栏目（图片0~3）的背景音乐+宣传语音预混段，由tools/convert/voice_column/的make_column_audio.py混音、pack_and_probe.py打包成col_bank.pcm，
    // 以卷内偏移157016写入（紧接报警音2之后）；每段语音播完间隔5秒再播，整段循环。
    .WAV_COL0_START_LBA     (32'd165208),
    .WAV_COL0_TOTAL_SECTORS (32'd8430),
    .WAV_COL1_START_LBA     (32'd173640),
    .WAV_COL1_TOTAL_SECTORS (32'd9185),
    .WAV_COL2_START_LBA     (32'd182832),
    .WAV_COL2_TOTAL_SECTORS (32'd8672),
    .WAV_COL3_START_LBA     (32'd191504),   // 紧接col2之后，按8扇区对齐
    .WAV_COL3_TOTAL_SECTORS (32'd9499),
    // 每段里一遍语音的采样数（make_column_audio.py 修剪后的长度），自动播放据此在语音间隔切图
    .WAV_COL0_VOICE_SAMPLES (32'd479282),
    .WAV_COL1_VOICE_SAMPLES (32'd543719),
    .WAV_COL2_VOICE_SAMPLES (32'd500006),
    .WAV_COL3_VOICE_SAMPLES (32'd570497),
    // 开机问候（背景乐+问候语音预混的裸PCM段，1701扇区），开机动画开始行走时播一遍。
    // 卷内偏移 192824~194524（紧接栏目段之后，所在簇 5003~5056 在 FAT 中未分配）。
    .WAV_INTRO_START_LBA     (32'd201016),
    .WAV_INTRO_TOTAL_SECTORS (32'd1701)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (~sdcard_rst_n),
    .sdram_ready       (sdram_init_done_sd),
    .key_next          (key1),
    .key_auto          (key2),
    .key_vol           (key3),
    .sw_in             (sw[2:0]),       // SW4不参与图片选择，只在顶层控制波形显示
    .state_code        (state_code),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (display_valid),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso),
    .flash_cs_n        (flash_cs_n),
    .flash_sclk        (flash_sclk),
    .flash_mosi        (flash_mosi),
    .flash_miso        (flash_miso),

    .osd_img_idx        (osd_img_idx_raw),
    .osd_auto_play_en   (osd_auto_play_en_raw),
    .osd_error_code     (osd_error_code_raw),
    .osd_sw_hold        (osd_sw_hold_raw),
    .osd_sw_shown_valid (osd_sw_shown_valid_raw),
    .osd_sw_shown_idx   (osd_sw_shown_idx_raw),
    .osd_sw_on_screen   (osd_sw_on_screen_raw),
    .osd_wav_alarm      (osd_wav_alarm_raw),
    .osd_nav_idx        (osd_nav_idx_raw),
    .intro_bg_shown     (intro_bg_shown_raw),
    .intro_pic_ready    (intro_pic_ready_raw),
    .first_committed    (first_committed_raw),
    .intro_commit_req   (intro_commit_req),
    .intro_walk         (intro_walk_active),
    .brightness_level   (brightness_level_raw),
    .brightness_mode    (brightness_mode_raw),
    .volume_level       (volume_level_raw),
    .volume_mode        (volume_mode_raw),
    .sd_ready           (sd_ready_raw),

    .view_mode          (thumb_view_mode_raw),
    .focus_index        (thumb_focus_raw),
    .image_complete     (thumb_image_complete_raw),

    .switch_grant       (switch_grant),
    .fade_busy_in       (fade_busy_in),
    .switch_request     (switch_request),
    .disp_commit_toggle (disp_commit_toggle),
    .prev_disp_buf_idx  (prev_disp_buf_idx),
    .mix_buf_idx        (mix_buf_idx),

    .dbg_page           (2'd0),          // 开关用于图片选择，诊断固定为页0（流水线状态）
    .dbg_digits         (dbg_digits),

    // WAV音频流式播放，读侧挂在video_clk域
    .rd_clk             (video_clk),
    .rd_rst_n           (video_rst_n),
    .sample_tick        (wav_sample_tick),
    .wav_sample_out     (wav_sample_out),
    .wav_sample_valid   (wav_sample_valid),
    .wav_stream_active  (wav_stream_active)
);

// ===================== 数码管：FAT32诊断显示 =====================
// 诊断页由dbg_page选择（当前固定接0，只显示页0），页内容见 sd_card_bmp_v2.v 的诊断段注释。
// seg_data_0 显示在最左边，故接最高位数字 dbg_digits[23:20]。
// FAT32_DIAG 置0可恢复成只显示图片编号。
localparam FAT32_DIAG = 1;

wire [6:0] seg_d0, seg_d1, seg_d2, seg_d3, seg_d4, seg_d5;

seg_decoder u_seg_d0 (.bin_data(dbg_digits[23:20]), .seg_data(seg_d0));
seg_decoder u_seg_d1 (.bin_data(dbg_digits[19:16]), .seg_data(seg_d1));
seg_decoder u_seg_d2 (.bin_data(dbg_digits[15:12]), .seg_data(seg_d2));
seg_decoder u_seg_d3 (.bin_data(dbg_digits[11:8]),  .seg_data(seg_d3));
seg_decoder u_seg_d4 (.bin_data(dbg_digits[7:4]),   .seg_data(seg_d4));
seg_decoder u_seg_d5 (.bin_data(dbg_digits[3:0]),   .seg_data(seg_d5));

seg_decoder seg_decoder_m0(
    .bin_data          (state_code),
    .seg_data          (seg_data_0)
);

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        (FAT32_DIAG ? {1'b1,seg_d0} : {1'b1,seg_data_0}),
    .seg_data_1        (FAT32_DIAG ? {1'b1,seg_d1} : {1'b1,7'b1111_111}),
    .seg_data_2        (FAT32_DIAG ? {1'b1,seg_d2} : {1'b1,7'b1111_111}),
    .seg_data_3        (FAT32_DIAG ? {1'b1,seg_d3} : {1'b1,7'b1111_111}),
    .seg_data_4        (FAT32_DIAG ? {1'b1,seg_d4} : {1'b1,7'b1111_111}),
    .seg_data_5        (FAT32_DIAG ? {1'b1,seg_d5} : {1'b1,7'b1111_111})
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (~video_rst_n),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (~video_rst_n),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw),
    .read_data_b       (video_read_data_b[31:8]),
    .vout_data_b       (),
    .vs_pre            (vs_pre),
    .de_pre            (de_pre)
);

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容。
// 门控信号用同步到video_clk域的player_active_sync，assign位于其声明之后（见下方"转场：跨域信号同步"段）。

// ===================== 缩略图显示通路 =====================
// 显示链路：A/B双路合成(转场) → 缩略图着色(vout_data_thumb) → 亮度alpha → 导航栏 → 滚动字幕 → 波形 → AXIS/HDMI。
// 全屏模式下原样通过；缩略图模式下2×2缩略图铺满全屏（每格THUMB_W×THUMB_H=320×240，
// 2:1最近邻缩小），焦点格画金黄色2像素边框，未加载的格子显示深灰占位。
// 读FIFO使能经本模块按区域门控，与frame_fifo_read的缩略图读地址序列
// （每屏幕行读2个源行、写FIFO时每THUMB_STEP个取1个）配合。
thumbnail_view #(
    .THUMB_WIDTH          (THUMB_W),
    .THUMB_HEIGHT         (THUMB_H)
) u_thumbnail_view (
    .clk                  (video_clk),
    .rst_n                (video_rst_n),
    .vs_in                (vs_0),
    .de_in                (de_0),
    .view_mode_async      (thumb_view_mode_raw),
    .focus_async          (thumb_focus_raw),
    .image_complete_async (thumb_image_complete_raw),
    .read_en_in           (video_read_en),
    .read_en_out          (video_read_en_thumb),
    .rgb_in               (vout_data),
    .rgb_out              (vout_data_thumb),
    .view_mode_frame      (thumb_view_mode_frame),
    .thumb_rd             (thumb_rd_px),
    .thumb_px             (thumb_out_px),
    .mix_req              (mix_active),
    .mix_mode_frame       (mix_read_frame),
    .mix_rd               (mix_rd_px)
);

// ===================== 当前图片编号跨域 =====================
// osd_img_idx由sd_card_clk域产生，两级打拍同步到video_clk域（变化很慢，双flop足够），供媒体音调使用。
// 图片编号、自动播放状态与错误码不在画面上显示，由数码管显示，auto_play_en/error_code不引到video_clk域。
reg [1:0] osd_img_idx_meta,  osd_img_idx_sync_r;

always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        osd_img_idx_meta    <= 2'd0;
        osd_img_idx_sync_r  <= 2'd0;
    end else begin
        osd_img_idx_meta    <= osd_img_idx_raw;
        osd_img_idx_sync_r  <= osd_img_idx_meta;
    end
end

assign osd_img_idx_sync     = osd_img_idx_sync_r;

// ===================== 转场：跨域信号同步 =====================
// disp_commit_toggle由sd_card_clk域产生，两级打拍到video_clk域后
// 做边沿检测生成1周期index_commit脉冲。
reg        commit_tgl_meta,  commit_tgl_sync_r, commit_tgl_sync_r2;
reg        player_active_meta, player_active_sync_r;

always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        commit_tgl_meta     <= 1'b0;
        commit_tgl_sync_r   <= 1'b0;
        commit_tgl_sync_r2  <= 1'b0;
        player_active_meta  <= 1'b0;
        player_active_sync_r<= 1'b0;
    end else begin
        commit_tgl_meta     <= disp_commit_toggle;
        commit_tgl_sync_r   <= commit_tgl_meta;
        commit_tgl_sync_r2  <= commit_tgl_sync_r;
        player_active_meta  <= display_valid;
        player_active_sync_r<= player_active_meta;
    end
end

wire       player_active_sync     = player_active_sync_r;
wire       index_commit = (commit_tgl_sync_r != commit_tgl_sync_r2);


// frame_start：对原始vsync(vs_0)做下降沿检测，产生1周期脉冲，供淡入淡出状态机计帧。
reg vs_0_d;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n)
        vs_0_d <= 1'b0;
    else
        vs_0_d <= vs_0;
end
wire frame_start = vs_0_d & ~vs_0;

wire [7:0] fade_alpha_out;
wire [7:0] fade_gain_alpha;    // 音频转场包络（中点压到约一半）
wire [3:0] shape_kind;         // 合成类型，0=交叉淡化，共10种轮换
wire       shape_in;
wire [8:0] shape_q;

// 转场（不经全黑）按次轮换：交叉淡化 → 撕裂(中间往两边) → 轮子 → 圆形光圈 → 燃烧纸张 → …
// 合成见下方"转场双路合成"段（transition_shape_mask_24）。
video_fade_transition #(
    .FADE_FRAMES (90)    // 旧图→新图合成帧数：约1.5秒@60Hz（手动/自动共用）
) u_video_fade_transition (
    .ctrl_clk         (sd_card_clk),
    .ctrl_rst_n       (sdcard_rst_n),
    .next_event_in    (switch_request),
    .next_event_out   (switch_grant),
    .fade_busy        (fade_busy_in),

    .pix_clk          (video_clk),
    .pix_rst_n        (video_rst_n),
    .player_active    (player_active_sync),
    .frame_start      (frame_start),
    .index_commit     (index_commit),
    .alpha_out        (fade_alpha_out),
    .gain_alpha_out   (fade_gain_alpha),
    .fade_active      (),
    .mix_active       (mix_active),
    .shape_kind       (shape_kind),
    .shape_in         (shape_in),
    .shape_q          (shape_q)
);

// ===================== 亮度调节（KEY3）=====================
// 亮度等级由sd_card_clk域产生，两级打拍到video_clk域后在frame_start锁存，
// 保证一帧内亮度不变、不出现上下半帧分界。
// 亮度折进转场alpha，与淡入淡出共用同一组RGB乘法器：
//   亮度系数按γ=2.2感知均匀16档查表，16~256（等级15时256/256=1，与原画面逐位一致）
//   eff_alpha = 亮度系数，9位（16~256），满亮度时eff_alpha=256，像素乘256>>8与原画面逐位一致
// eff_alpha只在帧边界附近变化，打一拍寄存不影响像素对齐。
reg [3:0] bright_meta, bright_sync_r, bright_level_frame;
reg       bright_mode_meta, bright_mode_sync_r;   // 亮度模式标志，供中央进度条使用（模块内帧边界锁存）
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        bright_meta        <= 4'd15;
        bright_sync_r      <= 4'd15;
        bright_level_frame <= 4'd15;
        bright_mode_meta   <= 1'b0;
        bright_mode_sync_r <= 1'b0;
    end else begin
        bright_meta   <= brightness_level_raw;
        bright_sync_r <= bright_meta;
        bright_mode_meta   <= brightness_mode_raw;
        bright_mode_sync_r <= bright_mode_meta;
        if (frame_start)
            bright_level_frame <= bright_sync_r;
    end
end

// ===================== 音量调节（KEY3）=====================
// 与亮度相同：两级打拍到video_clk域，frame_start锁存，中央进度条与实际音量同帧一致。
reg [3:0] vol_meta, vol_sync_r, vol_level_frame;
reg       vol_mode_meta, vol_mode_sync_r;          // 音量模式标志，供中央进度条使用
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        vol_meta        <= 4'd15;
        vol_sync_r      <= 4'd15;
        vol_level_frame <= 4'd15;
        vol_mode_meta   <= 1'b0;
        vol_mode_sync_r <= 1'b0;
    end else begin
        vol_meta   <= volume_level_raw;
        vol_sync_r <= vol_meta;
        vol_mode_meta   <= volume_mode_raw;
        vol_mode_sync_r <= vol_mode_meta;
        if (frame_start)
            vol_level_frame <= vol_sync_r;
    end
end

// ===================== 拨码紧急内容：亮度、音量固定最大 =====================
// SW图在屏幕上时亮度按15档（系数256）、播放报警曲目时音量按15档，不受KEY3设定影响；
// KEY3设定的等级保持不变，中央进度条仍显示设定值，回到普通图片/背景音乐后恢复。
// 两个标志都是sd_card_clk域准静态电平，两级打拍后在frame_start锁存，与亮度/音量等级同帧生效。
reg sw_full_meta, sw_full_sync_r, sw_full_frame;
reg alarm_meta,   alarm_sync_r,   alarm_frame;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        sw_full_meta   <= 1'b0;
        sw_full_sync_r <= 1'b0;
        sw_full_frame  <= 1'b0;
        alarm_meta     <= 1'b0;
        alarm_sync_r   <= 1'b0;
        alarm_frame    <= 1'b0;
    end else begin
        sw_full_meta   <= osd_sw_on_screen_raw;
        sw_full_sync_r <= sw_full_meta;
        alarm_meta     <= osd_wav_alarm_raw;
        alarm_sync_r   <= alarm_meta;
        if (frame_start) begin
            sw_full_frame <= sw_full_sync_r;
            alarm_frame   <= alarm_sync_r;
        end
    end
end
wire [3:0] bright_level_eff = sw_full_frame ? 4'd15 : bright_level_frame;
wire [3:0] vol_level_eff    = alarm_frame   ? 4'd15 : vol_level_frame;

// L*等间隔亮度表。满白×系数→γ=2.2换光强→CIE L*，16~256之间L*等分15份反推系数，
// 最暗16、最亮256，相邻档ΔL* 6.20~6.79（max/min 1.10），各档主观亮度变化均匀。
// 不在码值上再套γ=2.2，否则等于算两遍伽马，暗档挤在一起、亮档跨度过大。
reg [8:0] bright_gain;   // 16~256
always @(*) begin
    case (bright_level_eff)
        4'd0:  bright_gain = 9'd16;
        4'd1:  bright_gain = 9'd31;
        4'd2:  bright_gain = 9'd43;
        4'd3:  bright_gain = 9'd55;
        4'd4:  bright_gain = 9'd69;
        4'd5:  bright_gain = 9'd83;
        4'd6:  bright_gain = 9'd98;
        4'd7:  bright_gain = 9'd113;
        4'd8:  bright_gain = 9'd129;
        4'd9:  bright_gain = 9'd146;
        4'd10: bright_gain = 9'd163;
        4'd11: bright_gain = 9'd181;
        4'd12: bright_gain = 9'd199;
        4'd13: bright_gain = 9'd218;
        4'd14: bright_gain = 9'd237;
        default: bright_gain = 9'd256;
    endcase
end
// 转场不再渐暗，fade_alpha_out恒为255（按256参与计算），256*亮度系数>>8即亮度系数本身，
// 故eff_alpha直接取bright_gain，省去一个乘法器。
reg  [8:0]  eff_alpha;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n)
        eff_alpha <= 9'd0;
    else
        eff_alpha <= bright_gain;
end

// 亮度像素混合：转场已不再渐暗（fade_alpha恒255），这里只做KEY3亮度。
// 混合输入为缩略图着色后的vout_data_thumb
// KEY3亮度：乘数为折入亮度后的eff_alpha
// 乘积最大255*256=65280，取[15:8]最大255，不会溢出
// 满亮度且无转场（eff_alpha=256，即最高位为1）时像素乘256>>8就是原像素：
// 输出直接取原像素，乘法器输入清零保持不变，乘法器不随像素翻转。
wire        alpha_full  = eff_alpha[8];
wire [23:0] fade_mul_in = alpha_full ? 24'd0 : vout_data_thumb;
wire [16:0] fade_r17 = fade_mul_in[23:16] * eff_alpha;
wire [16:0] fade_g17 = fade_mul_in[15:8]  * eff_alpha;
wire [16:0] fade_b17 = fade_mul_in[7:0]   * eff_alpha;
wire [23:0] vout_data_transition = alpha_full ? vout_data_thumb
                                              : { fade_r17[15:8], fade_g17[15:8], fade_b17[15:8] };

// pixel_x：本项目视频时序模块只输出hs/vs/de，没有像素列计数，
// 这里在de有效期内自行计数还原（每行de拉低时清零，与line_y的
// 重建方式一致），供各叠加层做水平方向的定位。
reg [9:0] pixel_x_cnt;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n)
        pixel_x_cnt <= 10'd0;
    else if (!de)
        pixel_x_cnt <= 10'd0;
    else
        pixel_x_cnt <= pixel_x_cnt + 10'd1;
end

// ===================== 转场双路合成（不经全黑）=====================
// 转场期间（含准备帧）双路读：A路=显示bank（disp_buf_idx），B路=转场目标bank（mix_buf_idx），两路同拍读出；
// 空闲帧只读A路，SDRAM读带宽减半。是否读B路由thumbnail_view按帧锁存，mem侧与像素侧同帧生效。
// 合成放在读FIFO输出与像素寄存器之间：de_pre/vs_pre/pixel_x_pre比de早一拍，合成结果打一拍
// 后与原vout_data_raw同拍（与video_delay的像素寄存器逐位等价），不增加像素延迟，
// 也把交叉淡化的乘法与后面的亮度乘法隔开在两级寄存器之间。
// 空闲时直通A路；缩略图帧不启用双路读（B路FIFO不读），直接取A路的vout_data_raw。
// 准备帧q=0只显示A路，故B路从准备阶段任何一帧开始读都不影响画面。
// 合成只作用于图片本身，导航栏/字幕/进度条等叠加层都在后面，不受影响。
wire        mix_read_en_b = video_read_en_thumb & mix_rd_px;

reg [9:0] pixel_x_pre;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n)
        pixel_x_pre <= 10'd0;
    else if (!de_pre)
        pixel_x_pre <= 10'd0;
    else
        pixel_x_pre <= pixel_x_pre + 10'd1;
end

wire [23:0] mix_rgb_pre;
transition_shape_mask_24 u_transition_shape_mask_24 (
    .clk           (video_clk),
    .rst_n         (video_rst_n),
    .vsync         (vs_pre),
    .de            (de_pre),
    .rgb_a         (video_read_data[31:8]),
    .rgb_b         (video_read_data_b[31:8]),
    .pixel_x       (pixel_x_pre),
    .mix_active    (mix_active),
    .shape_kind    (shape_kind),
    .shape_in      (shape_in),
    .shape_q       (shape_q),
    .rgb_out       (mix_rgb_pre),
    .mask_active   ()
);

reg [23:0] vout_data_mix;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n)
        vout_data_mix <= 24'd0;
    else if (de_pre)
        vout_data_mix <= mix_rgb_pre;
    else
        vout_data_mix <= 24'd0;
end

wire [23:0] vout_data_ab = thumb_out_px ? vout_data_raw : vout_data_mix;
assign vout_data = player_active_sync ? vout_data_ab : 24'd0;

// 形状转场已在上面合成完成，这里不再遮罩
wire [23:0] vout_data_shape = vout_data_transition;

// ===================== 硬切/缩略图时隐藏导航栏与滚动字幕 =====================
// sw_hold由sd_card_clk域产生（拨码直显模式，含退出过程），两级打拍同步到video_clk域，
// 再在frame_start锁存，保证整帧要么全显示、要么全隐藏，不会出现半帧字幕。
// 缩略图模式用thumbnail_view输出的thumb_view_mode_frame（video_clk域、已按帧锁存，
// 与缩略图画面实际生效同帧），无需再同步。
// SW4为异步拨码输入，同样两级打拍+帧锁存，拨上=显示音频波形（不需消抖：抖动最多闪几帧）。
reg osd_sw_hold_meta, osd_sw_hold_sync_r;
reg wave_sw_meta, wave_sw_sync_r, wave_show_frame;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        osd_sw_hold_meta   <= 1'b0;
        osd_sw_hold_sync_r <= 1'b0;
        wave_sw_meta       <= 1'b0;
        wave_sw_sync_r     <= 1'b0;
        wave_show_frame    <= 1'b0;
    end else begin
        osd_sw_hold_meta   <= osd_sw_hold_raw;
        osd_sw_hold_sync_r <= osd_sw_hold_meta;
        wave_sw_meta       <= sw[3];
        wave_sw_sync_r     <= wave_sw_meta;
        if (frame_start) begin
            wave_show_frame <= wave_sw_sync_r;
        end
    end
end

wire subtitle_show = !osd_sw_hold_sync_r && !thumb_view_mode_frame;

// ===================== 消防员行走导航栏（第0~51行）=====================
// 四个栏目 充电桩安全/公共区域安全/家庭用电安全/消防通道安全 对应浏览图片0~3。
// 切图请求一发出，osd_nav_idx就变为目标图；小人在转场过程中走到目标栏目，到达后选中标签变黄，
// 下方滚动字幕换成该栏目的句子。放在形状遮罩之后、滚动字幕之前：不被转场遮挡。
// 与滚动字幕同一显示条件（硬切/缩略图时隐藏，隐藏期间小人直接落在目标栏目）。
// 2位编号两级打拍跨域，导航栏模块内再按帧做两次一致采样，避免两位不同时翻转时采到中间值。
reg [1:0] nav_idx_meta, nav_idx_sync_r;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        nav_idx_meta   <= 2'd0;
        nav_idx_sync_r <= 2'd0;
    end else begin
        nav_idx_meta   <= osd_nav_idx_raw;
        nav_idx_sync_r <= nav_idx_meta;
    end
end

fireman_nav_bar_24 #(
    .H_ACTIVE    (640),
    .BAND_H      (52),
    .SPRITE_Y    (2),
    .LABEL_Y     (34),
    .ULINE_Y     (50),
    .BG_Y        (32)                  // 白底从第32行起（标签上方多2行，第32~51行），小人最下2行落在白底上
) u_fireman_nav_bar_24 (
    .clk         (video_clk),
    .rst_n       (video_rst_n),
    .vsync       (vs),
    .de          (de),
    .rgb_in      (vout_data_shape),
    .pixel_x     (pixel_x_cnt),
    .enable      (subtitle_show),      // 模块内部在帧边界锁存
    .target_idx  (nav_idx_sync_r),
    .hold        (intro_active),       // 开机动画期间不画、不走
    .rgb_out     (vout_data_nav),
    .cur_idx     (nav_cur_idx),
    .step_pulse  (nav_step_pulse),
    .step_side   (nav_step_side),
    .nav_active  ()
);

// 导航栏下方的分栏目滚动字幕：屏幕第52~91行半透明暗条，金黄32×32汉字从右向左滚动，
// 句子随消防员已到达的栏目切换（换句时从右侧重新进入）。放在导航栏之后、波形之前。
scroll_subtitle_24 #(
    .H_ACTIVE    (640),
    .BAND_Y      (52),
    .BAND_H      (40),
    .TEXT_Y      (56),
    .SCROLL_STEP (2)
) u_scroll_subtitle_24 (
    .clk             (video_clk),
    .rst_n           (video_rst_n),
    .vsync           (vs),
    .de              (de),
    .rgb_in          (vout_data_nav),
    .pixel_x         (pixel_x_cnt),
    .enable          (subtitle_show && !intro_active),  // 开机动画期间隐藏；模块内部在帧边界锁存
    .sentence        (nav_cur_idx),
    .rgb_out         (vout_data_subtitle),
    .subtitle_active ()
);

// KEY3亮度/音量模式：屏幕中央"亮度调节"或"音量调节"字幕+16格进度条（面板第184~295行）。
// 放在亮度折叠之后，面板本身不随画面变暗；放在字幕之后、波形之前，三者互不重叠。
// 等级取已在frame_start锁存的bright_level_frame，与画面实际亮度同帧一致。
// SW图在屏幕上时（sw_full_frame=1）两个调节界面都不显示；KEY3模式与等级照常保留。
brightness_bar_24 u_brightness_bar_24 (
    .clk        (video_clk),
    .rst_n      (video_rst_n),
    .vsync      (vs),
    .de         (de),
    .rgb_in     (vout_data_subtitle),
    .pixel_x    (pixel_x_cnt),
    .enable     ((bright_mode_sync_r | vol_mode_sync_r) && !sw_full_frame),  // 模块内部在帧边界锁存
    .title_sel  (vol_mode_sync_r),                          // 0=亮度调节 1=音量调节
    .level      (vol_mode_sync_r ? vol_level_frame : bright_level_frame),
    .rgb_out    (vout_data_bright_bar),
    .bar_active ()
);

frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480),
    .THUMB_HEIGHT     (THUMB_H),     // 与thumbnail_view同一组缩略图参数
    .THUMB_STEP       (THUMB_STEP)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (~mem_rst_n),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (BUF2_ADDR),
    .read_addr_3       (BUF3_ADDR),
    .read_addr_index   (disp_buf_idx),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en_thumb),
    .read_data         (video_read_data),
    .read_thumb_mode   (thumb_view_mode_frame),   // 本帧缩略图读模式
    .read_mix_en       (mix_read_frame),          // 转场帧双路读（缩略图帧mem侧自动关闭）
    .read_mix_index    (mix_buf_idx),             // B路=转场目标bank
    .read_en_b         (mix_read_en_b),
    .read_data_b       (video_read_data_b),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (BUF2_ADDR),
    .write_addr_3      (BUF3_ADDR),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (~mem_rst_n),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== 音频：媒体音调联动（切图播提示音+对应图片的六音符琶音循环） =====================
pcm_media_tone u_pcm_media_tone (
    .clk          (video_clk),
    .rst          (~video_rst_n),
    .sample_tick  (wav_sample_tick),
    .media_id     (osd_img_idx_sync),
    .audio_valid  (arp_audio_valid),
    .audio_left   (arp_audio_left),
    .audio_right  (arp_audio_right)
);

// ===================== WAV音频流式播放 =====================
// 采样节拍：全工程唯一的48kHz NCO，WAV读侧与pcm_media_tone共用，
// 在video_clk(25MHz)域平均锁定到48kHz。
audio_sample_tick_gen #(
    .CLK_HZ    (25_000_000),
    .SAMPLE_HZ (48_000)
) u_wav_sample_tick_gen (
    .clk         (video_clk),
    .rst         (~video_rst_n),
    .sample_tick (wav_sample_tick)
);

// wav_stream_player输出16位有符号PCM，左移7位对齐到24位，
// 与pcm_media_tone的VOL_SHIFT=7保持同一套响度基准，单声道复制到左右声道。
wire signed [23:0] wav_audio_24 = { {1{wav_sample_out[15]}}, wav_sample_out, 7'b0 };

// 音频源选择：WAV播放优先于琶音，播放结束/未配置时自动回落到琶音。
// 本工程硬件只有3个按键且均已用于图片浏览，没有空闲输入可做force_arpeggio
// 拨码，固定接0。
audio_source_mux u_audio_source_mux (
    .wav_active     (wav_stream_active),
    .force_arpeggio (1'b0),
    .wav_valid      (wav_sample_valid),
    .wav_left       (wav_audio_24),
    .wav_right      (wav_audio_24),
    .arp_valid      (arp_audio_valid),
    .arp_left       (arp_audio_left),
    .arp_right      (arp_audio_right),
    .out_valid      (mix_audio_valid),
    .out_left       (mix_audio_left),
    .out_right      (mix_audio_right)
);

// 音画同步转场音量：复用上面已经算出的fade_gain_alpha（转场中点压低约6dB）/frame_start，
// 音频域就是video_clk本身（本工程HDMI音频链直接工作在video_clk域，没有独立的
// I2S时钟），所以pix_clk和aud_clk都传video_clk——2FF同步退化为同域打拍，
// 逻辑仍然成立，只是不跨真实时钟域。
sync_fade_gain u_sync_fade_gain (
    .pix_clk     (video_clk),
    .pix_rst_n   (video_rst_n),
    .frame_start (frame_start),
    .alpha_pix   (fade_gain_alpha),   // 转场中点压到约一半再回升
    .aud_clk     (video_clk),
    .aud_rst_n   (video_rst_n),
    .gain_aud    (fade_gain_aud)
);

// 增益应用：增益为Q12（4096=0dB），只会衰减不会放大，不需要饱和保护。
// 两路音源（WAV、琶音）都是单声道复制到左右声道，且24位样本 = 16位样本<<7
// （[22:7]即16位样本），因此 (样本24 * gain/4096) == (样本16 * gain) >>> 5，
// 只用一个16x14位乘法，结果同时送左右声道。
wire signed [15:0] mix_audio_16 = mix_audio_left[22:7];
// KEY3音量：按听感等分。感知响度N∝振幅^0.6（Stevens），N在等级0(-22.5dB)与等级15(0dB)之间线性等分，
// Q12系数=round(4096*N^(1/0.6))，307~4096；每档响度约+5%，dB步进由低端3.2dB渐变到高端0.8dB。
reg [12:0] vol_gain;   // Q12，307~4096
always @(*) begin
    case (vol_level_eff)
        4'd0:  vol_gain = 13'd307;
        4'd1:  vol_gain = 13'd445;
        4'd2:  vol_gain = 13'd602;
        4'd3:  vol_gain = 13'd778;
        4'd4:  vol_gain = 13'd971;
        4'd5:  vol_gain = 13'd1181;
        4'd6:  vol_gain = 13'd1408;
        4'd7:  vol_gain = 13'd1649;
        4'd8:  vol_gain = 13'd1906;
        4'd9:  vol_gain = 13'd2178;
        4'd10: vol_gain = 13'd2464;
        4'd11: vol_gain = 13'd2763;
        4'd12: vol_gain = 13'd3077;
        4'd13: vol_gain = 13'd3404;
        4'd14: vol_gain = 13'd3743;
        default: vol_gain = 13'd4096;
    endcase
end
// 转场包络0~255映射到0~256（255→256），非转场时增益精确等于音量表值；
// 与音量系数相乘后舍入回Q12并寄存为目标增益（两者都是准静态量，晚一拍无影响）。
wire [8:0]  fade_gain_q8   = fade_gain_aud + fade_gain_aud[7];
wire [21:0] aud_gain_prod  = fade_gain_q8 * vol_gain;           // 最大256*4096=2^20
reg  [12:0] aud_gain_tgt;     // Q12，0~4096
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n)
        aud_gain_tgt <= 13'd4096;
    else
        aud_gain_tgt <= (aud_gain_prod + 22'd128) >> 8;
end
// 增益一阶平滑：每个48kHz样本 g += (t-g)>>>6（时间常数约1.3ms），
// 差值不足一步时按±1收敛，保证最终精确等于目标；消除换档与转场包络按帧阶跃的拉链噪声。
reg  [12:0] aud_gain_eff;     // Q12，0~4096
wire signed [13:0] aud_gain_diff = $signed({1'b0, aud_gain_tgt}) - $signed({1'b0, aud_gain_eff});
wire signed [13:0] aud_gain_step = (aud_gain_diff >>> 6) != 14'sd0 ? (aud_gain_diff >>> 6) :
                                   (aud_gain_diff > 14'sd0) ? 14'sd1 :
                                   (aud_gain_diff < 14'sd0) ? -14'sd1 : 14'sd0;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n)
        aud_gain_eff <= 13'd4096;
    else if (wav_sample_tick)
        aud_gain_eff <= aud_gain_eff + aud_gain_step[12:0];
end

wire signed [29:0] gain_prod    = mix_audio_16 * $signed({1'b0, aud_gain_eff});

// 消防员脚步声：只由开机动画消防员的落脚脉冲触发，与行走动作逐帧同步（同在video_clk域，不跨时钟域）。
// 导航栏小人行走（切图转场）时不发脚步声，nav_step_pulse 不接入（综合会裁掉其逻辑）。
// 混在转场包络之后，转场期间背景音被压低时脚步声仍清晰；只受KEY3音量档控制。
// 小人只在导航栏显示时行走，硬切/缩略图模式下自然无脚步声。
wire signed [15:0] foot_pcm;
footstep_synth u_footstep_synth (
    .clk         (video_clk),
    .rst         (~video_rst_n),
    .sample_tick (wav_sample_tick),
    .trig        (intro_step_pulse),
    .trig_side   (intro_step_side),
    .foot_out    (foot_pcm)
);
// 位宽：|gain_prod|、|foot_prod| ≤ 32768*4096，和 ≤ 2^28，舍入后>>>5 落在24位有符号范围内，不需要饱和。
wire signed [29:0] foot_prod = foot_pcm * $signed({1'b0, vol_gain});   // 无脚步时foot_pcm=0，乘法器不翻转
wire signed [30:0] mix_sum   = gain_prod + foot_prod + 31'sd16;
wire signed [30:0] mix_out   = mix_sum >>> 5;

assign audio_valid      = mix_audio_valid;
assign audio_left_data  = mix_out[23:0];
assign audio_right_data = mix_out[23:0];

audio_arc_calculate #(
    .ACR_N         (6144),
    .ACR_CTS       (25000)      // video_clk 25MHz / 48kHz：改像素时钟或采样率时须同步修改
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (~video_rst_n),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ===================== 音频波形可视化 =====================
// 显示链路：A/B双路合成(转场) → 亮度alpha → 消防员导航栏 → 滚动字幕 → 中央亮度进度条 → 波形+峰值条叠加 → 紧急闪烁 → 开机动画 → SD卡故障提示图 → AXIS/HDMI。
// 采样抽头取最终送HDMI的音频（混音+转场增益之后），屏幕上的波形与耳朵
// 听到的完全一致：转场中点波形幅度也随音量一起收小。24位音频是16位
// 样本左移7位得到的（WAV与琶音同一套VOL_SHIFT=7），[22:7]即还原的16位样本。
// 使能取wav_stream_active && SW4：TF卡音乐真正在播放且SW4拨上时才显示波形，
// 同时也是一个直观的诊断信号——看到波形就说明WAV链路已经接通。
wire [23:0] vout_data_wave;

promax_audio_waveform #(
    .WAVE_X      (64),
    .WAVE_Y      (400),
    .WAVE_WIDTH  (512),
    .WAVE_HEIGHT (64),
    // 波形总长不变，每段绿色横条由16像素缩短到4像素：采样点32→128、抽取率12→3，
    // 显示的时间窗仍是384个样本（8ms），分辨率提高4倍，台阶更细、波形更平滑。
    // 原值：SAMPLE_COUNT=32（模块默认）、DECIMATE=12；中间试过64/6（8像素）。
    .SAMPLE_COUNT(128),
    .DECIMATE    (3),
    // 显示增益×4（只放大画面，不影响声音）。按《第一天》前20秒实测：峰值-1.5dBFS、
    // RMS仅-22dBFS，×1时波形中位偏移只有1像素；×4时中位6像素/90%分位16像素，
    // 峰值条20~29像素，削顶仅0.6%；×8峰值条长期顶满，失去指示意义。
    .GAIN_SHIFT  (2)
) u_promax_audio_waveform (
    .clk             (video_clk),
    .rst_n           (video_rst_n),
    .vsync           (vs),
    .de              (de),
    .rgb_in          (vout_data_bright_bar),
    .pixel_x         (pixel_x_cnt),
    .enable          (wav_stream_active && wave_show_frame && !intro_active),   // WAV播放中且SW4拨上才显示，开机动画期间隐藏
    .pcm_tap_valid   (audio_valid),
    .pcm_tap_left    (audio_left_data[22:7]),
    .rgb_out         (vout_data_wave),
    .waveform_active ()
);

// ===================== 紧急情况局部元素闪烁 + 画面四周红框 =====================
// 拨码紧急场景（SW1/SW2火警、SW3紧急疏散/地震报警）时，SW图中的三角警示牌边框和
// 主标题约3Hz亮暗交替，画面四周16像素红框同步闪烁（亮相显示、暗相熄灭）。
// 使能取"SW图已真正显示"而不是sw_hold：新图写完、显示bank切过去之后才按该图的区域闪，
// 避免读卡那几帧按新图坐标去闪旧图。valid/idx由sd_card_clk域两级打拍同步，
// 模块内部只在帧边界接受连续两拍一致的值。
// 放在波形之后、SD卡故障提示图之前：故障提示图仍然覆盖一切。
reg       sw_shown_valid_meta, sw_shown_valid_sync_r;
reg [1:0] sw_shown_idx_meta,   sw_shown_idx_sync_r;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        sw_shown_valid_meta   <= 1'b0;
        sw_shown_valid_sync_r <= 1'b0;
        sw_shown_idx_meta     <= 2'd0;
        sw_shown_idx_sync_r   <= 2'd0;
    end else begin
        sw_shown_valid_meta   <= osd_sw_shown_valid_raw;
        sw_shown_valid_sync_r <= sw_shown_valid_meta;
        sw_shown_idx_meta     <= osd_sw_shown_idx_raw;
        sw_shown_idx_sync_r   <= sw_shown_idx_meta;
    end
end

wire [23:0] vout_data_emerg;

emergency_element_flash_24 #(
    .H_ACTIVE      (640),
    .V_ACTIVE      (480),
    .TOGGLE_FRAMES (10),
    .BORDER        (16),
    .BORDER_COLOR  (24'hFF0000),
    .MARGIN        (6),
    .KNEE          (16),
    .DIM_SHIFT     (2)
) u_emergency_element_flash_24 (
    .clk           (video_clk),
    .rst_n         (video_rst_n),
    .vsync         (vs),
    .de            (de),
    .rgb_in        (vout_data_wave),
    .pixel_x       (pixel_x_cnt),
    .enable        (sw_shown_valid_sync_r),
    .img_sel       (sw_shown_idx_sync_r),
    .rgb_out       (vout_data_emerg),
    .flash_active  ()
);

// ===================== 开机动画：贴纸消防员从正左方走入，走到 PIC1 中消防员的位置 =====================
// 上电后整屏覆盖：先只显示背景约3秒（显示器上电/复位后重新锁定HDMI要1~3秒），首图提交后消防员侧身从左边屏幕外水平走到 PIC1 图中消防员的位置（约3.2秒，每次落脚出脚步声），
// 到位后正面立定约0.27秒（轮廓内即 PIC1 原像素），再交还原画面。PIC1 须为画有该消防员的充电桩图；首图一直不提交就一直停在背景；硬切/缩略图时直接结束。
// 卡上有 BG.BMP 时背景透出该图，到位后由 intro_commit_req 放行，显示bank从背景硬切到 PIC1。
// boot_done 取"首图已提交"（有背景图时 display_valid 在背景显示时就已拉高，不能再用 player_active_sync）。
// 放在紧急闪烁之后、SD卡故障提示图之前：未插卡时故障提示图照旧盖住全屏。
wire [23:0] vout_data_intro;
reg  [1:0]  intro_bg_sync, intro_rdy_sync, first_cm_sync;   // 单比特电平两级同步
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        intro_bg_sync  <= 2'b00;
        intro_rdy_sync <= 2'b00;
        first_cm_sync  <= 2'b00;
    end else begin
        intro_bg_sync  <= {intro_bg_sync[0],  intro_bg_shown_raw};
        intro_rdy_sync <= {intro_rdy_sync[0], intro_pic_ready_raw};
        first_cm_sync  <= {first_cm_sync[0],  first_committed_raw};
    end
end

fireman_intro_24 u_fireman_intro_24 (
    .clk          (video_clk),
    .rst_n        (video_rst_n),
    .vsync        (vs),
    .de           (de),
    .rgb_in       (vout_data_emerg),
    .enable       (subtitle_show),
    .boot_done    (first_cm_sync[1]),
    .bg_shown     (intro_bg_sync[1]),
    .pic_ready    (intro_rdy_sync[1]),
    .rgb_out      (vout_data_intro),
    .intro_active (intro_active),
    .commit_req   (intro_commit_req),
    .step_pulse   (intro_step_pulse),
    .step_side    (intro_step_side),
    .walk_active  (intro_walk_active)
);

// ===================== SD卡故障提示图 =====================
// SD卡持续约1.5秒没有初始化成功（未插卡/卡坏/接触不良）时，整屏显示片上ROM里的
// 提示图，盖住其前所有叠加层；初始化成功后立即撤销。放在链路最末端、AXIS之前。
// sd_ready由sd_card_clk域产生，两级打拍同步到video_clk域；模块内部在帧边界判断。
reg sd_ready_meta, sd_ready_sync_r;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        sd_ready_meta   <= 1'b0;
        sd_ready_sync_r <= 1'b0;
    end else begin
        sd_ready_meta   <= sd_ready_raw;
        sd_ready_sync_r <= sd_ready_meta;
    end
end

sd_fallback_overlay_24 u_sd_fallback_overlay_24 (
    .clk             (video_clk),
    .rst_n           (video_rst_n),
    .vsync           (vs),
    .de              (de),
    .rgb_in          (vout_data_intro),
    .pixel_x         (pixel_x_cnt),
    .sd_ready        (sd_ready_sync_r),
    .rgb_out         (vout_data_fallback),
    .fallback_active ()
);

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (~video_rst_n),
    .I_vs          (vs),
    .I_de          (de),
    .I_rgb         (vout_data_fallback),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (~video_rst_n),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (~video_rst_n),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (~video_rst_n),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
