`timescale 1ns/1ps
// emergency_element_flash_24 逐像素测试：输入SW*.bmp像素，导出亮相/暗相帧与Python模型比对
// 帧序（TOGGLE_FRAMES=2）：帧1进入紧急→亮，帧2亮，帧3暗，帧4暗，帧5亮；
// 帧6换图(sel+1)→亮相重计；帧8 enable=0→原图；帧9 enable毛刺(仅1拍)→应保持原图
module tb;
    parameter integer IMG = 0;
    localparam integer HT = 680, VACT = 480, VS_LINES = 3, VT = VACT + VS_LINES + 2;
    reg clk = 0, rst_n = 0;
    always #20 clk = ~clk;
    reg [23:0] mem [0:640*480-1];
    reg [11:0] hcnt = 0, vcnt = 0;
    reg [7:0]  frame = 0;
    wire vsync = !(vcnt < VS_LINES);
    wire de = (vcnt >= VS_LINES + 1) && (vcnt < VS_LINES + 1 + VACT) && (hcnt < 640);
    wire [11:0] row = vcnt - (VS_LINES + 1);
    reg [9:0] pixel_x_cnt;
    always @(posedge clk) pixel_x_cnt <= !de ? 10'd0 : pixel_x_cnt + 10'd1;
    wire [23:0] rgb_in = de ? mem[row*640 + pixel_x_cnt] : 24'd0;
    reg enable = 0; reg [1:0] sel = IMG;
    wire [23:0] rgb_out;
    emergency_element_flash_24 #(.TOGGLE_FRAMES(2)) dut (
        .clk(clk), .rst_n(rst_n), .vsync(vsync), .de(de), .rgb_in(rgb_in),
        .pixel_x(pixel_x_cnt), .enable(enable), .img_sel(sel), .rgb_out(rgb_out), .flash_active());
    integer fb, fd, f6, f8, f9;
    always @(posedge clk) begin
        if (hcnt == HT-1) begin
            hcnt <= 0;
            if (vcnt == VT-1) begin vcnt <= 0; frame <= frame + 1; end else vcnt <= vcnt + 1;
        end else hcnt <= hcnt + 1;
        if (de) begin
            if (frame == 2) $fwrite(fb, "%06h\n", rgb_out);
            if (frame == 3) $fwrite(fd, "%06h\n", rgb_out);
            if (frame == 6) $fwrite(f6, "%06h\n", rgb_out);
            if (frame == 8) $fwrite(f8, "%06h\n", rgb_out);
            if (frame == 9) $fwrite(f9, "%06h\n", rgb_out);
        end
    end
    // 控制信号在帧中间（vsync高期间）改变，模拟跨域同步后的电平
    always @(posedge clk) if (hcnt == 5 && vcnt == 100) begin
        if (frame == 0) enable <= 1;
        if (frame == 5) sel <= IMG + 1;
        if (frame == 7) enable <= 0;
    end
    // 帧9开始前一拍在vsync下降沿附近给enable一个单拍毛刺，验证"连续两拍一致"过滤
    always @(posedge clk) begin
        if (frame == 8 && vcnt == VT-1 && hcnt == HT-1) enable <= 1;
        else if (frame == 9 && vcnt == 0 && hcnt == 0) enable <= 0;
    end
    initial begin
        $readmemh($sformatf("img%0d.hex", IMG), mem);
        fb = $fopen("out_bright.hex"); fd = $fopen("out_dark.hex"); f6 = $fopen("out_f6.hex");
        f8 = $fopen("out_f8.hex"); f9 = $fopen("out_f9.hex");
        #100 rst_n = 1;
        wait (frame == 10);
        $fclose(fb); $fclose(fd); $fclose(f6); $fclose(f8); $fclose(f9);
        $display("TB_DONE IMG=%0d", IMG);
        $finish;
    end
endmodule
