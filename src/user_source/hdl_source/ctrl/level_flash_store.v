// ============================================================================
// 文件名称：level_flash_store.v
// 模块名称：level_flash_store
// 功能描述：亮度/音量等级掉电保存（板载SPI Flash）
// 目标器件：安路 EG4S20BG256
// ============================================================================
`timescale 1ns/1ps

// 亮度/音量等级掉电保存（板载用户 SPI Flash W25Q64，与存 bit 流的配置 Flash 无关）
// 存储：最后一个 4KB 扇区 SECTOR_ADDR 内按 4 字节记录顺序追加，记录 = {8'hA5, 亮度, 音量, ~{亮度,音量}, 8'h5A}；
//       扇区写满 1024 条才擦除一次、从头再写，擦写寿命 10 万次 × 1024 条，实际用不完。
// 上电：等 POWERUP_MS 后发 0xAB（退出掉电模式），再用 0x03 连续读整扇区，取最后一条校验通过的记录，
//       经 cfg_load 脉冲送执行层；遇到全 FF 的记录即为空位，后面不再读。无有效记录时保持默认等级。
//       写一半断电的残缺记录校验不过，只占一个位置，不影响前面的有效记录。
// 保存：上电读完后，等级与上次保存值不同、且停手 SAVE_DELAY_MS 不再变化时自动写一条（不需要按键）；
//       写入中再调节，写完后照样再等停手重写。等待写完超时则放弃本次，不反复重试。
// SPI 模式 0，SCLK = clk / (2*SPI_HALF)，100 MHz 下为 12.5 MHz（W25Q64 普通读 0x03 上限 50 MHz）。
module level_flash_store #(
    parameter integer CLK_FREQ_HZ   = 100_000_000,
    parameter integer SPI_HALF      = 4,            // SCLK 半周期拍数
    parameter integer POWERUP_MS    = 10,           // 上电等 Flash 就绪（规格 tPUW 最大 10 ms）
    parameter integer SAVE_DELAY_MS = 2000,         // 停手多久后保存
    parameter integer BUSY_TIMEOUT_MS = 1000,       // 等擦除/编程完成的超时（扇区擦除最大 400 ms）
    parameter [23:0]  SECTOR_ADDR   = 24'h7FF000,   // 8 MB 末尾 4KB 扇区
    parameter [7:0]   DEFAULT_LEVEL = 8'hFF         // {亮度,音量} 默认值，与执行层复位值一致（15,15）
)(
    input  wire       clk,
    input  wire       rst,

    input  wire [3:0] brightness_level,   // 执行层当前亮度等级
    input  wire [3:0] volume_level,       // 执行层当前音量等级
    output reg        cfg_load,           // 上电读到有效记录，单周期脉冲
    output reg  [3:0] cfg_brightness,     // 读到的亮度等级（cfg_load 同拍有效）
    output reg  [3:0] cfg_volume,         // 读到的音量等级（cfg_load 同拍有效）

    output reg        flash_cs_n,
    output reg        flash_sclk,
    output reg        flash_mosi,
    input  wire       flash_miso
);

localparam integer MS_CYC  = CLK_FREQ_HZ / 1000;
localparam integer MS_W    = $clog2(MS_CYC);
localparam integer GAP_CYC = 500;                 // 命令之间 CS 拉高 5 us（含 0xAB 后 tRES1 3 us）

// === 1 ms 节拍 ===
reg [MS_W-1:0] ms_cnt;
reg            ms_tick;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        ms_cnt  <= {MS_W{1'b0}};
        ms_tick <= 1'b0;
    end else begin
        ms_tick <= 1'b0;
        if (ms_cnt == MS_CYC - 1) begin
            ms_cnt  <= {MS_W{1'b0}};
            ms_tick <= 1'b1;
        end else
            ms_cnt <= ms_cnt + 1'b1;
    end
end

// === 字节收发：xfer_go 发起，MSB 先出，下降沿出数据、上升沿采样 ===
reg        miso_r;
reg        xfer_go;
reg  [7:0] xfer_tx;
reg        xfer_busy;
reg        xfer_done;
reg  [7:0] xfer_rx;
reg  [7:0] sh_tx;
reg  [2:0] bit_cnt;
reg  [2:0] half_cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        miso_r     <= 1'b1;
        xfer_busy  <= 1'b0;
        xfer_done  <= 1'b0;
        xfer_rx    <= 8'h00;
        sh_tx      <= 8'h00;
        bit_cnt    <= 3'd0;
        half_cnt   <= 3'd0;
        flash_sclk <= 1'b0;
        flash_mosi <= 1'b0;
    end else begin
        miso_r    <= flash_miso;
        xfer_done <= 1'b0;
        if (xfer_go) begin
            xfer_busy  <= 1'b1;
            sh_tx      <= xfer_tx;
            flash_mosi <= xfer_tx[7];
            bit_cnt    <= 3'd0;
            half_cnt   <= 3'd0;
            flash_sclk <= 1'b0;
        end else if (xfer_busy) begin
            if (half_cnt == SPI_HALF - 1) begin
                half_cnt <= 3'd0;
                if (!flash_sclk) begin
                    flash_sclk <= 1'b1;
                    xfer_rx    <= {xfer_rx[6:0], miso_r};
                end else begin
                    flash_sclk <= 1'b0;
                    if (bit_cnt == 3'd7) begin
                        xfer_busy <= 1'b0;
                        xfer_done <= 1'b1;
                    end else begin
                        bit_cnt    <= bit_cnt + 1'b1;
                        sh_tx      <= {sh_tx[6:0], 1'b0};
                        flash_mosi <= sh_tx[6];
                    end
                end
            end else
                half_cnt <= half_cnt + 1'b1;
        end
    end
end

// === 主状态机 ===
localparam [3:0] ST_PWRUP   = 4'd0,
                 ST_RDP     = 4'd1,   // 0xAB 退出掉电
                 ST_READ    = 4'd2,   // 0x03 + 地址，保持 CS 进入扫描
                 ST_SCAN    = 4'd3,   // 逐条读记录
                 ST_LOADED  = 4'd4,
                 ST_IDLE    = 4'd5,
                 ST_E_WREN  = 4'd6,
                 ST_ERASE   = 4'd7,   // 0x20 扇区擦除
                 ST_E_POLL  = 4'd8,
                 ST_P_WREN  = 4'd9,
                 ST_PROG    = 4'd10,  // 0x02 页编程 4 字节
                 ST_P_POLL  = 4'd11,
                 ST_CMD     = 4'd12,  // 发 cmd_buf 前 cmd_len 字节
                 ST_GAP     = 4'd13,  // CS 拉高间隔
                 ST_POLL    = 4'd14;  // 0x05 连续读状态寄存器直到 BUSY=0

reg  [3:0]  state;
reg  [3:0]  ret_state;      // ST_CMD / ST_GAP / ST_POLL 结束后去的状态
reg  [63:0] cmd_buf;
reg  [3:0]  cmd_len;
reg         cmd_keep_cs;    // 1=发完不拉高 CS（读命令后接着收数据）
reg         xf_wait;        // 已发起一个字节，等 xfer_done
reg  [15:0] gap_cnt;
reg  [10:0] wait_ms;        // 上电等待 / 忙等超时计数

reg  [1:0]  rec_byte;       // 扫描：当前记录第几字节
reg  [31:0] rec;
reg  [10:0] rec_idx;        // 下一条可写记录号，1024=扇区已满
reg         ld_ok;
reg  [7:0]  ld_val;
reg         loaded;         // 上电读取完成，可以保存
reg         erasing;        // 1=本次保存先擦扇区，擦完轮询后接着写记录

wire [7:0]  cur_val = {brightness_level, volume_level};
reg  [7:0]  last_val;
reg  [7:0]  saved_val;
reg  [7:0]  wr_val;
reg  [11:0] still_ms;       // 等级保持不变的毫秒数

wire [23:0] rec_addr = SECTOR_ADDR + {11'd0, rec_idx[9:0], 2'b00};
wire [31:0] new_rec  = {8'hA5, wr_val, ~wr_val, 8'h5A};
wire        save_due  = loaded && (cur_val != saved_val) && (cur_val == last_val) &&
                        (still_ms == SAVE_DELAY_MS);

// 停手计时：上电读回完成前保持清零，否则读回那几拍执行层还没换上新值，会把默认值当成新调节写进去
always @(posedge clk or posedge rst) begin
    if (rst) begin
        last_val <= DEFAULT_LEVEL;
        still_ms <= 12'd0;
    end else begin
        last_val <= cur_val;
        if (!loaded || cur_val != last_val)
            still_ms <= 12'd0;
        else if (ms_tick && still_ms != SAVE_DELAY_MS)
            still_ms <= still_ms + 1'b1;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state          <= ST_PWRUP;
        ret_state      <= ST_PWRUP;
        cmd_buf        <= 64'd0;
        cmd_len        <= 4'd0;
        cmd_keep_cs    <= 1'b0;
        xf_wait        <= 1'b0;
        xfer_go        <= 1'b0;
        xfer_tx        <= 8'h00;
        gap_cnt        <= 16'd0;
        wait_ms        <= 11'd0;
        rec_byte       <= 2'd0;
        rec            <= 32'd0;
        rec_idx        <= 11'd0;
        ld_ok          <= 1'b0;
        ld_val         <= DEFAULT_LEVEL;
        loaded         <= 1'b0;
        erasing        <= 1'b0;
        saved_val      <= DEFAULT_LEVEL;
        wr_val         <= DEFAULT_LEVEL;
        cfg_load       <= 1'b0;
        cfg_brightness <= DEFAULT_LEVEL[7:4];
        cfg_volume     <= DEFAULT_LEVEL[3:0];
        flash_cs_n     <= 1'b1;
    end else begin
        xfer_go  <= 1'b0;
        cfg_load <= 1'b0;

        case (state)
        ST_PWRUP: begin
            if (ms_tick) begin
                if (wait_ms == POWERUP_MS - 1) begin
                    wait_ms <= 11'd0;
                    state   <= ST_RDP;
                end else
                    wait_ms <= wait_ms + 1'b1;
            end
        end

        ST_RDP: begin
            cmd_buf     <= {8'hAB, 56'd0};
            cmd_len     <= 4'd1;
            cmd_keep_cs <= 1'b0;
            ret_state   <= ST_READ;
            state       <= ST_CMD;
        end

        ST_READ: begin
            cmd_buf     <= {8'h03, SECTOR_ADDR, 32'd0};
            cmd_len     <= 4'd4;
            cmd_keep_cs <= 1'b1;
            ret_state   <= ST_SCAN;
            rec_idx     <= 11'd0;
            rec_byte    <= 2'd0;
            state       <= ST_CMD;
        end

        ST_SCAN: begin
            if (!xf_wait) begin
                xfer_tx <= 8'h00;
                xfer_go <= 1'b1;
                xf_wait <= 1'b1;
            end else if (xfer_done) begin
                xf_wait  <= 1'b0;
                rec_byte <= rec_byte + 1'b1;
                rec      <= {rec[23:0], xfer_rx};
                if (rec_byte == 2'd3) begin
                    // 一条记录读满：本拍 rec[23:0] 为前 3 字节、xfer_rx 为第 4 字节
                    if ({rec[23:0], xfer_rx} == 32'hFFFF_FFFF) begin
                        flash_cs_n <= 1'b1;
                        gap_cnt    <= 16'd0;
                        ret_state  <= ST_LOADED;
                        state      <= ST_GAP;
                    end else begin
                        if (({rec[23:16], xfer_rx} == {8'hA5, 8'h5A}) && (rec[7:0] == ~rec[15:8])) begin
                            ld_ok  <= 1'b1;
                            ld_val <= rec[15:8];
                        end
                        rec_idx <= rec_idx + 1'b1;
                        if (rec_idx == 11'd1023) begin
                            flash_cs_n <= 1'b1;
                            gap_cnt    <= 16'd0;
                            ret_state  <= ST_LOADED;
                            state      <= ST_GAP;
                        end
                    end
                end
            end
        end

        ST_LOADED: begin
            loaded <= 1'b1;
            if (ld_ok) begin
                cfg_load       <= 1'b1;
                cfg_brightness <= ld_val[7:4];
                cfg_volume     <= ld_val[3:0];
                saved_val      <= ld_val;
            end
            state <= ST_IDLE;
        end

        ST_IDLE: begin
            if (save_due) begin
                wr_val  <= cur_val;
                erasing <= rec_idx[10];
                state   <= rec_idx[10] ? ST_E_WREN : ST_P_WREN;
            end
        end

        ST_E_WREN: begin
            cmd_buf     <= {8'h06, 56'd0};
            cmd_len     <= 4'd1;
            cmd_keep_cs <= 1'b0;
            ret_state   <= ST_ERASE;
            state       <= ST_CMD;
        end

        ST_ERASE: begin
            cmd_buf     <= {8'h20, SECTOR_ADDR, 32'd0};
            cmd_len     <= 4'd4;
            cmd_keep_cs <= 1'b0;
            ret_state   <= ST_E_POLL;
            state       <= ST_CMD;
        end

        ST_E_POLL: begin
            // 擦除完成（或超时）后从记录 0 开始写
            rec_idx     <= 11'd0;
            cmd_buf     <= {8'h05, 56'd0};
            cmd_len     <= 4'd1;
            cmd_keep_cs <= 1'b1;
            ret_state   <= ST_POLL;
            wait_ms     <= 11'd0;
            state       <= ST_CMD;
        end

        ST_P_WREN: begin
            cmd_buf     <= {8'h06, 56'd0};
            cmd_len     <= 4'd1;
            cmd_keep_cs <= 1'b0;
            ret_state   <= ST_PROG;
            state       <= ST_CMD;
        end

        ST_PROG: begin
            cmd_buf     <= {8'h02, rec_addr, new_rec};
            cmd_len     <= 4'd8;
            cmd_keep_cs <= 1'b0;
            ret_state   <= ST_P_POLL;
            state       <= ST_CMD;
        end

        ST_P_POLL: begin
            rec_idx     <= rec_idx + 1'b1;
            saved_val   <= wr_val;   // 写完或超时都记为已保存，失败不反复重写
            cmd_buf     <= {8'h05, 56'd0};
            cmd_len     <= 4'd1;
            cmd_keep_cs <= 1'b1;
            ret_state   <= ST_POLL;
            wait_ms     <= 11'd0;
            state       <= ST_CMD;
        end

        ST_CMD: begin
            flash_cs_n <= 1'b0;
            if (!xf_wait) begin
                if (cmd_len == 4'd0) begin
                    if (cmd_keep_cs)
                        state <= ret_state;
                    else begin
                        flash_cs_n <= 1'b1;
                        gap_cnt    <= 16'd0;
                        state      <= ST_GAP;
                    end
                end else begin
                    xfer_tx <= cmd_buf[63:56];
                    xfer_go <= 1'b1;
                    xf_wait <= 1'b1;
                end
            end else if (xfer_done) begin
                xf_wait <= 1'b0;
                cmd_buf <= {cmd_buf[55:0], 8'h00};
                cmd_len <= cmd_len - 1'b1;
            end
        end

        ST_GAP: begin
            flash_cs_n <= 1'b1;
            if (gap_cnt == GAP_CYC - 1)
                state <= ret_state;
            else
                gap_cnt <= gap_cnt + 1'b1;
        end

        ST_POLL: begin
            // 0x05 已发出，CS 保持低，状态寄存器连续输出；BUSY(bit0)=0 或超时即结束
            if (ms_tick)
                wait_ms <= wait_ms + 1'b1;
            if (!xf_wait) begin
                xfer_tx <= 8'h00;
                xfer_go <= 1'b1;
                xf_wait <= 1'b1;
            end else if (xfer_done) begin
                xf_wait <= 1'b0;
                if (!xfer_rx[0] || wait_ms >= BUSY_TIMEOUT_MS) begin
                    flash_cs_n <= 1'b1;
                    gap_cnt    <= 16'd0;
                    // 擦除轮询结束接着写记录，编程轮询结束回空闲
                    erasing    <= 1'b0;
                    ret_state  <= erasing ? ST_P_WREN : ST_IDLE;
                    state      <= ST_GAP;
                end
            end
        end

        default: state <= ST_IDLE;
        endcase
    end
end

endmodule
