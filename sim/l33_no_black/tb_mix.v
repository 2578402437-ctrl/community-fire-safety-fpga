`timescale 1ns/1ps
// transition_shape_mask_24 双路合成逐像素测试
// params.hex 每行 {act, kind[2:0], q[8:0]}（13位）。第f帧中途装入第f组参数，模块应在第f+1帧边界锁存。
// A = {行号低8位, 列号低8位, A5}，B = {~列号低8位, 行号^列号低8位, 3C}，低字节不同，A/B可区分。
// 输出 mix_out.txt：形状帧每像素一个字符 a/b/x（等于A/等于B/都不是）；
//   kind=0 且 act=1 的淡化帧每像素输出6位十六进制RGB（由Python按公式核对）。
module tb_mix;
    parameter integer N = 70;
    localparam integer HT = 680, VACT = 480, VS_LINES = 3, VT = VACT + VS_LINES + 2;
    reg clk = 0, rst_n = 0;
    always #20 clk = ~clk;
    reg [12:0] ptab [0:255];
    reg [11:0] hcnt = 0, vcnt = 0;
    reg [7:0]  frame = 0;
    wire vsync = !(vcnt < VS_LINES);
    wire de = (vcnt >= VS_LINES + 1) && (vcnt < VS_LINES + 1 + VACT) && (hcnt < 640);
    wire [11:0] row = vcnt - (VS_LINES + 1);
    reg [9:0] pixel_x_cnt;
    always @(posedge clk) pixel_x_cnt <= !de ? 10'd0 : pixel_x_cnt + 10'd1;
    wire [7:0] col8 = pixel_x_cnt[7:0];
    wire [23:0] rgb_a = de ? {row[7:0], col8, 8'hA5} : 24'd0;
    wire [23:0] rgb_b = de ? {~col8, row[7:0] ^ col8, 8'h3C} : 24'd0;
    reg act = 0; reg [2:0] kind = 0; reg [8:0] q = 0;
    reg act_cur = 0; reg [2:0] kind_cur = 0;   // 本帧生效的参数（帧边界跟随模块锁存）
    wire [23:0] rgb_out;
    transition_shape_mask_24 dut (
        .clk(clk), .rst_n(rst_n), .vsync(vsync), .de(de), .rgb_a(rgb_a), .rgb_b(rgb_b),
        .pixel_x(pixel_x_cnt), .mix_active(act), .shape_kind(kind), .shape_in(1'b1), .shape_q(q),
        .rgb_out(rgb_out), .mask_active());
    integer fo;
    always @(posedge clk) begin
        if (hcnt == HT-1) begin
            hcnt <= 0;
            if (vcnt == VT-1) begin vcnt <= 0; frame <= frame + 1; end else vcnt <= vcnt + 1;
        end else hcnt <= hcnt + 1;
        if (de && frame >= 1 && frame <= N) begin
            if (dut.act_f && dut.kind_f == 3'd0)
                $fwrite(fo, "%06h", rgb_out);
            else
                $fwrite(fo, "%s", (rgb_out == rgb_a) ? "a" : (rgb_out == rgb_b) ? "b" : "x");
        end
        if (de && pixel_x_cnt == 639 && frame >= 1 && frame <= N)
            $fwrite(fo, "\n");
        if (hcnt == 5 && vcnt == 100)
            {act, kind, q} <= ptab[frame];
    end
    initial begin
        $readmemh("params.hex", ptab);
        fo = $fopen("mix_out.txt");
        #100 rst_n = 1;
        wait (frame == N + 1);
        $fclose(fo);
        $display("TB_DONE N=%0d", N);
        $finish;
    end
endmodule
