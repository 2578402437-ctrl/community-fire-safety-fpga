// ============================================================================
// 文件名称：wav_stream_player.v
// 模块名称：wav_stream_player
// 功能描述：SD卡PCM音频流式播放器（环形缓冲、起停播回差、下溢指数衰减）
// 目标器件：安路 EG4S20BG256
// ============================================================================
`timescale 1ns/1ps

// TF卡流式WAV（已转码为原始PCM）播放器
//
// 对TF卡里的音频数据做"流式播放"。本模块夹在SD卡扇区读取
// 基础设施（与sd_sector_adapter同一套sector_*接口）和音频采样接口之间，
// 用一块双时钟BRAM环形缓冲吸收TF卡突发读取（~1.2MB/s）和音频消费
// （48kHz×16bit×1ch=96KB/s）之间约12.5:1的速率差。
//
// 架构：
//   TF卡扇区字节流（wr_clk域，字节串行）
//     -> 小端序配对成16位样本 -> 写入BRAM环形缓冲
//   音频采样节拍（rd_clk域，约48kHz）
//     -> 从BRAM读出 -> 输出sample_out/sample_valid
//
// 写侧是按扇区粒度的状态机：缓冲剩余空间够一个扇区时才发起读请求，
// 收满256个样本（512字节）后再判断下一个扇区。读侧按采样率消费。
// 读侧起播/停播带回差：水位达到一个扇区才起播，起播后降到STOP_LEVEL以下才停。
// 缓冲下溢时保持上一采样并逐样本指数衰减到0（sample_valid依然为1），避免硬切爆音。
//
// 设计要点：
//   1. sector_lba直接输出cur_lba，保证请求有效的那一拍地址已稳定。
//   2. 写侧流控：剩余空间不足一个扇区时不发请求，防止覆盖未播放数据。
//   3. 指针为ADDR_WIDTH+1位，区分"满"和"空"。
//   4. 格雷码在各自源时钟域内生成后再跨域，play_enable/结束标志单比特2FF同步。
//   5. 缓冲读写独立成无复位的always块，使TD能推断为BRAM而不是LUT。
//   6. 指针不随play_enable清零（跨域清零无法保证两侧同时生效），
//      循环重播时数据无缝接续。
//   7. 播放途中拉低play_enable可中止当前曲目：WS_REQ态立即回WS_IDLE（请求已被
//      play_enable门控，不会发出）；WS_FILL态必须把当前扇区收完（扇区传输是原子的）
//      再回WS_IDLE。上层看到stream_idle_wr=1后才能换start_lba/total_sectors重新开播。
//      环形缓冲里残留的旧曲目样本（最多约85ms）会先播完，再无缝接上新曲目。
//
// 握手约定：sector_busy为1时不得认为请求已被接收。上层仲裁对非总线
// 主人必须给出sector_busy=1，本模块在WS_REQ里一直等到!sector_busy
// （即请求在这一拍真正被适配器接收）才进入WS_FILL。
//
// 数据格式：原始16位有符号小端序PCM，48kHz单声道。FPGA侧不解析WAV
// 文件头，只需要知道起始LBA和总扇区数。TF卡字节是低字节先到。
module wav_stream_player #(
    parameter integer ADDR_WIDTH         = 12,   // 4096 x 16bit = 8KB环形缓冲，约85ms@48kHz
    parameter integer SAMPLES_PER_SECTOR = 256,  // 512字节/2，同时作为起播水位
    parameter integer STOP_LEVEL         = 32,   // 起播后水位低于此值才停播（回差）
    parameter integer DECAY_SH           = 6     // 下溢衰减：每样本减去1/2^DECAY_SH，约1.3ms时间常数
) (
    // ---------------- 写侧：wr_clk域（SD卡SPI引擎时钟，本工程为sd_card_clk/100MHz） ----------------
    input  wire        wr_clk,
    input  wire        wr_rst_n,
    input  wire        play_enable,        // 电平：播放使能（wr_clk域）
    input  wire [31:0] start_lba,          // 音频数据起始扇区（PC工具转码后的裸PCM起始LBA）
    input  wire [31:0] total_sectors,      // 音频数据总扇区数
    output wire        sector_req,         // 请求读取一个扇区（电平，被接收前保持）
    output wire [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,       // 每个有效脉冲代表1个字节
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,  // 扇区内字节序号0~511（本模块按sector_valid自行配对，未使用此输入）
    input  wire        sector_done,
    input  wire [7:0]  sector_error,
    output wire        stream_end_wr,      // wr_clk域电平：wstate==WS_END。仅供同域（sd_card_bmp_v2内）
                                            // 自动重播逻辑使用，不跨时钟域，不要在其他域直接使用。
    output wire        stream_idle_wr,     // wr_clk域电平：wstate==WS_IDLE，此时可安全切换曲目参数（同上，仅限同域使用）

    // ---------------- 读侧：rd_clk域（音频链时钟，本工程为video_clk/25MHz） ----------------
    input  wire        rd_clk,
    input  wire        rd_rst_n,
    input  wire        sample_tick,        // 约48kHz脉冲：消费一个样本
    output reg  signed [15:0] sample_out,
    output reg         sample_valid,
    input  wire        sample_ready,       // 下游就绪，本工程HDMI音频链无反压，固定接1

    // ---------------- 状态（rd_clk域输出） ----------------
    output reg  [31:0] sample_counter,     // 已消费样本数，供将来OSD显示用
    output wire        stream_active,      // 播放使能、未结束、且缓冲已注满过
    output wire        stream_end,         // 已播放完毕
    output wire        buffer_low          // 剩余不足25%
);
    localparam integer DEPTH = (1 << ADDR_WIDTH);
    localparam integer PW    = ADDR_WIDTH + 1;   // 指针位宽：多1位区分满/空

    // ---------------- 环形缓冲（双时钟简单双口RAM，供TD推断为BRAM） ----------------
    reg [15:0] buffer [0:DEPTH-1];
    reg        buf_we;
    reg [ADDR_WIDTH-1:0] buf_waddr;
    reg [15:0] buf_wdata;
    reg [15:0] buf_rdata;

    reg [PW-1:0] wr_ptr;    // 写指针（wr_clk域）
    reg [PW-1:0] rd_ptr;    // 读指针（rd_clk域）

    always @(posedge wr_clk) begin
        if (buf_we)
            buffer[buf_waddr] <= buf_wdata;
    end

    always @(posedge rd_clk) begin
        buf_rdata <= buffer[rd_ptr[ADDR_WIDTH-1:0]];
    end

    function [PW-1:0] to_gray;
        input [PW-1:0] b;
        begin
            to_gray = b ^ (b >> 1);
        end
    endfunction

    function [PW-1:0] from_gray;
        input [PW-1:0] g;
        reg [PW-1:0] b;
        integer i;
        begin
            b[PW-1] = g[PW-1];
            for (i = PW-2; i >= 0; i = i - 1)
                b[i] = b[i+1] ^ g[i];
            from_gray = b;
        end
    endfunction

    // 格雷码寄存器在各自源时钟域生成，同步链在目的时钟域
    reg [PW-1:0] wr_gray;                        // wr_clk域
    reg [PW-1:0] wr_gray_sync1, wr_gray_sync2;   // rd_clk域
    reg [PW-1:0] rd_gray;                        // rd_clk域
    reg [PW-1:0] rd_gray_sync1, rd_gray_sync2;   // wr_clk域

    wire [PW-1:0] wr_ptr_in_rd = from_gray(wr_gray_sync2);
    reg  [PW-1:0] rd_ptr_in_wr;                  // 写域：读指针解码后寄存一拍

    // 水位：PW位模运算，取值0~DEPTH
    wire [PW-1:0] level_wr = wr_ptr - rd_ptr_in_wr;   // 写域（偏保守：读指针同步有延迟，只会高估水位）
    wire [PW-1:0] level_rd = wr_ptr_in_rd - rd_ptr;   // 读域（偏保守：写指针同步有延迟，只会低估水位）

    // 剩余空间够放下一整个扇区（寄存一拍：只在WS_REQ使用，此时写指针不变、
    // 读指针只增不减，晚一拍只会低估剩余空间，判断偏保守）
    reg space_ok;

    // ---------------- 写侧状态机 ----------------
    localparam [2:0] WS_IDLE  = 3'd0;
    localparam [2:0] WS_REQ   = 3'd1;
    localparam [2:0] WS_FILL  = 3'd2;
    localparam [2:0] WS_END   = 3'd4;
    reg [2:0]  wstate;
    reg [31:0] cur_lba;
    reg [31:0] sectors_read;
    reg [7:0]  lo_byte;             // 小端序配对暂存低字节
    reg        lo_pending;

    // 只有缓冲有空间时才举手要总线，避免空占SD总线影响图片加载；
    // play_enable拉低（中止/换曲）后不再发新请求
    assign sector_req     = (wstate == WS_REQ) && space_ok && play_enable;
    assign sector_lba     = cur_lba;
    assign stream_end_wr  = (wstate == WS_END);
    assign stream_idle_wr = (wstate == WS_IDLE);

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wstate         <= WS_IDLE;
            cur_lba        <= 32'd0;
            sectors_read   <= 32'd0;
            wr_ptr         <= {PW{1'b0}};
            wr_gray        <= {PW{1'b0}};
            lo_pending     <= 1'b0;
            lo_byte        <= 8'd0;
            buf_we         <= 1'b0;
            buf_waddr      <= {ADDR_WIDTH{1'b0}};
            buf_wdata      <= 16'd0;
            rd_gray_sync1  <= {PW{1'b0}};
            rd_gray_sync2  <= {PW{1'b0}};
            rd_ptr_in_wr   <= {PW{1'b0}};
            space_ok       <= 1'b0;
        end else begin
            // 写指针格雷码（本域生成）
            wr_gray       <= to_gray(wr_ptr);
            // 读指针格雷码同步进写域
            rd_gray_sync1 <= rd_gray;
            rd_gray_sync2 <= rd_gray_sync1;
            rd_ptr_in_wr  <= from_gray(rd_gray_sync2);
            space_ok      <= (level_wr <= (DEPTH - SAMPLES_PER_SECTOR));

            buf_we <= 1'b0;

            case (wstate)
            WS_IDLE: begin
                if (play_enable && start_lba != 32'd0 && total_sectors != 32'd0) begin
                    cur_lba      <= start_lba;
                    sectors_read <= 32'd0;
                    lo_pending   <= 1'b0;
                    wstate       <= WS_REQ;
                end
            end
            WS_REQ: begin
                // 中止：请求被play_enable门控，本拍不会发出，可直接回IDLE
                if (!play_enable)
                    wstate <= WS_IDLE;
                // sector_req已在本拍有效且适配器空闲：请求在本拍被接收
                else if (space_ok && !sector_busy)
                    wstate <= WS_FILL;
            end
            WS_FILL: begin
                if (sector_valid) begin
                    if (!lo_pending) begin
                        lo_byte    <= sector_byte;      // 先到的是低字节
                        lo_pending <= 1'b1;
                    end else begin
                        buf_we     <= 1'b1;
                        buf_waddr  <= wr_ptr[ADDR_WIDTH-1:0];
                        buf_wdata  <= {sector_byte, lo_byte};  // 后到的高字节拼成16位
                        wr_ptr     <= wr_ptr + 1'b1;
                        lo_pending <= 1'b0;
                    end
                end
                if (sector_done) begin
                    if (sector_error != 8'd0) begin
                        wstate <= WS_END;           // 扇区读出错：停止播放
                    end else begin
                        sectors_read <= sectors_read + 1'b1;
                        cur_lba      <= cur_lba + 1'b1;
                        if (!play_enable)
                            wstate <= WS_IDLE;      // 中止：当前扇区已收完，回IDLE等待换曲
                        else if (sectors_read + 1'b1 >= total_sectors)
                            wstate <= WS_END;       // 全部读完
                        else
                            wstate <= WS_REQ;       // 读下一个扇区
                    end
                end
            end
            WS_END: begin
                if (!play_enable)
                    wstate <= WS_IDLE;              // 等播放停止才回IDLE
            end
            default: wstate <= WS_IDLE;
            endcase
        end
    end

    // ---------------- 读侧 ----------------
    // play_enable / 结束标志：单比特电平，2FF同步进读域
    reg play_sync1, play_sync2;
    reg end_sync1,  end_sync2;
    // buffer_primed：缓冲区是否已经真正注满过至少一个扇区的有效数据。
    // 只有这个标志为1，stream_active才会去抢audio_source_mux的选源权，
    // 否则WAV抢不到总线时会"假装活跃但只出静音"，把琶音音源顶掉。
    reg buffer_primed;
    // rd_run：已起播（回差状态）。未起播要等水位≥一个扇区，已起播则水位≥STOP_LEVEL就继续读
    reg rd_run;
    wire run_ok = (level_rd >= SAMPLES_PER_SECTOR) || (rd_run && level_rd >= STOP_LEVEL);
    // 下溢衰减：x - x/2^k；|x|很小时x>>>k为0会停在原值，直接归零
    wire signed [15:0] decay_step = sample_out >>> DECAY_SH;
    wire signed [15:0] decay_next = (decay_step == 16'sd0) ? 16'sd0 : (sample_out - decay_step);

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr         <= {PW{1'b0}};
            rd_gray        <= {PW{1'b0}};
            sample_out     <= 16'sd0;
            sample_valid   <= 1'b0;
            sample_counter <= 32'd0;
            wr_gray_sync1  <= {PW{1'b0}};
            wr_gray_sync2  <= {PW{1'b0}};
            play_sync1     <= 1'b0;
            play_sync2     <= 1'b0;
            end_sync1      <= 1'b0;
            end_sync2      <= 1'b0;
            buffer_primed  <= 1'b0;
            rd_run         <= 1'b0;
        end else begin
            // 读指针格雷码（本域生成）
            rd_gray       <= to_gray(rd_ptr);
            // 写指针格雷码同步进读域
            wr_gray_sync1 <= wr_gray;
            wr_gray_sync2 <= wr_gray_sync1;
            play_sync1    <= play_enable;
            play_sync2    <= play_sync1;
            end_sync1     <= stream_end_wr;
            end_sync2     <= end_sync1;

            sample_valid <= 1'b0;

            if (sample_tick && sample_ready) begin
                if (run_ok || (end_sync2 && level_rd != 0)) begin
                    // 缓冲足够（含回差），或播放已结束但还有残余样本：正常播放（排空残余）
                    sample_out     <= buf_rdata;
                    rd_ptr         <= rd_ptr + 1'b1;
                    sample_valid   <= 1'b1;
                    sample_counter <= sample_counter + 1'b1;
                end else begin
                    // 预填充阶段或下溢：保持上一采样并衰减，不消费读指针
                    sample_out   <= decay_next;
                    sample_valid <= 1'b1;   // valid仍然断言，下游不会因为没数据而停顿
                end
            end

            rd_run <= play_sync2 && run_ok;

            if (!play_sync2) begin
                sample_counter <= 32'd0;
                buffer_primed  <= 1'b0;   // 下一轮播放要重新注满一次才算"活跃"
            end else if (level_rd >= SAMPLES_PER_SECTOR) begin
                buffer_primed <= 1'b1;
            end
        end
    end

    // stream_active：播放使能打开、还没播完、且缓冲区已经真正注满过数据。
    assign stream_active = play_sync2 && !end_sync2 && buffer_primed;
    assign stream_end    = end_sync2;
    assign buffer_low    = (level_rd < (DEPTH >> 2)); // < 25%

endmodule
