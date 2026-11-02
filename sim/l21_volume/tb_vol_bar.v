`timescale 1ns/1ps
// 进度条对照仿真：新 brightness_bar_24（带title_sel）与参考版本（改名 brightness_bar_24_old）并排
// 1. title_sel=0：任何使能/等级下与旧版逐像素一致
// 2. title_sel=1：除标题前两字（x=256~319, y=194~225）外与旧版逐像素一致；该区域内文字像素与旧版不同
// 3. 帧中途改 title_sel，本帧不变、下一帧生效
// 4. 导出亮度/音量两帧 PPM 供目视核对
module tb_vol_bar;
    localparam H_ACT = 640, H_BLK = 40;
    localparam V_ACT = 320, V_BLK = 4;        // 面板在184~295行，320行足够

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    reg vsync = 1, de = 0;
    reg [9:0] pixel_x = 0;
    reg [11:0] cur_y = 0;
    reg enable = 0, title = 0;
    reg [3:0] level = 15;
    wire [23:0] rgb_in = {pixel_x[7:0], cur_y[8:1], 8'h60};
    wire [23:0] rgb_new, rgb_old;

    brightness_bar_24 dut (
        .clk(clk), .rst_n(rst_n), .vsync(vsync), .de(de), .rgb_in(rgb_in), .pixel_x(pixel_x),
        .enable(enable), .title_sel(title), .level(level), .rgb_out(rgb_new), .bar_active());
    brightness_bar_24_old ref_old (
        .clk(clk), .rst_n(rst_n), .vsync(vsync), .de(de), .rgb_in(rgb_in), .pixel_x(pixel_x),
        .enable(enable), .level(level), .rgb_out(rgb_old), .bar_active());

    integer errors = 0;
    integer x, y, fd, diff_in, diff_out, chg_y, frames = 0;
    reg chg_title;
    reg in_title2;

    // exp_title：本帧应生效的标题；chg_y行改title（验证帧边界锁存）
    task run_frame(input exp_en, input exp_title, input dump, input [8*64-1:0] fname);
        begin
            vsync = 0;
            repeat (H_ACT + H_BLK) @(posedge clk);
            vsync = 1;
            repeat ((H_ACT + H_BLK) * (V_BLK - 1)) @(posedge clk);
            if (dump) begin
                fd = $fopen(fname, "w");
                $fwrite(fd, "P3\n%0d %0d\n255\n", H_ACT, V_ACT);
            end
            diff_in = 0; diff_out = 0;
            for (y = 0; y < V_ACT; y = y + 1) begin
                cur_y = y;
                if (y == chg_y) title = chg_title;
                for (x = 0; x < H_ACT; x = x + 1) begin
                    de = 1; pixel_x = x;
                    #1;
                    in_title2 = (x >= 256 && x < 320 && y >= 194 && y < 226);
                    if (rgb_new !== rgb_old) begin
                        if (in_title2 && exp_en && exp_title) diff_in = diff_in + 1;
                        else diff_out = diff_out + 1;
                    end
                    if (dump) $fwrite(fd, "%0d %0d %0d\n", rgb_new[23:16], rgb_new[15:8], rgb_new[7:0]);
                    @(posedge clk);
                end
                de = 0; pixel_x = 0;
                repeat (H_BLK) @(posedge clk);
            end
            if (dump) $fclose(fd);
            frames = frames + 1;
            if (diff_out != 0 || ((exp_en && exp_title) != (diff_in != 0))) begin
                errors = errors + 1;
                $display("ERR 帧%0d en=%0d title=%0d lv=%0d：标题区差异=%0d 区外差异=%0d",
                         frames, exp_en, exp_title, level, diff_in, diff_out);
            end else
                $display("帧%0d en=%0d title=%0d lv=%0d：标题区差异=%0d 区外差异=%0d OK",
                         frames, exp_en, exp_title, level, diff_in, diff_out);
        end
    endtask

    integer k;
    initial begin
        chg_y = -1;
        repeat (5) @(posedge clk);
        rst_n = 1;
        run_frame(0, 0, 0, "");                       // 复位后首帧：隐藏
        enable = 1; title = 0;
        run_frame(1, 0, 0, "");                       // 帧前改使能，本帧frame_start即锁存生效
        for (k = 0; k < 16; k = k + 5) begin          // 亮度标题，等级0/5/10/15
            level = k;
            run_frame(1, 0, (k == 10), "frame_bright_lv10.ppm");
        end
        title = 1;
        for (k = 0; k < 16; k = k + 5) begin          // 音量标题
            level = k;
            run_frame(1, 1, (k == 10), "frame_volume_lv10.ppm");
        end
        // 帧中途改标题：本帧仍为音量，下一帧为亮度
        chg_y = 100; chg_title = 0;
        run_frame(1, 1, 0, "");
        chg_y = -1;
        run_frame(1, 0, 0, "");
        // 帧中途改回音量并隐藏
        chg_y = 150; chg_title = 1;
        run_frame(1, 0, 0, "");
        chg_y = -1;
        run_frame(1, 1, 0, "");
        enable = 0;                                   // 帧前改使能：本帧即隐藏
        run_frame(0, 1, 0, "");
        if (errors == 0) $display("==== ALL PASS（%0d 帧）====", frames);
        else $display("==== %0d FAIL ====", errors);
        $finish;
    end
endmodule
