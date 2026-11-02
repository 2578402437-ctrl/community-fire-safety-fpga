`timescale 1ns/1ps

// scroll_subtitle_24 仿真
// 1. 隐藏(enable=0)时全帧像素与输入完全一致
// 2. 显示时字幕条外像素不变，条内像素要么是减半的原图、要么是文字色
// 3. 每帧文字左移SCROLL_STEP像素（比较相邻两帧文字首像素位置）
// 4. 导出若干帧顶部64行为PPM，供目视核对字形
module tb_scroll_subtitle;
    localparam H_ACT = 640, H_BLK = 40;
    localparam V_ACT = 64,  V_BLK = 4;     // 只仿真顶部64行，足够覆盖字幕条（第20~59行）
    localparam [23:0] TXT = 24'hFFD200;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    reg vsync = 1, de = 0;
    reg [9:0] pixel_x = 0;
    reg enable = 1;
    wire [23:0] rgb_in = {pixel_x[7:0], 8'h80, 8'h40} | 24'h101010;
    wire [23:0] rgb_out;

    scroll_subtitle_24 #(
        .H_ACTIVE(H_ACT), .BAND_Y(20), .BAND_H(40), .TEXT_Y(24), .SCROLL_STEP(2)
    ) dut (
        .clk(clk), .rst_n(rst_n), .vsync(vsync), .de(de),
        .rgb_in(rgb_in), .pixel_x(pixel_x), .enable(enable),
        .rgb_out(rgb_out), .subtitle_active()
    );

    integer errors = 0;
    integer frame, x, y, fd;
    integer first_text_x, prev_first_x;
    integer text_pixels;
    reg [23:0] exp_band;

    task run_frame(input integer dump, input [8*64-1:0] fname);
        begin
            // 场消隐：vsync低电平脉冲（下降沿=frame_start）
            vsync = 0;
            repeat (H_ACT + H_BLK) @(posedge clk);
            vsync = 1;
            repeat ((H_ACT + H_BLK) * (V_BLK - 1)) @(posedge clk);
            if (dump) begin
                fd = $fopen(fname, "w");
                $fwrite(fd, "P3\n%0d %0d\n255\n", H_ACT, V_ACT);
            end
            first_text_x = -1;
            text_pixels = 0;
            for (y = 0; y < V_ACT; y = y + 1) begin
                for (x = 0; x < H_ACT; x = x + 1) begin
                    de = 1; pixel_x = x;
                    #1;
                    exp_band = {1'b0, rgb_in[23:17], 1'b0, rgb_in[15:9], 1'b0, rgb_in[7:1]};
                    if (!enable || y < 20 || y >= 60) begin
                        if (rgb_out !== rgb_in) begin
                            errors = errors + 1;
                            if (errors < 10) $display("ERR 直通失败 y=%0d x=%0d en=%0d", y, x, enable);
                        end
                    end else if (rgb_out !== exp_band && rgb_out !== TXT) begin
                        errors = errors + 1;
                        if (errors < 10) $display("ERR 条带像素异常 y=%0d x=%0d %h", y, x, rgb_out);
                    end
                    if (enable && rgb_out === TXT) begin
                        text_pixels = text_pixels + 1;
                        if (first_text_x < 0 || x < first_text_x) first_text_x = x;
                    end
                    if (dump) $fwrite(fd, "%0d %0d %0d\n", rgb_out[23:16], rgb_out[15:8], rgb_out[7:0]);
                    @(posedge clk);
                end
                de = 0; pixel_x = 0;
                repeat (H_BLK) @(posedge clk);
            end
            if (dump) $fclose(fd);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;

        // 隐藏模式：使能在下一帧边界才生效，跑2帧后检查
        enable = 0;
        run_frame(0, "");
        run_frame(0, "");
        if (text_pixels != 0) begin errors = errors + 1; $display("ERR 隐藏时仍有文字"); end
        $display("隐藏帧检查完成 errors=%0d", errors);

        // 打开：前若干帧文字仍在屏幕右侧外，快进到文字进入后验证滚动步进
        enable = 1;
        prev_first_x = -1;
        for (frame = 0; frame < 220; frame = frame + 1) begin
            case (frame)
                80:  run_frame(1, "frame_080.ppm");
                200: run_frame(1, "frame_200.ppm");
                default: run_frame(0, "");
            endcase
            // 文字左边沿完全在屏内时（即首像素不是被左边界截断），相邻帧应正好左移2像素
            if (frame >= 160 && frame <= 210 && prev_first_x > 40 && first_text_x >= 0) begin
                if (prev_first_x - first_text_x != 2) begin
                    errors = errors + 1;
                    $display("ERR 帧%0d 滚动步进=%0d", frame, prev_first_x - first_text_x);
                end
            end
            prev_first_x = first_text_x;
        end
        $display("显示帧检查完成 文字像素(末帧)=%0d errors=%0d", text_pixels, errors);

        // 运行中再关闭：下一帧起应完全直通
        enable = 0;
        run_frame(0, "");
        run_frame(0, "");
        if (text_pixels != 0) begin errors = errors + 1; $display("ERR 关闭后仍有文字"); end

        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL errors=%0d", errors);
        $finish;
    end
endmodule
