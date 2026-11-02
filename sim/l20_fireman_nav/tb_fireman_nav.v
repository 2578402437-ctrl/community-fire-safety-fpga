`timescale 1ns/1ps
// 消防员导航栏 + 分栏目滚动字幕 联合测试（与顶层同样的串接：导航栏 → 滚动字幕）
// sched.hex 每行一帧 {dump[0], enable[0], target[1:0]}（4位）：第f帧中途（vsync高、第50行）装入第f行，
//   模块在第f+1帧边界采样。dump=1 的帧导出每个有效像素的输出RGB。
// 为缩短仿真，垂直只有 VACT=100 行有效（导航栏0~51行、字幕52~91行都在其中），水平按640有效。
// 每帧在第96行导出两个模块的帧级状态到 state.txt。
module tb;
    parameter integer N = 1400;
    localparam integer HT = 680, VACT = 100, VS_LINES = 3, VT = VACT + VS_LINES + 2;
    reg clk = 0, rst_n = 0;
    always #20 clk = ~clk;
    reg [3:0]  stab [0:4095];
    reg [11:0] hcnt = 0, vcnt = 0;
    reg [11:0] frame = 0;
    wire vsync = !(vcnt < VS_LINES);
    wire de = (vcnt >= VS_LINES + 1) && (vcnt < VS_LINES + 1 + VACT) && (hcnt < 640);
    wire [11:0] row = vcnt - (VS_LINES + 1);
    reg [9:0] pixel_x_cnt;
    always @(posedge clk) pixel_x_cnt <= !de ? 10'd0 : pixel_x_cnt + 10'd1;
    wire [23:0] rgb_in = de ? {row[7:0] ^ 8'h5A, pixel_x_cnt[7:0], {pixel_x_cnt[9:8], row[5:0]}} : 24'd0;
    reg en = 1; reg [1:0] tgt = 0; reg dump = 0;
    wire [23:0] rgb_nav, rgb_out;
    wire [1:0]  cur_idx;
    fireman_nav_bar_24 #(
        .SPRITE_FILE("../../src/user_source/hdl_source/rom/nav_sprite_4bit.hex"),
        .LABEL_FILE ("../../src/user_source/hdl_source/rom/nav_label_1bit.hex")
    ) u_nav (
        .clk(clk), .rst_n(rst_n), .vsync(vsync), .de(de), .rgb_in(rgb_in), .pixel_x(pixel_x_cnt),
        .enable(en), .target_idx(tgt), .rgb_out(rgb_nav), .cur_idx(cur_idx), .nav_active());
    scroll_subtitle_24 #(
        .GLYPH_FILE("../../src/user_source/hdl_source/rom/subtitle_glyph32.hex")
    ) u_sub (
        .clk(clk), .rst_n(rst_n), .vsync(vsync), .de(de), .rgb_in(rgb_nav), .pixel_x(pixel_x_cnt),
        .enable(en), .sentence(cur_idx), .rgb_out(rgb_out), .subtitle_active());
    integer fo, fs;
    reg dump_cur = 0;
    always @(posedge clk) begin
        if (hcnt == HT-1) begin
            hcnt <= 0;
            if (vcnt == VT-1) begin vcnt <= 0; frame <= frame + 1; end else vcnt <= vcnt + 1;
        end else hcnt <= hcnt + 1;
        if (de && frame >= 1 && frame <= N && dump_cur) begin
            $fwrite(fo, "%06x", rgb_out);
            if (pixel_x_cnt == 639) $fwrite(fo, "\n");
        end
        if (hcnt == 0 && vcnt == 2 && frame >= 1 && frame <= N && dump_cur)
            $fwrite(fo, "F %0d\n", frame);
        // 输入在帧中途改变
        if (hcnt == 5 && vcnt == 50) begin
            {dump, en, tgt} <= stab[frame];
        end
        // 本帧是否导出：取上一帧装入的dump位（即sched第frame-1行），在vsync低期间更新
        if (hcnt == 1 && vcnt == 1) dump_cur <= dump;
        if (hcnt == 7 && vcnt == 96 && frame >= 1 && frame <= N)
            $fwrite(fs, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n", frame,
                u_nav.enable_frame, u_nav.tgt_frame, u_nav.pos, u_nav.face_left, u_nav.walking,
                u_nav.step_cnt, u_nav.cur_idx, u_sub.enable_frame, u_sub.sent_frame, u_sub.scroll_pos);
    end
    initial begin
        $readmemh("sched.hex", stab);
        fo = $fopen("pix_out.txt");
        fs = $fopen("state.txt");
        #100 rst_n = 1;
        wait (frame == N + 1);
        $fclose(fo); $fclose(fs);
        $display("TB_DONE N=%0d", N);
        $finish;
    end
endmodule
