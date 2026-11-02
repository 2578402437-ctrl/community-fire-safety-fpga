`timescale 1ns/1ps
// footstep_synth 逐采样比对：每12800个采样触发一次（左右交替），共3步，
// 每个采样把 foot_out 写入 rtl_out.txt，与 footstep_model.py 的结果比对。
module tb_footstep;
reg clk = 0;
always #20 clk = ~clk;          // 25 MHz
reg rst = 1;
reg tick = 0;
reg trig = 0;
reg side = 0;
wire signed [15:0] foot;

footstep_synth dut (
    .clk(clk), .rst(rst), .sample_tick(tick),
    .trig(trig), .trig_side(side), .foot_out(foot)
);

integer n, fd;
initial begin
    fd = $fopen("rtl_out.txt", "w");
    repeat (4) @(posedge clk);
    rst <= 0;
    for (n = 0; n < 12800 * 3; n = n + 1) begin
        @(posedge clk);
        if (n % 12800 == 0) begin
            trig <= 1; side <= (n / 12800) % 2;
            @(posedge clk);
            trig <= 0;
        end
        tick <= 1;
        @(posedge clk);
        tick <= 0;
        @(posedge clk);     // mul_go
        @(posedge clk);     // foot_out 已更新
        $fdisplay(fd, "%0d", foot);
    end
    $fclose(fd);
    $display("TB_DONE");
    $finish;
end
endmodule
