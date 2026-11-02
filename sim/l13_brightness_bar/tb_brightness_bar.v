`timescale 1ns/1ps

// KEY3亮度进度条 brightness_bar_24 仿真
// 1. 隐藏(enable=0)时全帧像素与输入完全一致
// 2. 显示时面板外像素不变；进度条中间行点亮像素=(等级+1)*18，未点亮=(15-等级)*18
// 3. 帧中途改等级/使能，本帧不变、下一帧才生效（帧边界锁存）
// 4. 导出等级0/7/15三帧为PPM，供目视核对
module tb_brightness_bar;
    localparam H_ACT = 640, H_BLK = 40;
    localparam V_ACT = 480, V_BLK = 4;
    localparam [23:0] ON = 24'hFFD200, OFF = 24'h404040;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    reg vsync = 1, de = 0;
    reg [9:0] pixel_x = 0;
    reg [11:0] cur_y = 0;
    reg enable = 0;
    reg [3:0] level = 15;
    wire [23:0] rgb_in = {pixel_x[7:0], cur_y[8:1], 8'h60};
    wire [23:0] rgb_out;

    brightness_bar_24 dut (
        .clk(clk), .rst_n(rst_n), .vsync(vsync), .de(de),
        .rgb_in(rgb_in), .pixel_x(pixel_x), .enable(enable), .level(level),
        .rgb_out(rgb_out), .bar_active()
    );

    integer errors = 0;
    integer x, y, fd, on_px, off_px, chg_y;
    reg [3:0] chg_level; reg chg_en;
    reg in_panel;

    // exp_en/exp_lv：本帧应生效的使能与等级；chg_*：帧中途(第chg_y行)改输入，用于验证锁存
    task run_frame(input exp_en, input [3:0] exp_lv, input dump, input [8*64-1:0] fname);
        begin
            vsync = 0;
            repeat (H_ACT + H_BLK) @(posedge clk);
            vsync = 1;
            repeat ((H_ACT + H_BLK) * (V_BLK - 1)) @(posedge clk);
            if (dump) begin
                fd = $fopen(fname, "w");
                $fwrite(fd, "P3\n%0d %0d\n255\n", H_ACT, V_ACT);
            end
            on_px = 0; off_px = 0;
            for (y = 0; y < V_ACT; y = y + 1) begin
                cur_y = y;
                if (y == chg_y) begin enable = chg_en; level = chg_level; end
                for (x = 0; x < H_ACT; x = x + 1) begin
                    de = 1; pixel_x = x;
                    #1;
                    in_panel = (x >= 140 && x < 500 && y >= 184 && y < 296);
                    if ((!exp_en || !in_panel) && rgb_out !== rgb_in) begin
                        errors = errors + 1;
                        if (errors < 10) $display("ERR 直通失败 y=%0d x=%0d", y, x);
                    end
                    if (y == 256) begin   // 进度条中间行
                        if (rgb_out === ON)  on_px  = on_px + 1;
                        if (rgb_out === OFF) off_px = off_px + 1;
                    end
                    if (dump) $fwrite(fd, "%0d %0d %0d\n", rgb_out[23:16], rgb_out[15:8], rgb_out[7:0]);
                    @(posedge clk);
                end
                de = 0; pixel_x = 0;
                repeat (H_BLK) @(posedge clk);
            end
            if (dump) $fclose(fd);
            if (exp_en && (on_px != (exp_lv + 1) * 18 || off_px != (15 - exp_lv) * 18)) begin
                errors = errors + 1;
                $display("ERR 等级%0d 点亮=%0d 未点亮=%0d", exp_lv, on_px, off_px);
            end
            $display("帧 en=%0d lv=%0d：进度条点亮像素=%0d 未点亮=%0d", exp_en, exp_lv, on_px, off_px);
        end
    endtask

    initial begin
        chg_y = -1;
        repeat (5) @(posedge clk);
        rst_n = 1;
        run_frame(0, 15, 0, "");                       // 复位后未使能：全直通
        enable = 1; level = 0;
        run_frame(1, 0, 1, "lv00.ppm");
        level = 7;
        run_frame(1, 7, 1, "lv07.ppm");
        level = 15;
        run_frame(1, 15, 1, "lv15.ppm");
        // 帧中途(第200行，面板内)改等级为3：本帧仍是15，下一帧才是3
        chg_y = 200; chg_en = 1; chg_level = 3;
        run_frame(1, 15, 0, "");
        chg_y = -1;
        run_frame(1, 3, 0, "");
        // 帧中途关闭：本帧仍显示，下一帧全直通
        chg_y = 200; chg_en = 0; chg_level = 3;
        run_frame(1, 3, 0, "");
        chg_y = -1;
        run_frame(0, 3, 0, "");
        if (errors == 0) $display("==== ALL PASS ===="); else $display("==== %0d ERRORS ====", errors);
        $finish;
    end
endmodule
