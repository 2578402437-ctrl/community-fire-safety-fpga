`timescale 1ns/1ps
// 导航栏白底范围对照仿真：新模块（BG_Y=34）与参考版本（改名 fireman_nav_bar_24_old）并排
// 期望：第34~51行、第52行及以后与旧版逐像素一致；第0~33行中，旧版输出白底(BG_COLOR)的像素，
// 新版输出原图rgb_in；旧版输出小人颜色的像素，新版完全相同。cur_idx逐帧一致。
// 目标栏目序列覆盖站立、向右走、右边界穿出、向左走（镜像），导出几帧PPM。
module tb_nav_bg;
    localparam H_ACT = 640, H_BLK = 40;
    localparam V_ACT = 60, V_BLK = 4;          // 导航栏在第0~51行，60行足够
    localparam [23:0] WHITE = 24'hFFFFFF;
    localparam SPR = "../../src/user_source/hdl_source/rom/nav_sprite_4bit.hex";
    localparam LAB = "../../src/user_source/hdl_source/rom/nav_label_1bit.hex";

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg vsync = 1, de = 0;
    reg [9:0] pixel_x = 0;
    reg [11:0] cur_y = 0;
    reg enable = 1;
    reg [1:0] target = 0;
    // 原图：避免纯白，便于区分
    wire [23:0] rgb_in = {pixel_x[7:0], cur_y[5:0], 2'b01, 8'h40};
    wire [23:0] rgb_new, rgb_old;
    wire [1:0]  idx_new, idx_old;

    fireman_nav_bar_24 #(.BG_Y(34), .SPRITE_FILE(SPR), .LABEL_FILE(LAB)) dut (
        .clk(clk), .rst_n(rst_n), .vsync(vsync), .de(de), .rgb_in(rgb_in), .pixel_x(pixel_x),
        .enable(enable), .target_idx(target), .rgb_out(rgb_new), .cur_idx(idx_new), .nav_active());
    fireman_nav_bar_24_old #(.SPRITE_FILE(SPR), .LABEL_FILE(LAB)) ref_old (
        .clk(clk), .rst_n(rst_n), .vsync(vsync), .de(de), .rgb_in(rgb_in), .pixel_x(pixel_x),
        .enable(enable), .target_idx(target), .rgb_out(rgb_old), .cur_idx(idx_old), .nav_active());

    integer errors = 0, frames = 0;
    integer x, y, fd, n_bg, n_spr_top;
    task run_frame(input dump, input [8*64-1:0] fname);
        begin
            vsync = 0;
            repeat (H_ACT + H_BLK) @(posedge clk);
            vsync = 1;
            repeat ((H_ACT + H_BLK) * (V_BLK - 1)) @(posedge clk);
            if (dump) begin
                fd = $fopen(fname, "w");
                $fwrite(fd, "P3\n%0d %0d\n255\n", H_ACT, V_ACT);
            end
            n_bg = 0; n_spr_top = 0;
            for (y = 0; y < V_ACT; y = y + 1) begin
                cur_y = y;
                for (x = 0; x < H_ACT; x = x + 1) begin
                    de = 1; pixel_x = x;
                    #1;
                    if (enable && y < 34) begin
                        if (rgb_old === WHITE) begin
                            n_bg = n_bg + 1;
                            if (rgb_new !== rgb_in) begin
                                errors = errors + 1;
                                if (errors < 10) $display("ERR 白底未透出 帧%0d y=%0d x=%0d", frames, y, x);
                            end
                        end else begin
                            n_spr_top = n_spr_top + 1;
                            if (rgb_new !== rgb_old) begin
                                errors = errors + 1;
                                if (errors < 10) $display("ERR 小人像素不同 帧%0d y=%0d x=%0d", frames, y, x);
                            end
                        end
                    end else if (rgb_new !== rgb_old) begin
                        errors = errors + 1;
                        if (errors < 10) $display("ERR 区外不同 帧%0d y=%0d x=%0d", frames, y, x);
                    end
                    if (dump) $fwrite(fd, "%0d %0d %0d\n", rgb_new[23:16], rgb_new[15:8], rgb_new[7:0]);
                    @(posedge clk);
                end
                de = 0; pixel_x = 0;
                repeat (H_BLK) @(posedge clk);
            end
            if (dump) $fclose(fd);
            if (idx_new !== idx_old) begin
                errors = errors + 1;
                $display("ERR 帧%0d cur_idx 新%0d 旧%0d", frames, idx_new, idx_old);
            end
            if (frames % 50 == 0 || dump)
                $display("帧%0d en=%0d target=%0d cur=%0d：顶部透出%0d 顶部小人%0d", frames, enable, target, idx_new, n_bg, n_spr_top);
            frames = frames + 1;
        end
    endtask

    integer k;
    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        for (k = 0; k < 3; k = k + 1) run_frame(k == 2, "f_stand.ppm");        // 站立正面
        target = 1;                                                             // 向右走一格
        for (k = 0; k < 200; k = k + 1) run_frame(k == 60, "f_walk_r.ppm");
        target = 3; for (k = 0; k < 340; k = k + 1) run_frame(0, "");          // 走两格
        target = 0; for (k = 0; k < 180; k = k + 1) run_frame(k == 80, "f_wrap.ppm");  // 右边界穿出
        target = 3; for (k = 0; k < 180; k = k + 1) run_frame(k == 60, "f_walk_l.ppm"); // 向左走（镜像）
        enable = 0; target = 1; for (k = 0; k < 3; k = k + 1) run_frame(0, "");  // 隐藏
        enable = 1; for (k = 0; k < 3; k = k + 1) run_frame(k == 2, "f_back.ppm");
        if (errors == 0) $display("==== ALL PASS（%0d 帧）====", frames);
        else $display("==== %0d FAIL ====", errors);
        $finish;
    end
endmodule
