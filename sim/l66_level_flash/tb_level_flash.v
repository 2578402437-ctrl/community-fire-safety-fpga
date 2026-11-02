`timescale 1ns/1ps
// level_flash_store + W25Q64 行为模型（只建末扇区 4KB）
// 用例：空片不加载/首次保存、追加保存、复位读回、残缺记录跳过、扇区写满擦除后重写
module tb_level_flash;

reg clk = 0;
always #5 clk = ~clk;
reg rst = 1;

reg  [3:0] bl = 4'd15, vl = 4'd15;   // 模拟执行层等级
wire       cfg_load;
wire [3:0] cfg_b, cfg_v;
wire cs_n, sclk, mosi;
reg  miso = 1'b1;

level_flash_store #(
    .CLK_FREQ_HZ     (1_000_000),   // 1 "ms" = 1000 拍，缩短仿真
    .POWERUP_MS      (10),
    .SAVE_DELAY_MS   (5),
    .BUSY_TIMEOUT_MS (1000)
) dut (
    .clk(clk), .rst(rst),
    .brightness_level(bl), .volume_level(vl),
    .cfg_load(cfg_load), .cfg_brightness(cfg_b), .cfg_volume(cfg_v),
    .flash_cs_n(cs_n), .flash_sclk(sclk), .flash_mosi(mosi), .flash_miso(miso)
);

always @(posedge clk) if (cfg_load) begin bl <= cfg_b; vl <= cfg_v; end

// ---------------- W25Q64 模型 ----------------
reg [7:0]  mem [0:4095];
reg [7:0]  sh_in, cmd, sh_out;
reg [2:0]  bitc;
integer    bytec;
reg [23:0] addr;
reg        wel = 0;
reg        busy = 0;
reg        bad = 0;          // 协议错误
integer    n_erase = 0, n_prog = 0;
integer    i, j;

task flash_fill(input [7:0] v);
    for (j = 0; j < 4096; j = j + 1) mem[j] = v;
endtask

always @(negedge cs_n) begin bitc = 0; bytec = 0; sh_out = 8'hFF; end

always @(posedge cs_n) begin
    if (bytec > 0) begin
        if (cmd == 8'h20) begin
            if (!wel) bad = 1;
            else if (bytec != 4) bad = 1;
            else begin
                if (addr != 24'h7FF000) bad = 1;
                busy = 1; wel = 0; n_erase = n_erase + 1;
                flash_fill(8'hFF);
                #50000 busy = 0;
            end
        end else if (cmd == 8'h02) begin
            if (!wel || bytec < 5) bad = 1;
            else begin
                busy = 1; wel = 0; n_prog = n_prog + 1;
                #3000 busy = 0;
            end
        end else if (cmd == 8'h06) wel = 1;
    end
end

always @(posedge sclk) if (!cs_n) begin
    sh_in = {sh_in[6:0], mosi};
    bitc = bitc + 1;
    if (bitc == 0) begin
        if (bytec == 0) begin
            cmd = sh_in;
            if (busy && cmd != 8'h05) bad = 1;   // 忙时只许读状态
        end else if (bytec <= 3)
            addr = {addr[15:0], sh_in};
        else if (cmd == 8'h02 && wel) begin
            if (addr[23:12] != 12'h7FF) bad = 1;
            mem[addr[11:0]] = mem[addr[11:0]] & sh_in;
            addr[7:0] = addr[7:0] + 1;
        end
        bytec = bytec + 1;
    end
end

// 下降沿出数据
always @(negedge sclk) if (!cs_n) begin
    if (bitc == 0) begin
        if (cmd == 8'h05 && bytec >= 1) sh_out = {7'd0, busy};
        else if (cmd == 8'h03 && bytec >= 4) begin
            sh_out = (addr[23:12] == 12'h7FF) ? mem[addr[11:0]] : 8'hFF;
            addr = addr + 1;
        end else sh_out = 8'hFF;
    end
    #2 miso = sh_out[7 - bitc];
end

// ---------------- 用例 ----------------
integer errs = 0;
integer nload;
always @(posedge clk) if (cfg_load) nload = nload + 1;

task check(input cond, input [8*64-1:0] msg);
    if (!cond) begin errs = errs + 1; $display("FAIL: %0s  t=%0t", msg, $time); end
    else $display("ok  : %0s", msg);
endtask

task do_reset;
    begin
        nload = 0;
        rst = 1; bl = 4'd15; vl = 4'd15;
        repeat (20) @(posedge clk);
        rst = 0;
        wait (dut.state == 4'd5);   // ST_IDLE
        repeat (10) @(posedge clk);
    end
endtask

task wait_idle_after_save;
    begin
        wait (dut.state != 4'd5);
        wait (dut.state == 4'd5);
        repeat (10) @(posedge clk);
    end
endtask

function [31:0] rec_at(input integer k);
    rec_at = {mem[4*k], mem[4*k+1], mem[4*k+2], mem[4*k+3]};
endfunction

initial begin
    flash_fill(8'hFF);

    // 1 空片：不加载，保持默认，不写
    do_reset;
    check(nload == 0 && bl == 15 && vl == 15, "blank: no load, default 15/15");
    #200000;
    check(n_prog == 0, "blank: no write while unchanged");

    // 2 首次调节 → 写记录 0
    bl = 4'd3; vl = 4'd7;
    wait_idle_after_save;
    check(rec_at(0) == 32'hA537C85A, "save#1 -> rec0 = A5 37 C8 5A");

    // 3 连续调节只在停手后写一次
    bl = 4'd4; #20000; bl = 4'd5; #20000; vl = 4'd2;
    wait_idle_after_save;
    check(n_prog == 2 && rec_at(1) == 32'hA552AD5A, "save#2 after still -> rec1 = 52");

    // 4 复位读回
    do_reset;
    check(nload == 1 && bl == 5 && vl == 2, "reload 5/2");
    check(dut.rec_idx == 2, "next idx = 2");
    #200000;
    check(n_prog == 2, "reload: no spurious write");

    // 5 残缺记录（模拟写一半断电）：rec2 = A5 9F FF FF，应跳过、仍读回 5/2、下次写 rec3
    mem[8] = 8'hA5; mem[9] = 8'h9F;
    do_reset;
    check(nload == 1 && bl == 5 && vl == 2, "partial rec skipped, reload 5/2");
    check(dut.rec_idx == 3, "next idx = 3");
    bl = 4'd0;
    wait_idle_after_save;
    $display("rec2=%h rec3=%h rec4=%h nprog=%0d idx=%0d", rec_at(2), rec_at(3), rec_at(4), n_prog, dut.rec_idx);
    check(rec_at(3) == 32'hA502FD5A, "save -> rec3 = 02");

    // 6 写满：1024 条有效记录，最后一条 = 0xC6
    for (i = 0; i < 1024; i = i + 1) begin
        mem[4*i] = 8'hA5; mem[4*i+1] = (i == 1023) ? 8'hC6 : 8'h11;
        mem[4*i+2] = ~mem[4*i+1]; mem[4*i+3] = 8'h5A;
    end
    do_reset;
    check(nload == 1 && bl == 12 && vl == 6, "full sector: reload last 12/6");
    check(dut.rec_idx == 1024, "full: idx = 1024");
    vl = 4'd9;
    i = n_erase;
    wait_idle_after_save;
    check(n_erase == i + 1, "full: erased once");
    $display("rec0=%h rec1=%h nprog=%0d idx=%0d", rec_at(0), rec_at(1), n_prog, dut.rec_idx);
    check(rec_at(0) == 32'hA5C9365A && rec_at(1) == 32'hFFFFFFFF, "after erase: rec0 = C9, rec1 blank");
    do_reset;
    check(nload == 1 && bl == 12 && vl == 9, "reload after erase 12/9");

    check(!bad, "no protocol error");
    if (errs == 0) $display("RESULT: ALL PASS"); else $display("RESULT: %0d FAIL", errs);
    $finish;
end

initial begin #200_000_000; $display("TIMEOUT"); $finish; end
endmodule
