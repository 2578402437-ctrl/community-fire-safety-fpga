`timescale 1ns/1ps
// 双路读回归
// SD侧随机间隔写一整帧到buf1，同时视频持续读：
//   MIX=1：A路读buf0、B路读buf2（内容不同），两路逐像素检查；
//   MIX=0：只读A路（与原tb_wr_rd一致），B路FIFO不得被写入。
// 检查：1) 写入SDRAM的每个字地址/数据正确（含WRITE_V_FLIP）且一个不少
//       2) 读写突发互斥（App_rd_en与App_wr_en不同时有效）
//       3) 两路显示像素正确、读FIFO不下溢
// 宏：+define+MIX=0/1（默认1）、+define+LAT=n SDRAM读延迟拍数（默认6）
`ifndef MIX
`define MIX 1
`endif
`ifndef LAT
`define LAT 6
`endif
module tb_dual_read;
    localparam integer LAT = `LAT;
    reg mem_clk=0, sd_clk=0, video_clk=0, rst=1;
    always #4  mem_clk=~mem_clk;     // 125MHz
    always #5  sd_clk=~sd_clk;       // 100MHz
    always #20 video_clk=~video_clk; // 25MHz

    wire read_req, read_req_ack, hs_0, vs_0, de_0, hs, vs, de, video_read_en;
    wire [31:0] video_read_data, video_read_data_b; wire [23:0] vout_raw, vout_raw_b;
    video_timing_data u_vt (.video_clk(video_clk), .rst(rst), .read_req(read_req),
        .read_req_ack(read_req_ack), .hs(hs_0), .vs(vs_0), .de(de_0));
    video_delay u_vd (.video_clk(video_clk), .rst(rst), .read_en(video_read_en),
        .read_data(video_read_data[31:8]), .hs(hs_0), .vs(vs_0), .de(de_0),
        .hs_r(hs), .vs_r(vs), .de_r(de), .vout_data(vout_raw),
        .read_data_b(video_read_data_b[31:8]), .vout_data_b(vout_raw_b));

    reg wr_req=0, wr_en=0; reg [31:0] wr_data=0; wire wr_ack, wr_fin;
    wire App_rd_en, App_wr_en, Sdr_rd_en; wire [20:0] App_rd_addr, App_wr_addr;
    wire [31:0] App_wr_din, Sdr_rd_dout; wire [3:0] App_wr_dm;
    wire mix_on = (`MIX != 0);
    frame_read_write #(.WRITE_V_FLIP(1), .FRAME_WIDTH(640), .FRAME_HEIGHT(480),
                       .THUMB_HEIGHT(240), .THUMB_STEP(2)) u_frw (
        .mem_clk(mem_clk), .rst(rst), .Sdr_init_done(1'b1), .Sdr_init_ref_vld(1'b0), .Sdr_busy(1'b0),
        .App_rd_en(App_rd_en), .App_rd_addr(App_rd_addr), .Sdr_rd_en(Sdr_rd_en), .Sdr_rd_dout(Sdr_rd_dout),
        .read_clk(video_clk), .read_req(read_req), .read_req_ack(read_req_ack), .read_finish(),
        .read_addr_0(21'd0), .read_addr_1(21'd307200), .read_addr_2(21'd614400), .read_addr_3(21'd921600),
        .read_addr_index(2'd0), .read_len(21'd307200), .read_en(video_read_en),
        .read_data(video_read_data), .read_thumb_mode(1'b0),
        .read_mix_en(mix_on), .read_mix_index(2'd2), .read_en_b(video_read_en & mix_on),
        .read_data_b(video_read_data_b),
        .App_wr_en(App_wr_en), .App_wr_addr(App_wr_addr), .App_wr_din(App_wr_din), .App_wr_dm(App_wr_dm),
        .write_clk(sd_clk), .write_req(wr_req), .write_req_ack(wr_ack), .write_finish(wr_fin),
        .write_addr_0(21'd0), .write_addr_1(21'd307200), .write_addr_2(21'd614400), .write_addr_3(21'd921600),
        .write_addr_index(2'd1), .write_len(21'd307200), .write_en(wr_en), .write_data(wr_data));

    // SDRAM行为模型：读延迟LAT拍
    reg [31:0] mem [0:1228799];
    reg [31:0] lat_d [0:31]; reg [31:0] lat_v; integer i; integer nwr=0, conflict=0, nrd_b=0;
    initial begin
        for (i=0;i<307200;i=i+1) mem[i] = {i[23:0], 8'h00};                         // buf0：A路
        for (i=0;i<307200;i=i+1) mem[614400+i] = {i[23:0] ^ 24'h5A5A5A, 8'h00};     // buf2：B路
    end
    always @(posedge mem_clk) begin
        lat_v <= {lat_v[30:0], App_rd_en};
        lat_d[0] <= mem[App_rd_addr];
        for (i=1;i<32;i=i+1) lat_d[i] <= lat_d[i-1];
        if (App_wr_en) begin mem[App_wr_addr] <= App_wr_din; nwr = nwr + 1; end
        if (App_wr_en && App_rd_en) conflict = conflict + 1;
        if (u_frw.read_fifo_we_b) nrd_b = nrd_b + 1;
    end
    assign Sdr_rd_en = lat_v[LAT-1]; assign Sdr_rd_dout = lat_d[LAT-1];

    integer errors=0, px_err=0, px_err_b=0, underflow=0, underflow_b=0, frames=0, k, r, x;
    reg [9:0] ox, oy; reg vs_q, de_q;
    always @(posedge video_clk) begin
        de_q <= de; vs_q <= vs;
        if (!de) ox <= 0; else ox <= ox + 1;
        if (vs_q & ~vs) begin oy <= 0; frames = frames + 1; end else if (de_q & ~de) oy <= oy + 1;
        if (de && frames >= 1 && vout_raw !== (oy*640+ox)) begin px_err = px_err + 1;
            if (px_err <= 5) $display("A_PIX_ERR (%0d,%0d) got=%h", ox, oy, vout_raw); end
        if (mix_on && de && frames >= 1 && vout_raw_b !== ((oy*640+ox) ^ 24'h5A5A5A)) begin px_err_b = px_err_b + 1;
            if (px_err_b <= 5) $display("B_PIX_ERR (%0d,%0d) got=%h", ox, oy, vout_raw_b); end
        if (video_read_en && u_frw.read_buf.empty_flag && frames >= 1) underflow = underflow + 1;
        if (mix_on && video_read_en && u_frw.read_buf_b.empty_flag && frames >= 1) underflow_b = underflow_b + 1;
    end

    // SD侧写一整帧：请求握手后按随机间隔推数据（平均约每3拍1个）
    integer seed = 7, t_start, t_fin;
    initial begin
        #300 rst = 0;
        wait (frames == 1);
        @(posedge sd_clk) wr_req <= 1; t_start = $time;
        wait (wr_ack); @(posedge sd_clk) wr_req <= 0;
        wait (!wr_ack); repeat (20) @(posedge sd_clk);
        for (k = 0; k < 307200; k = k + 1) begin
            while (($random(seed) & 3) != 0) @(posedge sd_clk);
            wr_en <= 1; wr_data <= {k[23:0] ^ 24'hA5A5A5, 8'h00};
            @(posedge sd_clk); wr_en <= 0;
        end
        wait (wr_fin); t_fin = $time;
        repeat (100) @(posedge mem_clk);
        for (k = 0; k < 307200; k = k + 1) begin
            r = k / 640; x = k % 640;
            if (mem[307200 + (479 - r)*640 + x] !== {k[23:0] ^ 24'hA5A5A5, 8'h00}) begin
                errors = errors + 1; if (errors <= 5) $display("WR_ERR idx%0d", k); end
        end
        wait (frames == 3);
        $display("RESULT MIX=%0d LAT=%0d wr_words=%0d wr_err=%0d rw_overlap=%0d A_pix_err=%0d B_pix_err=%0d A_underflow=%0d B_underflow=%0d B_fifo_writes=%0d wr_time=%0dus",
                 `MIX, LAT, nwr, errors, conflict, px_err, px_err_b, underflow, underflow_b, nrd_b, (t_fin - t_start)/1000);
        if (nwr == 307200 && errors == 0 && conflict == 0 && px_err == 0 && px_err_b == 0 &&
            underflow == 0 && underflow_b == 0 && (mix_on || nrd_b == 0)) $display("RESULT: PASS");
        else $display("RESULT: FAIL");
        $finish;
    end
endmodule
