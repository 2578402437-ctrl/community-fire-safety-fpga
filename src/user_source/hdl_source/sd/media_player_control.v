// ============================================================================
// 文件名称：media_player_control.v
// 模块名称：media_player_control
// 功能描述：媒体执行层：切图、预加载、转场、自动播放与亮度/音量状态（四层按键架构第四层）
// 目标器件：安路 EG4S20BG256
// ============================================================================
// 媒体播放执行层：接收策略命令，执行具体操作，维护播放状态
// 四层架构第四层：执行层
//
// 功能：
// 1. 维护播放状态（当前图片、缓冲区、自动播放等）
// 2. 接收policy层的命令，执行对应操作
// 3. 生成加载和显示切换请求
// 4. 管理亮度、音量、自动播放等功能参数

module media_player_control #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter integer AUTO_PLAY_MS      = 2500,  // 自动轮播间隔，2.5秒
    parameter integer LOAD_TIMEOUT_MS   = 1000,  // 加载无进展超时：连续这么久没有像素写入/写完确认则重试，1秒
    parameter integer MAX_RETRIES       = 1      // 失败重试次数上限，超过则跳过保留上一帧
)(
    input  wire clk,
    input  wire rst,

    // === 来自 media_policy 的命令（都是1个周期脉冲）===
    input  wire cmd_next_image,         // 下一张
    input  wire cmd_prev_image,         // 上一张
    input  wire cmd_toggle_autoplay,    // 切换自动播放
    input  wire cmd_brightness_enter,   // 进入亮度调节模式
    input  wire cmd_brightness_up,      // 亮度+1

    // === 上电从 Flash 读回的亮度/音量等级（level_flash_store，同clk域）===
    input  wire       cfg_load,           // 读到有效记录，单周期脉冲
    input  wire [3:0] cfg_brightness,
    input  wire [3:0] cfg_volume,

    // === 共享1ms节拍 ===
    input  wire tick_1ms,               // 1ms节拍（单周期脉冲，仅在tick_req期间产生）
    output wire tick_req,               // 自动轮播计时或等待加载完成时为1

    // === 缩略图快速选择（来自thumbnail_controller，同clk域）===
    input  wire        cmd_select_image,  // 快速选择请求（单周期脉冲）
    input  wire [1:0]  select_index,      // 要切到的图片编号
    input  wire        view_mode,         // 1=缩略图模式（此时暂停自动轮播计时）

    // === 拨码开关直显图片（来自sd_card_bmp_v2，已消抖、已按优先级与文件存在性解析）===
    input  wire        sw_sel_valid,      // 1=有开关拨上且对应SW*.BMP存在
    input  wire [1:0]  sw_sel_idx,        // 0=SW1 1=SW2 2=SW3 3=SW12
    output wire        sw_hold,           // 1=拨码模式（或正在退出），屏蔽按键浏览/轮播/缩略图
    output reg         sw_shown_valid,    // 1=显示bank里当前是已加载完成的SW*.BMP（供顶层紧急闪烁门控）
    output reg  [1:0]  sw_shown_idx,      // 当前显示的SW图编号 0=SW1 1=SW2 2=SW3 3=SW12
    output reg         sw_on_screen,      // 1=屏幕上正显示SW图（拨下后重读PIC期间仍为1，切回PIC才清零），供顶层亮度固定最大
    output reg  [1:0]  nav_target_idx,    // 导航栏目标栏目：发起切图请求时即为目标图，放弃加载时退回当前图

    // === 开机动画背景 BG.BMP ===
    // 有 BG.BMP 时：扫描完先把它加载到 BG_BANK 直接显示，再加载 PIC1 但不提交，
    // 等开机动画走到位（intro_commit_req）才切到 PIC1（硬切，不触发转场）。
    input  wire        bg_valid,          // 卡上有 BG.BMP
    input  wire        intro_commit_req,  // 开机动画请求提交首图（已同步到本时钟域）
    output reg         intro_bg_shown,    // 1=显示bank里是BG.BMP（首图提交前）
    output reg         intro_pic_ready,   // 1=PIC1已加载完、等开机动画放行
    output wire        first_committed,   // 1=首张浏览图已提交

    // === 系统状态输入 ===
    input  wire scan_found_valid,       // 扫描到有效BMP文件标志
    input  wire [31:0] scan_found_sector, // 扫描到的BMP文件起始扇区
    input  wire [2:0]  scan_found_total,  // 已找到的BMP文件总数
    input  wire sd_init_done,           // SD卡初始化完成
    input  wire bmp_ready,              // BMP读取模块就绪
    input  wire sdram_ready,            // SDRAM初始化完成（已同步到本时钟域）
    input  wire scan_done,              // 扫描完成标志

    input  wire write_finish_toggle,    // SDRAM写完标志（mem_clk时钟域）
    input  wire bmp_data_wr_en,         // BMP数据写使能（加载看门狗据此判断有进展）
    input  wire [23:0] bmp_data,        // BMP像素数据

    // === BMP内容级错误（来自sd_card_bmp_v2的头校验/像素完整性检查）===
    input  wire        load_error,      // 本次加载内容校验失败（头校验/像素截断），电平在write_finish_pulse那拍有效
    input  wire [7:0]   bmp_error_code,  // 对应的错误码（BMP_ERR_HEADER/BMP_ERR_TRUNCATED）

    // === 转场控制握手（与video_fade_transition，同clk域，直连无需CDC）===
    // 切图流程（不经全黑）：目标图先加载到它自己的bank（旧图照常显示，已加载过的直接跳过），
    // 就绪后发switch_request并给出mix_buf_idx，转场双路合成到整幅新图后switch_grant，此时才提交显示bank。
    // 缩略图模式下选图：目标就绪后直接提交（硬切），延时约100ms再发select_done让缩略图控制器回全屏。
    input  wire        switch_grant,      // 转场合成完成（整幅新图），提交显示bank
    input  wire        fade_busy_in,      // 转场进行中，忽略新的手动切换请求
    output reg         switch_request,    // 切换请求脉冲（新图已就绪，触发转场合成）
    output reg         disp_commit_toggle,// disp_buf_idx每次真正提交时翻转，供跨域生成index_commit
    output reg [1:0]   prev_disp_buf_idx, // 上一次提交前显示的bank号（提交瞬间捕获，保持到下次提交）
    output reg [1:0]   mix_buf_idx,       // 转场B路bank号（=目标图），发请求时更新，之后保持
    output reg         select_done,       // 缩略图选图结束（成功硬切或放弃），单周期脉冲

    // === 自动播放跟随栏目语音（来自sd_card_bmp_v2，同clk域）===
    input  wire        voice_sync_en,     // 1=当前图有栏目语音，自动播放在语音间隔切图（0=按AUTO_PLAY_MS定时）
    input  wire        voice_track_ok,    // 1=正在播放当前图自己的栏目段
    input  wire        voice_gap,         // 1=当前栏目段处在一遍语音播完后的间隔里

    // === 播放状态输出 ===
    output reg [1:0]  write_buf_idx,    // 写入bank编号（=正在加载的图片编号，四bank常驻）
    output reg [1:0]  disp_buf_idx,     // 显示bank编号（=当前显示的图片编号，四bank常驻）
    output reg [1:0]  img_idx,          // 当前显示的图片编号
    output reg [3:0]  brightness_level, // 亮度等级（0~15）
    output reg        brightness_mode,  // 亮度调节模式标志
    output reg [3:0]  volume_level,     // 音量等级（0~15）
    output reg        volume_mode,      // 音量调节模式标志（与brightness_mode互斥）
    output reg        display_valid,    // 显示有效标志
    output reg        auto_play_en,     // 自动播放使能

    // === 加载控制输出 ===
    output reg         scan_start_pulse,  // 扫描开始脉冲
    output reg         load_start_pulse,  // 加载图片开始脉冲
    output reg [31:0]  load_sector,       // 要加载的图片扇区地址

    // === 状态显示 ===
    output reg [3:0]   state_code,       // 数码管状态显示编号

    // === 最终错误码（重试耗尽后保留，成功加载后清零；给OSD/诊断用）===
    output reg [7:0]   last_error_code,

    // === 缩略图状态 ===
    output reg [3:0]   image_complete,    // 每位对应一个常驻bank是否持有已成功加载的图片
    output wire [2:0]  image_count        // 扫描到的图片数（0~4）
);

// === BMP错误码定义（与sd_card_bmp_v2.v保持一致，避开FAT32层已用的0x10/0x20~0x26） ===
// 本模块只产生超时码；头校验/像素截断码由sd_card_bmp_v2通过bmp_error_code传入
localparam [7:0] BMP_ERR_TIMEOUT   = 8'h31;

// === 时间参数计算 ===
// 自动轮播与加载超时以1ms节拍计数
localparam integer AUTO_W = $clog2(AUTO_PLAY_MS);
localparam integer LT_W   = $clog2(LOAD_TIMEOUT_MS);

// === 内部状态寄存器 ===
reg [1:0]  load_idx;              // 当前正在写入的图片编号
reg [2:0]  img_found_count;       // 扫描到的图片总数
assign image_count = img_found_count;
reg [31:0] img_sector0;           // 第0张图片的起始扇区地址
reg [31:0] img_sector1;           // 第1张图片的起始扇区地址
reg [31:0] img_sector2;           // 第2张图片的起始扇区地址
reg [31:0] img_sector3;           // 第3张图片的起始扇区地址
reg        load_busy;             // 图片加载忙标志
reg        source_done_seen;      // 源数据发送完成标志
reg        first_image_committed; // 首张图片已提交标志
reg        scan_kicked;           // 扫描已启动标志

reg [AUTO_W-1:0] auto_cnt;        // 自动播放计时计数器（ms）
reg        voice_gap_seen;        // 自动播放中已到语音间隔、但当时被加载/转场挡住还没切
reg [LT_W-1:0]   load_timeout_cnt; // 加载超时计数器（ms）
reg [1:0]  retry_count;           // 当前这张图已重试次数（内容错误/超时共用）

// === 手动切换转场握手：请求/放行两阶段 ===
reg        switch_pending;        // 切图进行中（从按键到提交或放弃）
reg [1:0]  pending_target_idx;    // 要切到的图片编号
reg        switch_loading;        // 目标图正在预加载
reg        switch_ready;          // 目标图已就绪，下一拍决定转场或硬切
reg        switch_requested;      // 已发switch_request，等待switch_grant
reg        load_preload;          // 本次加载是切图预加载（完成后不直接提交）
reg        load_fill;             // 本次加载是空闲后台预读（完成后只标记bank就绪，不提交、不动导航栏）
reg [3:0]  fill_tried;            // 本轮扫描已后台预读过的bank（失败或被SW图覆盖后不再重读，改为按键时按需加载）
reg        sel_exit_wait;         // 缩略图硬切后等待回全屏
reg [6:0]  sel_exit_cnt;          // 回全屏延时（ms）
localparam integer SEL_EXIT_MS = 100;   // 显示bank切换先跨到mem域生效（约6帧），再退出缩略图

// === 拨码开关直显 ===
// sw_cur_*：最近一次已执行的拨码目标（不论加载成败），与sw_sel不同时才动作，避免失败后反复重试
reg        sw_cur_valid;
reg [1:0]  sw_cur_idx;
reg        load_kind_sw;          // 本次加载是SW*.BMP（1）还是PIC（0）
assign sw_hold = sw_sel_valid || sw_cur_valid;

// === 开机背景 ===
localparam [1:0] BG_BANK = 2'd1;  // BG.BMP 借用 bank1（PIC2 首次加载时覆盖）
reg        bg_tried;              // 本轮扫描已尝试过加载 BG.BMP（失败则直接走原流程）
wire       load_kind_bg = load_sector[3];   // 句柄bit3=1：本次加载是BG.BMP
assign first_committed = first_image_committed;

// 自动轮播计时条件（缩略图/拨码/加载/转场期间暂停）与加载等待条件，两者之一成立时请求1ms节拍
// 加载等待覆盖整个加载过程（含源数据送完后等写完确认），超时计数在每次像素写入时清零
wire auto_run  = auto_play_en && !view_mode && !sw_hold && !load_busy && first_image_committed &&
                 !switch_pending && !fade_busy_in;
wire load_wait = load_busy;
assign tick_req = sd_init_done && (auto_run || load_wait || sel_exit_wait);

// SW图写入的bank：既不是当前显示的bank，也不是浏览中当前图(img_idx)的bank——
// 这样退出拨码模式时img_idx那张图还完好，可以直接切回，不用重新读卡
function [1:0] sw_bank_pick;
    input [1:0] p;
    input [1:0] d;
    begin
        if (p != 2'd0 && d != 2'd0)      sw_bank_pick = 2'd0;
        else if (p != 2'd1 && d != 2'd1) sw_bank_pick = 2'd1;
        else if (p != 2'd2 && d != 2'd2) sw_bank_pick = 2'd2;
        else                             sw_bank_pick = 2'd3;
    end
endfunction

// === 空闲后台预读的候选bank ===
// 条件：在已扫描到的图片范围内、尚未就绪、本轮没预读过、不是当前显示的bank、开机背景显示中不碰BG_BANK
wire [3:0] fill_elig;
genvar gi;
generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_fill_elig
        assign fill_elig[gi] = (gi < img_found_count) && !image_complete[gi] && !fill_tried[gi] &&
                               (disp_buf_idx != gi) && !(intro_bg_shown && (BG_BANK == gi));
    end
endgenerate
// 优先读PIC2（PIC1之后的下一张），再PIC3、PIC4
wire [1:0] fill_pick = fill_elig[1] ? 2'd1 :
                       fill_elig[2] ? 2'd2 :
                       fill_elig[3] ? 2'd3 : 2'd0;

// === 同步 mem_clk 域的 write_finish_toggle（3级触发器链用于跨时钟域）===
reg [2:0]  wrfin_tgl_sync;
wire       write_finish_pulse;

assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];

// === 根据当前图片编号计算下一张 ===
function [1:0] next_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: next_index_limited = 2'd0;
            3'd1: next_index_limited = 2'd0;
            3'd2: next_index_limited = (cur == 2'd1) ? 2'd0 : (cur + 2'd1);
            3'd3: next_index_limited = (cur == 2'd2) ? 2'd0 : (cur + 2'd1);
            default: next_index_limited = (cur == 2'd3) ? 2'd0 : (cur + 2'd1);
        endcase
    end
endfunction

// === 根据当前图片编号计算上一张 ===
function [1:0] prev_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: prev_index_limited = 2'd0;
            3'd1: prev_index_limited = 2'd0;
            3'd2: prev_index_limited = (cur == 2'd0) ? 2'd1 : (cur - 2'd1);
            3'd3: prev_index_limited = (cur == 2'd0) ? 2'd2 : (cur - 2'd1);
            default: prev_index_limited = (cur == 2'd0) ? 2'd3 : (cur - 2'd1);
        endcase
    end
endfunction

// === 根据图片编号查表返回对应的扇区地址 ===
function [31:0] sector_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: sector_lut = img_sector0;
            2'd1: sector_lut = img_sector1;
            2'd2: sector_lut = img_sector2;
            2'd3: sector_lut = img_sector3;
            default: sector_lut = img_sector0;
        endcase
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        // === 清除脉冲输出 ===
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        load_sector <= 32'd0;

        // === 初始化状态 ===
        write_buf_idx <= 2'd0;
        disp_buf_idx <= 2'd0;
        img_idx <= 2'd0;
        load_idx <= 2'd0;
        img_found_count <= 3'd0;
        img_sector0 <= 32'd0;
        img_sector1 <= 32'd0;
        img_sector2 <= 32'd0;
        img_sector3 <= 32'd0;
        load_busy <= 1'b0;
        source_done_seen <= 1'b0;
        first_image_committed <= 1'b0;
        scan_kicked <= 1'b0;
        display_valid <= 1'b0;

        auto_cnt <= {AUTO_W{1'b0}};
        voice_gap_seen <= 1'b0;
        auto_play_en <= 1'b0;
        load_timeout_cnt <= {LT_W{1'b0}};
        retry_count <= 2'd0;
        last_error_code <= 8'h00;
        brightness_level <= 4'd15; // 默认最高档=100%亮度
        brightness_mode <= 1'b0;   // 默认不在亮度调节模式
        volume_level <= 4'd15;     // 默认最高档=原音量
        volume_mode <= 1'b0;
        wrfin_tgl_sync <= 3'b000;
        state_code <= 4'h0;
        switch_pending <= 1'b0;
        pending_target_idx <= 2'd0;
        switch_request <= 1'b0;
        disp_commit_toggle <= 1'b0;
        prev_disp_buf_idx <= 2'd0;
        mix_buf_idx <= 2'd0;
        select_done <= 1'b0;
        switch_loading <= 1'b0;
        switch_ready <= 1'b0;
        switch_requested <= 1'b0;
        load_preload <= 1'b0;
        sel_exit_wait <= 1'b0;
        sel_exit_cnt <= 7'd0;
        sw_cur_valid <= 1'b0;
        sw_cur_idx <= 2'd0;
        load_kind_sw <= 1'b0;
        sw_shown_valid <= 1'b0;
        sw_shown_idx <= 2'd0;
        sw_on_screen <= 1'b0;
        bg_tried <= 1'b0;
        load_fill <= 1'b0;
        fill_tried <= 4'd0;
        intro_bg_shown <= 1'b0;
        intro_pic_ready <= 1'b0;
    end else begin
        // === 清除脉冲输出 ===
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        switch_request <= 1'b0;
        select_done <= 1'b0;

        // === 同步 write_finish_toggle ===
        wrfin_tgl_sync <= {wrfin_tgl_sync[1:0], write_finish_toggle};

        // === 上电恢复掉电前保存的亮度/音量（上电约15ms，早于扫描完成，不与KEY3调节冲突）===
        if (cfg_load) begin
            brightness_level <= cfg_brightness;
            volume_level     <= cfg_volume;
        end

        // === SD未初始化完成，重置所有状态 ===
        if (!sd_init_done) begin
            scan_kicked <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en <= 1'b0;
            auto_cnt <= {AUTO_W{1'b0}};
            img_found_count <= 3'd0;
            img_idx <= 2'd0;
            load_idx <= 2'd0;
            write_buf_idx <= 2'd0;
            disp_buf_idx <= 2'd0;
            img_sector0 <= 32'd0;
            img_sector1 <= 32'd0;
            img_sector2 <= 32'd0;
            img_sector3 <= 32'd0;
            load_busy <= 1'b0;
            source_done_seen <= 1'b0;
            display_valid <= 1'b0;
            load_timeout_cnt <= {LT_W{1'b0}};
            retry_count <= 2'd0;
            last_error_code <= 8'h00;
            sw_cur_valid <= 1'b0;
            sw_shown_valid <= 1'b0;
            sw_on_screen <= 1'b0;
            switch_pending <= 1'b0;   // 切图作废，进行中的转场由其等待提交超时收尾
            switch_loading <= 1'b0;
            switch_ready <= 1'b0;
            switch_requested <= 1'b0;
            load_preload <= 1'b0;
            sel_exit_wait <= 1'b0;
            bg_tried <= 1'b0;
            load_fill <= 1'b0;
            fill_tried <= 4'd0;
            intro_bg_shown <= 1'b0;
            intro_pic_ready <= 1'b0;
        end else begin
            // === 扫描阶段：缓存前4张图的起始扇区 ===
            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= scan_found_sector;
                    3'd1: img_sector1 <= scan_found_sector;
                    3'd2: img_sector2 <= scan_found_sector;
                    3'd3: img_sector3 <= scan_found_sector;
                    default: ;
                endcase

                if (img_found_count < 3'd4)
                    img_found_count <= img_found_count + 3'd1;
            end

            // === 记住源图已经把数据送完FIFO ===
            if (load_busy && bmp_ready)
                source_done_seen <= 1'b1;

            // === 只有真正收到 write_finish_toggle 脉冲，才判定这次加载的结果 ===
            // write_finish_pulse只代表"帧已经写完SDRAM"，不代表内容有效——
            // load_error是sd_card_bmp_v2在同一次加载里对头校验/像素完整性的判定结果，
            // 在write_finish_pulse这一拍已经稳定（下一次streamer_start前不会变），可以直接采样。
            if (load_busy && source_done_seen && write_finish_pulse) begin
                source_done_seen <= 1'b0;
                load_timeout_cnt <= {LT_W{1'b0}};

                if (load_error) begin
                    if (retry_count < MAX_RETRIES) begin
                        // 重试：原地重新加载同一张图，不切换显示，不提交
                        retry_count <= retry_count + 2'd1;
                        load_start_pulse <= 1'b1;
                        // load_sector保持本次加载的句柄不变（PIC或SW图）
                        load_busy <= 1'b1;
                    end else begin
                        // 重试耗尽：放弃这张图，保留上一帧显示不变
                        // 自动模式下auto_cnt计时器会在下一个间隔自然切到下一张；
                        // 手动模式下停在当前画面，等待按键——不在这里主动切换
                        retry_count <= 2'd0;
                        last_error_code <= bmp_error_code;
                        load_busy <= 1'b0;
                        load_fill <= 1'b0;
                        // 切图预加载失败：放弃这次切图，旧图一直在显示，画面不动
                        if (load_preload) begin
                            load_preload   <= 1'b0;
                            switch_loading <= 1'b0;
                            switch_pending <= 1'b0;
                            if (view_mode)
                                select_done <= 1'b1;   // 缩略图选图失败：回全屏（仍是旧图）
                        end
                    end
                end else begin
                    // 内容有效：提交新图并切换显示缓冲区
                    retry_count <= 2'd0;
                    last_error_code <= 8'h00;
                    load_busy <= 1'b0;
                    if (load_kind_sw) begin
                        // 拨码图片硬切——只换显示bank，不触发转场，不改img_idx（退出时据此恢复）
                        disp_buf_idx <= load_idx;
                        display_valid <= 1'b1;
                        sw_shown_valid <= 1'b1;
                        sw_shown_idx <= sw_cur_idx;
                        sw_on_screen <= 1'b1;
                    end else if (load_kind_bg) begin
                        // 开机背景：直接显示，不算首图提交
                        disp_buf_idx <= load_idx;
                        display_valid <= 1'b1;
                        intro_bg_shown <= 1'b1;
                    end else if (load_fill) begin
                        // 空闲后台预读完成：只标记bank就绪（见image_complete），不改显示
                        load_fill <= 1'b0;
                    end else if (intro_bg_shown && !first_image_committed) begin
                        // 背景显示中的 PIC1：先不提交，等开机动画到位放行（见下方"开机背景"段）
                        intro_pic_ready <= 1'b1;
                    end else if (load_preload) begin
                        // 切图预加载完成：不改显示，交给下方"目标就绪"决定转场或硬切
                        load_preload   <= 1'b0;
                        switch_loading <= 1'b0;
                        switch_ready   <= 1'b1;
                    end else begin
                    sw_shown_valid <= 1'b0;
                    sw_on_screen <= 1'b0;
                    if (first_image_committed) begin
                        prev_disp_buf_idx <= disp_buf_idx;   // 提交瞬间捕获旧bank号，直到下次提交前保持不变
                        disp_commit_toggle <= ~disp_commit_toggle;  // 首张图不触发转场
                    end
                    disp_buf_idx <= load_idx;
                    img_idx <= load_idx;
                    display_valid <= 1'b1;
                    first_image_committed <= 1'b1;

                    // === 数码管显示 ===
                    if (brightness_mode || volume_mode)
                        state_code <= 4'hB;  // 0xB = 亮度/音量模式标记
                    else
                        state_code <= {2'b0, load_idx} + 4'd1;  // 显示图片编号（1~4）
                    end
                end
            end else if (brightness_mode) begin
                // === 亮度调节模式：显示亮度等级 ===
                state_code <= brightness_level;
            end else if (volume_mode) begin
                // === 音量调节模式：显示音量等级 ===
                state_code <= volume_level;
            end else if (!load_busy && display_valid && first_image_committed) begin
                // === 正常显示模式：显示当前图片编号（1~4）===
                // 调试提示：如果看到 0xF，说明 cmd_prev_image 在触发
                if (cmd_prev_image)
                    state_code <= 4'hF;  // 调试：显示0xF表示上一张命令触发
                else if (cmd_next_image)
                    state_code <= 4'hE;  // 调试：显示0xE表示下一张命令触发
                else
                    state_code <= {2'b0, img_idx} + 4'd1;
            end

            // === 开机背景：开机动画到位后提交PIC1 ===
            // 不翻转disp_commit_toggle（首图不触发转场），显示bank直接从BG切到PIC1
            if (intro_pic_ready && intro_commit_req) begin
                intro_pic_ready <= 1'b0;
                intro_bg_shown <= 1'b0;
                disp_buf_idx <= 2'd0;
                img_idx <= 2'd0;
                first_image_committed <= 1'b1;
                state_code <= 4'd1;
            end

            // === 上电后自动发起一次"扫描前4张BMP" ===
            // SDRAM未初始化完成前不启动扫描/写入，避免首帧数据丢失
            if (!scan_kicked && bmp_ready && sdram_ready) begin
                scan_start_pulse <= 1'b1;
                scan_kicked <= 1'b1;
                first_image_committed <= 1'b0;
                auto_play_en <= 1'b0;
                auto_cnt <= {AUTO_W{1'b0}};
                img_found_count <= 3'd0;
                img_idx <= 2'd0;
                load_idx <= 2'd0;
                write_buf_idx <= 2'd0;
                disp_buf_idx <= 2'd0;
                display_valid <= 1'b0;
                load_busy <= 1'b0;
                source_done_seen <= 1'b0;
                retry_count <= 2'd0;
                switch_pending <= 1'b0;
                switch_loading <= 1'b0;
                switch_ready <= 1'b0;
                switch_requested <= 1'b0;
                load_preload <= 1'b0;
                sel_exit_wait <= 1'b0;
                bg_tried <= 1'b0;
                load_fill <= 1'b0;
                fill_tried <= 4'd0;
                intro_bg_shown <= 1'b0;
                intro_pic_ready <= 1'b0;
            // === 扫描完成后，自动加载并显示第一张（有BG.BMP时先加载背景，失败则跳过）===
            end else if (scan_done && !first_image_committed && !load_busy && !intro_pic_ready &&
                         img_found_count > 3'd0) begin
                if (bg_valid && !bg_tried) begin
                    bg_tried      <= 1'b1;
                    load_idx      <= BG_BANK;
                    write_buf_idx <= BG_BANK;
                    load_sector   <= 32'd8;          // bit3=1：BG.BMP句柄
                end else begin
                    load_idx      <= 2'd0;
                    write_buf_idx <= 2'd0;
                    load_sector   <= img_sector0;
                end
                load_start_pulse <= 1'b1;
                load_kind_sw <= 1'b0;
                load_preload <= 1'b0;
                load_busy <= 1'b1;
                source_done_seen <= 1'b0;
                load_timeout_cnt <= {LT_W{1'b0}};
                retry_count <= 2'd0;
            end else begin
                // === 处理命令 ===

                // === 拨码开关直显（硬切）===
                // 开关目标与上次执行的目标不同、且没有加载/转场在进行时动作：
                //   拨上 → 把对应SW*.BMP加载到空闲bank，写完直接切显示bank；
                //   全部拨下 → 直接切回浏览中的当前图(img_idx)；该bank若已被覆盖则重新加载。
                if (first_image_committed && scan_done && !load_busy &&
                    !switch_pending && !fade_busy_in &&
                    ((sw_sel_valid != sw_cur_valid) ||
                     (sw_sel_valid && sw_sel_idx != sw_cur_idx))) begin
                    sw_cur_valid <= sw_sel_valid;
                    sw_cur_idx   <= sw_sel_idx;
                    if (sw_sel_valid) begin
                        load_idx         <= sw_bank_pick(img_idx, disp_buf_idx);
                        write_buf_idx    <= sw_bank_pick(img_idx, disp_buf_idx);
                        load_start_pulse <= 1'b1;
                        load_sector      <= {29'd0, 1'b1, sw_sel_idx};   // bit2=1：SW图句柄
                        load_kind_sw     <= 1'b1;
                        load_preload     <= 1'b0;
                        load_busy        <= 1'b1;
                        source_done_seen <= 1'b0;
                        load_timeout_cnt <= {LT_W{1'b0}};
                        retry_count      <= 2'd0;
                    end else if (image_complete[img_idx]) begin
                        disp_buf_idx     <= img_idx;                    // 立即切回，下一帧生效
                        sw_shown_valid   <= 1'b0;
                        sw_on_screen     <= 1'b0;
                    end else begin
                        sw_shown_valid   <= 1'b0;                       // 拨码已全部拨下：重载期间也停止闪烁
                        load_idx         <= img_idx;
                        write_buf_idx    <= img_idx;
                        load_start_pulse <= 1'b1;
                        load_sector      <= sector_lut(img_idx);
                        load_kind_sw     <= 1'b0;
                        load_preload     <= 1'b0;
                        load_busy        <= 1'b1;
                        source_done_seen <= 1'b0;
                        load_timeout_cnt <= {LT_W{1'b0}};
                        retry_count      <= 2'd0;
                    end
                end

                // === 切图第2步：目标图就绪 ===
                // 已在目标bank里（加载过且未被覆盖）就不再读卡，直接就绪；否则先预加载，旧图照常显示
                if (switch_pending && !switch_loading && !switch_ready && !switch_requested &&
                    !sel_exit_wait && !load_busy) begin
                    if (image_complete[pending_target_idx]) begin
                        switch_ready <= 1'b1;
                    end else begin
                        load_idx         <= pending_target_idx;
                        write_buf_idx    <= pending_target_idx;
                        load_start_pulse <= 1'b1;
                        load_sector      <= sector_lut(pending_target_idx);
                        load_kind_sw     <= 1'b0;
                        load_preload     <= 1'b1;
                        load_busy        <= 1'b1;
                        source_done_seen <= 1'b0;
                        load_timeout_cnt <= {LT_W{1'b0}};
                        retry_count      <= 2'd0;
                        switch_loading   <= 1'b1;
                    end
                end

                // === 切图第3步：就绪后，全屏发转场请求；缩略图模式直接硬切 ===
                if (switch_ready) begin
                    switch_ready <= 1'b0;
                    if (view_mode) begin
                        prev_disp_buf_idx <= disp_buf_idx;
                        disp_buf_idx  <= pending_target_idx;
                        img_idx       <= pending_target_idx;
                        sw_shown_valid <= 1'b0;
                        sw_on_screen  <= 1'b0;
                        switch_pending <= 1'b0;
                        sel_exit_wait <= 1'b1;
                        sel_exit_cnt  <= 7'd0;
                        if (!brightness_mode && !volume_mode)
                            state_code <= {2'b0, pending_target_idx} + 4'd1;
                    end else begin
                        mix_buf_idx      <= pending_target_idx;
                        switch_request   <= 1'b1;
                        switch_requested <= 1'b1;
                    end
                end

                // === 切图第4步：合成到整幅新图，提交显示bank（此后A路读新图，B路内容相同）===
                if (switch_grant && switch_requested) begin
                    switch_requested <= 1'b0;
                    switch_pending   <= 1'b0;
                    prev_disp_buf_idx <= disp_buf_idx;
                    disp_buf_idx  <= pending_target_idx;
                    img_idx       <= pending_target_idx;
                    sw_shown_valid <= 1'b0;
                    sw_on_screen  <= 1'b0;
                    disp_commit_toggle <= ~disp_commit_toggle;
                    if (!brightness_mode && !volume_mode)
                        state_code <= {2'b0, pending_target_idx} + 4'd1;
                end

                // === 缩略图硬切后：等显示bank生效再回全屏 ===
                if (sel_exit_wait && tick_1ms) begin
                    if (sel_exit_cnt >= SEL_EXIT_MS - 1) begin
                        sel_exit_wait <= 1'b0;
                        select_done   <= 1'b1;
                    end else begin
                        sel_exit_cnt <= sel_exit_cnt + 7'd1;
                    end
                end

                // === 切图第1步：下一张（登记目标，随后预加载/转场）===
                // 常驻bank下，只有1张图时"下一张"等价于重载当前正在显示的bank，
                // 会在显示的同时被写破坏，因此要求至少2张图（与自动播放的判断条件一致）
                // 开机背景显示期间（首图提交前）不响应切图，避免触发转场
                if (cmd_next_image && !sw_hold && !intro_bg_shown && scan_done && (img_found_count > 3'd1) &&
                    !switch_pending && !fade_busy_in) begin
                    pending_target_idx <= next_index_limited(img_idx, img_found_count);
                    switch_pending <= 1'b1;
                end

                // === 阶段1：上一张 ===
                if (cmd_prev_image && !sw_hold && !intro_bg_shown && scan_done && (img_found_count > 3'd1) &&
                    !switch_pending && !fade_busy_in) begin
                    pending_target_idx <= prev_index_limited(img_idx, img_found_count);
                    switch_pending <= 1'b1;
                end

                // === 缩略图快速选择（阶段1，与next/prev共用转场握手）===
                // 选中的图即使还没加载过也可以选：放行后照常从TF卡加载到对应bank
                if (cmd_select_image && !sw_hold && !intro_bg_shown && scan_done && ({1'b0, select_index} < img_found_count) &&
                    (select_index != img_idx) && !switch_pending && !fade_busy_in) begin
                    pending_target_idx <= select_index;
                    switch_pending <= 1'b1;
                end

                // === 切换自动播放 ===
                if (cmd_toggle_autoplay && !sw_hold && !intro_bg_shown && scan_done && (img_found_count > 3'd1)) begin
                    auto_play_en <= ~auto_play_en;
                    auto_cnt <= {AUTO_W{1'b0}};
                end

                // === KEY3短按循环切换：正常 → 亮度模式 → 音量模式 → 正常 ===
                if (cmd_brightness_enter && scan_done) begin
                    brightness_mode <= !brightness_mode && !volume_mode;
                    volume_mode     <= brightness_mode;
                end

                // === 亮度/音量调节（KEY3长按，policy按当前模式每500ms发一次up）===
                // 0~15循环：到15后再+1回绕到0（4位自然溢出）
                if (cmd_brightness_up && brightness_mode) begin
                    brightness_level <= brightness_level + 4'd1;
                end

                if (cmd_brightness_up && volume_mode) begin
                    volume_level <= volume_level + 4'd1;
                end

                // === 自动播放计时 ===
                // 自动切换与手动next/prev共用同一套切图流程（预加载→双路合成转场→提交）。
                // 缩略图模式下暂停计时（不清零），回到全屏后继续
                // 当前图有栏目语音时不用定时，等这一遍语音播完、进入间隔才切下一张；
                // 间隔到来时若被后台预读/转场等挡住，先记下（voice_gap_seen），放开后立即切。
                // 换图后新段开播前 voice_track_ok=0，记录清掉，新图重新等它自己的第一遍语音。
                if (!auto_play_en || !voice_track_ok)
                    voice_gap_seen <= 1'b0;
                else if (voice_gap)
                    voice_gap_seen <= 1'b1;

                if (auto_run && voice_sync_en) begin
                    auto_cnt <= {AUTO_W{1'b0}};
                    if (voice_track_ok && (voice_gap || voice_gap_seen)) begin
                        pending_target_idx <= next_index_limited(img_idx, img_found_count);
                        switch_pending <= 1'b1;
                        voice_gap_seen <= 1'b0;
                    end
                end else if (auto_run) begin
                    if (!tick_1ms)
                        auto_cnt <= auto_cnt;
                    else if (auto_cnt < (AUTO_PLAY_MS - 1))
                        auto_cnt <= auto_cnt + 1'b1;
                    else begin
                        // 达到自动播放间隔：登记目标（切图第1步）
                        auto_cnt <= {AUTO_W{1'b0}};
                        pending_target_idx <= next_index_limited(img_idx, img_found_count);
                        switch_pending <= 1'b1;
                    end
                end else if (!auto_play_en) begin
                    auto_cnt <= {AUTO_W{1'b0}};
                end

                // === 空闲后台预读：把还没加载过的图依次读进各自的bank ===
                // 旧图照常显示，不提交、不触发转场；之后切到这些图时目标已就绪，按键即开始转场。
                // 开机动画期间（PIC1已就绪等放行）也可预读，但跳过背景占用的BG_BANK；
                // 有切图/拨码/缩略图/转场时不发起，已发起的会先读完再处理切图（切图第2步等!load_busy）。
                if (scan_done && (first_image_committed || intro_pic_ready) && !load_busy &&
                    !switch_pending && !sel_exit_wait && !sw_hold && !view_mode && !fade_busy_in &&
                    (fill_elig != 4'd0)) begin
                    fill_tried[fill_pick] <= 1'b1;
                    load_idx         <= fill_pick;
                    write_buf_idx    <= fill_pick;
                    load_start_pulse <= 1'b1;
                    load_sector      <= sector_lut(fill_pick);
                    load_kind_sw     <= 1'b0;
                    load_preload     <= 1'b0;
                    load_fill        <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    load_timeout_cnt <= {LT_W{1'b0}};
                    retry_count      <= 2'd0;
                end

                // === 加载无进展超时：重试MAX_RETRIES次后放弃，保留上一帧 ===
                // 每次像素写入清零，只有连续LOAD_TIMEOUT_MS没有进展（含写完确认丢失）才判超时
                if (load_wait) begin
                    if (bmp_data_wr_en)
                        load_timeout_cnt <= {LT_W{1'b0}};
                    else if (!tick_1ms)
                        load_timeout_cnt <= load_timeout_cnt;
                    else if (load_timeout_cnt < (LOAD_TIMEOUT_MS - 1))
                        load_timeout_cnt <= load_timeout_cnt + 1'b1;
                    else begin
                        load_timeout_cnt <= {LT_W{1'b0}};
                        if (retry_count < MAX_RETRIES) begin
                            retry_count <= retry_count + 2'd1;
                            load_start_pulse <= 1'b1;
                            // load_sector保持本次加载的句柄不变（PIC或SW图）
                            source_done_seen <= 1'b0;
                        end else begin
                            // 超时重试耗尽：放弃这张图，保留上一帧显示
                            retry_count <= 2'd0;
                            last_error_code <= BMP_ERR_TIMEOUT;
                            load_busy <= 1'b0;
                            source_done_seen <= 1'b0;
                            load_fill <= 1'b0;
                            // 切图预加载超时：放弃这次切图，画面不动
                            if (load_preload) begin
                                load_preload   <= 1'b0;
                                switch_loading <= 1'b0;
                                switch_pending <= 1'b0;
                                if (view_mode)
                                    select_done <= 1'b1;
                            end
                        end
                    end
                end
            end
        end
    end
end

// === 导航栏目标栏目 nav_target_idx ===
// 让消防员小人在转场一开始就朝目标栏目走，而不是等新图提交后才动：
//   - 已发起切图请求、等待转场放行：目标 = pending_target_idx；
//   - 已放行、正在加载浏览图（含重试）：目标 = load_idx；
//   - 其他情况（空闲、拨码SW图加载、重试耗尽放弃）：目标 = 当前显示的img_idx。
// 寄存输出，跨到video_clk域后由导航栏模块按帧做两次一致采样。
always @(posedge clk or posedge rst) begin
    if (rst)
        nav_target_idx <= 2'd0;
    else if (switch_pending)
        nav_target_idx <= pending_target_idx;
    else if (load_busy && !load_kind_sw && !load_kind_bg && !load_fill)
        nav_target_idx <= load_idx;
    else
        nav_target_idx <= img_idx;
end

// === 加载完成标志 image_complete ===
// 本工程四bank常驻、按需加载：bank N 只有在第N张图成功提交过以后才持有有效图像。
//   - 扫描重新开始/SD未就绪：全部清零；
//   - 某bank开始加载（load_busy期间正在被写）：该位清零，避免缩略图显示半张图；
//   - 加载成功提交（与上面"内容有效：提交新图"同一条件）：该位置1；
//   - 重试耗尽/超时放弃：该位保持0（bank内容已被部分覆盖）。
always @(posedge clk or posedge rst) begin
    if (rst)
        image_complete <= 4'd0;
    else if (!sd_init_done || scan_start_pulse)
        image_complete <= 4'd0;
    else if (load_busy && source_done_seen && write_finish_pulse && !load_error)
        image_complete[load_idx] <= !load_kind_sw && !load_kind_bg;   // bank被SW图/开机背景占用后不算作PIC已加载
    else if (load_busy)
        image_complete[load_idx] <= 1'b0;
end

endmodule
