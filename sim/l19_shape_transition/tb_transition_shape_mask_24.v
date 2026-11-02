`timescale 1ns/1ps
// transition_shape_mask_24 逐像素测试
// params.hex 每行一组 {kind[1:0], in, q[8:0]}（12位）。第f帧中途（第100行）装入第f组参数，
// 模块应在第f+1帧边界锁存、整帧生效；导出第1~N帧每个像素的结果码：
//   0 = 输出为黑（被遮罩）  1 = 输出等于输入（直通）  2 = 其它（错误）
// 输入为不含0的渐变图案 {行号低8位, 列号低8位, A5}，可区分直通与变黑。
module tb;
    parameter integer N = 68;
    localparam integer HT = 680, VACT = 480, VS_LINES = 3, VT = VACT + VS_LINES + 2;
    reg clk = 0, rst_n = 0;
    always #20 clk = ~clk;
    reg [11:0] ptab [0:255];
    reg [11:0] hcnt = 0, vcnt = 0;
    reg [7:0]  frame = 0;
    wire vsync = !(vcnt < VS_LINES);
    wire de = (vcnt >= VS_LINES + 1) && (vcnt < VS_LINES + 1 + VACT) && (hcnt < 640);
    wire [11:0] row = vcnt - (VS_LINES + 1);
    reg [9:0] pixel_x_cnt;
    always @(posedge clk) pixel_x_cnt <= !de ? 10'd0 : pixel_x_cnt + 10'd1;
    wire [23:0] rgb_in = de ? {row[7:0], pixel_x_cnt[7:0], 8'hA5} : 24'd0;
    reg [1:0] kind = 0; reg s_in = 0; reg [8:0] q = 0;
    wire [23:0] rgb_out;
    transition_shape_mask_24 dut (
        .clk(clk), .rst_n(rst_n), .vsync(vsync), .de(de), .rgb_in(rgb_in),
        .pixel_x(pixel_x_cnt), .shape_kind(kind), .shape_in(s_in), .shape_q(q),
        .rgb_out(rgb_out), .mask_active());
    integer fo;
    always @(posedge clk) begin
        if (hcnt == HT-1) begin
            hcnt <= 0;
            if (vcnt == VT-1) begin vcnt <= 0; frame <= frame + 1; end else vcnt <= vcnt + 1;
        end else hcnt <= hcnt + 1;
        if (de && frame >= 1 && frame <= N)
            $fwrite(fo, "%0d", (rgb_out == 24'd0) ? 0 : (rgb_out == rgb_in) ? 1 : 2);
        if (de && pixel_x_cnt == 639 && frame >= 1 && frame <= N)
            $fwrite(fo, "\n");
        // 参数在帧中途（vsync高）改变
        if (hcnt == 5 && vcnt == 100)
            {kind, s_in, q} <= ptab[frame];
    end
    initial begin
        $readmemh("params.hex", ptab);
        fo = $fopen("mask_out.txt");
        #100 rst_n = 1;
        wait (frame == N + 1);
        $fclose(fo);
        $display("TB_DONE N=%0d", N);
        $finish;
    end
endmodule
