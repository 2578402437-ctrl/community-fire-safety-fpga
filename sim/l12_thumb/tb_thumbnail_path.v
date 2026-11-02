`timescale 1ns/1ps

// 缩略图读通路端到端仿真：
//   video_timing_data → video_delay → thumbnail_view（含thumbnail_layout）
//   frame_read_write（含改过的frame_fifo_read）→ SDRAM行为模型
// SDRAM每个字写入 {bank, 行号, 列号} 编码，逐像素核对显示输出：
//   全屏：像素 = {disp_buf, y, x}
//   缩略图：区域内 = {source_index, local_y*STEP, local_x*STEP}，焦点框=金黄，未加载=深灰，区域外=黑
// TW/TH与顶层THUMB_W/THUMB_H一致（默认320×240铺满全屏）
// 同时检查读FIFO不发生下溢，并在帧中间随机时刻翻转模式，验证帧边界锁存不错帧。
module tb_thumbnail_path;
    localparam TW = 320, TH = 240, STEP = 640 / TW;
    reg mem_clk = 0, video_clk = 0, rst = 1;
    always #4  mem_clk   = ~mem_clk;     // 125MHz
    always #20 video_clk = ~video_clk;   // 25MHz

    // ---------------- 控制量（模拟sd_card_clk域，异步） ----------------
    reg        view_mode_async = 0;
    reg [1:0]  focus_async = 2'd2;
    reg [3:0]  cpl_async = 4'b1011;      // 图2未加载 → 应显示占位色
    reg [1:0]  disp_idx = 2'd1;          // 全屏显示bank1

    // ---------------- 视频时序与延迟 ----------------
    wire read_req, read_req_ack, hs_0, vs_0, de_0;
    wire hs, vs, de, video_read_en, video_read_en_thumb;
    wire [31:0] video_read_data;
    wire [23:0] vout_raw, vout_thumb;
    wire view_mode_frame;

    video_timing_data u_vt (.video_clk(video_clk), .rst(rst), .read_req(read_req),
        .read_req_ack(read_req_ack), .hs(hs_0), .vs(vs_0), .de(de_0));
    video_delay u_vd (.video_clk(video_clk), .rst(rst), .read_en(video_read_en),
        .read_data(video_read_data[31:8]), .hs(hs_0), .vs(vs_0), .de(de_0),
        .hs_r(hs), .vs_r(vs), .de_r(de), .vout_data(vout_raw));

    thumbnail_view #(.THUMB_WIDTH(TW), .THUMB_HEIGHT(TH)) u_tv (.clk(video_clk), .rst_n(~rst), .vs_in(vs_0), .de_in(de_0),
        .view_mode_async(view_mode_async), .focus_async(focus_async),
        .image_complete_async(cpl_async), .read_en_in(video_read_en),
        .read_en_out(video_read_en_thumb), .rgb_in(vout_raw), .rgb_out(vout_thumb),
        .view_mode_frame(view_mode_frame));

    // ---------------- 帧读写 + SDRAM行为模型 ----------------
    wire        App_rd_en, App_wr_en, Sdr_rd_en;
    wire [20:0] App_rd_addr, App_wr_addr;
    wire [31:0] App_wr_din, Sdr_rd_dout;
    wire [3:0]  App_wr_dm;

    frame_read_write #(.WRITE_V_FLIP(1), .FRAME_WIDTH(640), .FRAME_HEIGHT(480),
                       .THUMB_HEIGHT(TH), .THUMB_STEP(STEP)) u_frw (
        .mem_clk(mem_clk), .rst(rst), .Sdr_init_done(1'b1), .Sdr_init_ref_vld(1'b0), .Sdr_busy(1'b0),
        .App_rd_en(App_rd_en), .App_rd_addr(App_rd_addr), .Sdr_rd_en(Sdr_rd_en), .Sdr_rd_dout(Sdr_rd_dout),
        .read_clk(video_clk), .read_req(read_req), .read_req_ack(read_req_ack), .read_finish(),
        .read_addr_0(21'd0), .read_addr_1(21'd307200), .read_addr_2(21'd614400), .read_addr_3(21'd921600),
        .read_addr_index(disp_idx), .read_len(21'd307200), .read_en(video_read_en_thumb),
        .read_data(video_read_data), .read_thumb_mode(view_mode_frame),
        .App_wr_en(App_wr_en), .App_wr_addr(App_wr_addr), .App_wr_din(App_wr_din), .App_wr_dm(App_wr_dm),
        .write_clk(mem_clk), .write_req(1'b0), .write_req_ack(), .write_finish(),
        .write_addr_0(21'd0), .write_addr_1(21'd0), .write_addr_2(21'd0), .write_addr_3(21'd0),
        .write_addr_index(2'd0), .write_len(21'd307200), .write_en(1'b0), .write_data(32'd0));

    // SDRAM：读延迟6拍（frame_fifo_read在最后一个App_rd_en后等10拍，须小于10）
    function [31:0] pix_code;
        input [1:0] b; input [9:0] y; input [9:0] x;
        pix_code = {3'b0, b, y[8:0], x, 8'h00};
    endfunction
    reg [31:0] lat_d [0:5];
    reg [5:0]  lat_v;
    integer i;
    always @(posedge mem_clk) begin
        lat_v <= {lat_v[4:0], App_rd_en};
        lat_d[0] <= pix_code(App_rd_addr / 307200, (App_rd_addr % 307200) / 640, (App_rd_addr % 307200) % 640);
        for (i = 1; i < 6; i = i + 1) lat_d[i] <= lat_d[i-1];
    end
    assign Sdr_rd_en   = lat_v[5];
    assign Sdr_rd_dout = lat_d[5];

    // ---------------- 输出端逐像素核对 ----------------
    reg [11:0] ox, oy; reg de_q, vs_q;
    integer errors = 0, checked = 0, frames = 0, thumb_frames = 0, full_frames = 0;
    reg frame_mode;   // 本帧在输出端应生效的模式（取第0拍锁存值打拍过来）
    reg [23:0] expect_px;
    reg [1:0] sidx; reg [11:0] lx, ly;
    always @(posedge video_clk) begin
        de_q <= de; vs_q <= vs;
        if (!de) ox <= 0; else ox <= ox + 1;
        if (vs_q & ~vs) begin
            oy <= 0;
            frames = frames + 1;
            if (frames > 1) begin
                if (frame_mode) thumb_frames = thumb_frames + 1; else full_frames = full_frames + 1;
            end
            frame_mode = view_mode_frame;   // 输出端第1行开始前，模式早已锁存
        end else if (de_q & ~de) oy <= oy + 1;

        if (de && frames >= 1) begin
            if (!frame_mode) begin
                expect_px = pix_code(disp_idx, oy, ox) >> 8;
            end else begin
                sidx = {oy >= TH, ox >= TW};
                lx = ox % TW; ly = oy % TH;
                if (ox >= 2*TW || oy >= 2*TH)                   expect_px = 24'd0;
                else if (sidx == focus_async && (lx < 2 || ly < 2 || lx >= TW-2 || ly >= TH-2))
                                                                expect_px = 24'hFFD700;
                else if (!cpl_async[sidx])                      expect_px = 24'h303030;
                else                                            expect_px = pix_code(sidx, ly * STEP, lx * STEP) >> 8;
            end
            checked = checked + 1;
            if (vout_thumb !== expect_px) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("像素错误 帧%0d 模式%0d (x=%0d,y=%0d) 实际=%h 期望=%h", frames, frame_mode, ox, oy, vout_thumb, expect_px);
            end
        end
    end

    // ---------------- 读FIFO下溢检查 ----------------
    integer underflow = 0, min_lvl_thumb = 9999;
    always @(posedge video_clk) begin
        if (video_read_en_thumb && u_frw.read_buf.count == 0 && frames >= 1) underflow = underflow + 1;
        // 缩略图帧有效显示期间读FIFO最低水位（带宽余量参考）
        if (frames >= 2 && frame_mode && video_read_en_thumb && u_frw.read_buf.count < min_lvl_thumb)
            min_lvl_thumb = u_frw.read_buf.count;
    end

    initial begin
        #200 rst = 0;
        // 帧1全屏 → 第2帧中间切缩略图 → 第4帧中间切回全屏 → 第5帧中间再切缩略图
        wait (frames == 2); #(5_000_000) view_mode_async = 1;
        wait (frames == 4); #(7_300_000) view_mode_async = 0;
        wait (frames == 5); #(3_100_000) view_mode_async = 1;
        wait (frames == 8);
        $display("核对帧数=%0d（全屏%0d 缩略图%0d） 像素数=%0d 错误=%0d 下溢=%0d 缩略图帧FIFO最低水位=%0d",
                 frames - 1, full_frames, thumb_frames, checked, errors, underflow, min_lvl_thumb);
        if (errors == 0 && underflow == 0 && thumb_frames >= 2 && full_frames >= 2) $display("RESULT: PASS");
        else $display("RESULT: FAIL");
        $finish;
    end
endmodule

// ---------------- 读/写FIFO行为模型（非show-ahead：re后下一拍dout有效） ----------------
module rfifo_32_32_512(input clkr, input clkw, input rst, input we, input re, input [31:0] di,
    output empty_flag, output full_flag, output [8:0] wrusedw, output [8:0] rdusedw, output reg [31:0] dout);
    reg [31:0] mem [0:511];
    integer wp = 0, rp = 0;
    wire [31:0] count = wp - rp;
    assign wrusedw = (count > 511) ? 9'd511 : count[8:0];
    assign rdusedw = wrusedw;
    assign empty_flag = (count == 0);
    assign full_flag = (count >= 512);
    always @(posedge clkw or posedge rst) if (rst) wp = 0; else if (we) begin
        if (count >= 512) $display("FIFO上溢 %t", $time);
        mem[wp % 512] = di; wp = wp + 1; end
    always @(posedge clkr or posedge rst) if (rst) begin rp = 0; dout <= 0; end else if (re) begin
        dout <= mem[rp % 512]; if (count != 0) rp = rp + 1; end
endmodule

module wfifo_32_32_512(input clkr, input clkw, input rst, input we, input re, input [31:0] di,
    output empty_flag, output full_flag, output [8:0] wrusedw, output [8:0] rdusedw, output [31:0] dout);
    assign empty_flag = 1'b1; assign full_flag = 1'b0; assign wrusedw = 0; assign rdusedw = 0; assign dout = 0;
endmodule
