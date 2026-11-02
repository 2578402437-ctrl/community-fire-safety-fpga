`timescale 1ns/1ps
// 开机动画层 fireman_intro_24（贴纸消防员）逐像素比对测试
// 完整 640×480 有效区，消隐按 800×525 缩短为 HT=660、VT=486。
// 为缩短仿真 STAND_N/WALK_N/ARRIVE_N 由宏传入（默认 4/64/4：站 4 帧、走 64 帧覆盖全部 4 个姿势、到位 4 帧），定点模型用同样参数比对。
// boot_done 在第 BOOT_FROM 次 frame_start 之前拉高（模型从该帧起看到 boot=1）。
// 每帧有效期导出所有像素到 pix.txt（"F 帧号 intro_active" + 每像素一行十六进制）。
// rgb_in = {x[7:0], y[7:0], 8'h55}，动画结束后应直通。
`ifndef STAND
`define STAND 4
`endif
`ifndef WALK
`define WALK 64
`endif
`ifndef ARRIVE
`define ARRIVE 4
`endif
`ifndef BOOT_FROM
`define BOOT_FROM 3
`endif
`ifndef NFRAMES
`define NFRAMES 76
`endif
`ifndef DUMP_MOD
`define DUMP_MOD 4
`endif
module tb;
    localparam integer HT = 660, VACT = 480, VS_LINES = 3, VT = VACT + VS_LINES + 3;
    reg clk = 0, rst_n = 0;
    always #20 clk = ~clk;
    reg [11:0] hcnt = 0, vcnt = 0;
    wire vsync = !(vcnt < VS_LINES);
    wire de = (vcnt >= VS_LINES + 1) && (vcnt < VS_LINES + 1 + VACT) && (hcnt < 640);
    wire [11:0] row = vcnt - (VS_LINES + 1);
    wire [23:0] rgb_in = de ? {hcnt[7:0], row[7:0], 8'h55} : 24'd0;
    reg boot = 0;
    wire [23:0] rgb_out;
    wire act, stp, sts;
    fireman_intro_24 #(
        .ROM_FILE("../../src/user_source/hdl_source/rom/intro_sticker_5bit.hex"),
        .STAND_N(`STAND), .WALK_N(`WALK), .ARRIVE_N(`ARRIVE)
    ) dut (
        .clk(clk), .rst_n(rst_n), .vsync(vsync), .de(de), .rgb_in(rgb_in),
        .enable(1'b1), .boot_done(boot), .bg_shown(1'b0), .pic_ready(1'b0), .commit_req(),   // 无背景图模式
        .rgb_out(rgb_out), .intro_active(act),
        .step_pulse(stp), .step_side(sts));

    integer fo, nfs = 0;
    reg vs_d = 1;
    always @(posedge clk) begin
        if (hcnt == HT - 1) begin
            hcnt <= 0;
            vcnt <= (vcnt == VT - 1) ? 0 : vcnt + 1;
        end else
            hcnt <= hcnt + 1;
    end
    // frame_start 计数（与模块内 vs_q && !vsync 同一拍）
    always @(posedge clk) begin
        vs_d <= vsync;
        if (vs_d && !vsync) begin
            nfs = nfs + 1;
            if (nfs + 1 >= `BOOT_FROM) boot <= 1;   // 在第 BOOT_FROM 次 frame_start 之前拉高
            if (nfs > `NFRAMES) begin
                $fclose(fo);
                $finish;
            end
        end
    end
    // 每帧第一个有效像素时写帧头（此时 intro_active 已是本帧值）
    always @(posedge clk) begin
        // 每 DUMP_MOD 帧导出一帧，最后两帧必导出
        if (de && nfs >= 1 && (nfs % `DUMP_MOD == 0 || nfs >= `NFRAMES - 1)) begin
            if (row == 0 && hcnt == 0)
                $fwrite(fo, "F %0d %0d\n", nfs, act);
            $fwrite(fo, "%06x\n", rgb_out);
        end
    end
    always @(posedge clk)
        if (stp) $display("STEP nfs=%0d side=%0d", nfs, sts);
    initial begin
        fo = $fopen("pix.txt", "w");
        #200 rst_n = 1;
    end
endmodule
