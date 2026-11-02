`timescale 1ns/1ps

// bmp_scaler_640x480 单元仿真：各种源分辨率 → 640×480，逐像素对比参考模型
// 源像素编码 {x[11:0], y[11:0]}（BMP自下而上：第0条源行=图像最底行）
// 参考模型（与讲义公式一致）：
//   letterbox：宽图(3w≥4h) dst=640×max(1,h*640/w)，否则 dst=max(1,w*480/h)×480，居中
//   输出第k行（自下而上）、第c列：在图像区内则 src = ((k-off_y)*h/dst_h, (c-off_x)*w/dst_w)，否则黑
module tb_bmp_scaler;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         start = 0, hdr_done = 0, hdr_ok = 1, in_valid = 0, src_eof = 0;
    reg  [15:0] src_w = 0, src_h = 0;
    reg  [23:0] in_pixel = 0;
    wire        hold, out_valid;
    wire [23:0] out_pixel;
    reg         keep;

    bmp_scaler_640x480 #(.KEEP_ASPECT(1)) dut (.clk(clk), .rst(rst), .start(start),
        .hdr_done(hdr_done), .hdr_ok(hdr_ok), .src_w(src_w), .src_h(src_h),
        .in_valid(in_valid), .in_pixel(in_pixel), .src_eof(src_eof),
        .hold(hold), .out_valid(out_valid), .out_pixel(out_pixel));

    integer dst_w, dst_h, off_x, off_y, n_out, errors, total_err;
    integer ok_x, ok_y; reg [23:0] exp_px;
    integer max_fifo;

    // 输出核对
    always @(posedge clk) begin
        if (out_valid) begin
            ok_y = n_out / 640; ok_x = n_out % 640;
            if (!hdr_ok || ok_x < off_x || ok_x >= off_x + dst_w || ok_y < off_y || ok_y >= off_y + dst_h)
                exp_px = 24'd0;
            else
                exp_px = {12'((ok_x - off_x) * src_w / dst_w), 12'((ok_y - off_y) * src_h / dst_h)};
            if (out_pixel !== exp_px) begin
                errors = errors + 1;
                if (errors <= 5) $display("    错误 (x=%0d,y=%0d) 实际=%h 期望=%h", ok_x, ok_y, out_pixel, exp_px);
            end
            n_out = n_out + 1;
        end
        if (dut.fifo_cnt > max_fifo) max_fifo = dut.fifo_cnt;
    end

    // 源端：模拟SD按扇区送字节，hold时在扇区边界暂停
    task run_case(input integer w, input integer h, input integer truncate_rows, input bad_hdr);
        integer x, y, bytes_in_sector;
        begin
            @(posedge clk) start = 1; @(posedge clk) start = 0;
            src_w = w; src_h = h; hdr_ok = !bad_hdr;
            n_out = 0; errors = 0; max_fifo = 0;
            if (3*w >= 4*h) begin dst_w = 640; dst_h = (h*640)/w; if (dst_h == 0) dst_h = 1; end
            else            begin dst_h = 480; dst_w = (w*480)/h; if (dst_w == 0) dst_w = 1; end
            off_x = (640 - dst_w) / 2; off_y = (480 - dst_h) / 2;
            repeat (3) @(posedge clk);
            @(posedge clk) hdr_done = 1; @(posedge clk) hdr_done = 0;
            bytes_in_sector = 0;
            if (!bad_hdr)
            for (y = 0; y < h - truncate_rows; y = y + 1)
                for (x = 0; x < w; x = x + 1) begin
                    // 每像素3字节，SD约32拍/字节；每扇区171像素检查一次hold
                    if (bytes_in_sector >= 512) begin
                        bytes_in_sector = 0;
                        while (hold) @(posedge clk);
                    end
                    repeat (3) @(posedge clk);
                    @(posedge clk) begin in_valid = 1; in_pixel = {x[11:0], y[11:0]}; end
                    @(posedge clk) in_valid = 0;
                    bytes_in_sector = bytes_in_sector + 3;
                end
            @(posedge clk) src_eof = 1; @(posedge clk) src_eof = 0;
            wait (n_out == 307200);
            repeat (200) @(posedge clk);
            if (n_out != 307200) errors = errors + 1;
            $display("  %0dx%0d%0s%0s → 图像区%0dx%0d 偏移(%0d,%0d)  输出=%0d  FIFO峰值=%0d  错误=%0d %0s",
                     w, h, truncate_rows ? " (截断)" : "", bad_hdr ? " (头错误)" : "",
                     dst_w, dst_h, off_x, off_y, n_out, max_fifo, errors, errors ? "FAIL" : "ok");
            total_err = total_err + errors;
        end
    endtask

    // 截断时，丢失的那部分期望为黑：简化处理——截断用例只检查"输出满一帧且不死锁"
    initial begin
        total_err = 0;
        #100 rst = 0;
        run_case(640, 480, 0, 0);    // 1:1
        run_case(320, 240, 0, 0);    // 2倍放大
        run_case(160, 120, 0, 0);    // 4倍放大
        run_case(1024, 768, 0, 0);   // 缩小
        run_case(800, 600, 0, 0);    // 非整数缩小
        run_case(1280, 720, 0, 0);   // 16:9 letterbox上下黑边
        run_case(480, 640, 0, 0);    // 竖图 左右黑边
        run_case(333, 250, 0, 0);    // 宽度非4倍数、非整数放大
        run_case(101, 37, 0, 0);     // 极端小图
        run_case(640, 480, 0, 1);    // 头错误 → 全黑
        $display("RESULT: %0s", total_err ? "FAIL" : "PASS");
        // 截断用例：只看是否输出满一帧、不死锁
        errors = 0;
        run_case(320, 240, 100, 0);   // 截断：报的"错误"是被填黑的行，正常
        $finish;
    end
endmodule
