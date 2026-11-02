// ============================================================================
// 文件名称：footstep_synth.v
// 模块名称：footstep_synth
// 功能描述：脚步声实时合成（白噪声 + 两级低通 + 指数衰减包络）
// 目标器件：安路 EG4S20BG256
// ============================================================================
`timescale 1ns/1ps

// 脚步声实时合成（与导航栏小人的落脚动作逐帧同步）
// 每收到一个落脚脉冲 trig，包络 env 置满并开始指数衰减（每采样减 env>>DECAY_SH 再减1，
// 时间常数约43 ms，一步约144 ms）；声源为16位LFSR白噪声，经两级一阶低通（移位实现，不用乘法），
// 再乘包络得到一声短促的"踏"声。左右脚低通截止频率不同（约1.9 kHz / 950 Hz，小喇叭也能放出），听起来一轻一重。
// 只在48 kHz sample_tick 上更新；包络为0时滤波器清零、乘法器两路输入均为0，待机不翻转。
// 输出比 sample_tick 晚1拍更新（寄存器输出），对采样值无影响。
// 定点算法与 sim/l24_footstep/footstep_model.py 逐位一致，试听文件由该脚本生成。
module footstep_synth #(
    parameter integer DECAY_SH = 11,     // 包络衰减移位
    parameter integer LP_SH_L  = 2,      // 迈前腿帧（左脚）低通移位
    parameter integer LP_SH_R  = 3,      // 迈后腿帧（右脚）低通移位
    parameter integer OUT_SH   = 12      // 输出 = (y2*env)>>>OUT_SH，一步RMS约 -18 dBFS
)(
    input  wire               clk,
    input  wire               rst,           // 高有效复位，与pcm_media_tone保持一致
    input  wire               sample_tick,   // 48 kHz采样节拍
    input  wire               trig,          // 落脚脉冲（同一时钟域，1拍）
    input  wire               trig_side,     // 0=左脚，1=右脚
    output reg  signed [15:0] foot_out       // 16位有符号PCM，无脚步时为0
);

localparam [14:0] ENV_MAX = 15'h7FFF;

reg        [15:0] lfsr;
reg        [14:0] env;
reg        [14:0] env_mul;     // 本采样参与相乘的包络（更新前的值）
reg               side;
reg signed [15:0] y1;
reg signed [15:0] y2;
reg               mul_go;      // sample_tick延迟1拍，更新输出

// 16位Galois LFSR，多项式 x^16+x^14+x^13+x^11+1（0xB400）
wire        [15:0] lfsr_nx = lfsr[0] ? ((lfsr >> 1) ^ 16'hB400) : (lfsr >> 1);
wire signed [15:0] noise   = $signed(lfsr_nx) >>> 1;          // ±16384

// 两级一阶低通：y += (x - y) >>> sh，第二级用第一级本拍的新值
wire signed [16:0] d1    = noise - y1;
wire signed [16:0] d1_sh = side ? (d1 >>> LP_SH_R) : (d1 >>> LP_SH_L);
wire signed [15:0] y1_nx = y1 + d1_sh[15:0];
wire signed [16:0] d2    = y1_nx - y2;
wire signed [16:0] d2_sh = side ? (d2 >>> LP_SH_R) : (d2 >>> LP_SH_L);
wire signed [15:0] y2_nx = y2 + d2_sh[15:0];

// 指数衰减，最小步长1，保证有限时间内归零
wire [14:0] env_dec = (env >> DECAY_SH) + 15'd1;
wire [14:0] env_nx  = (env > env_dec) ? env - env_dec : 15'd0;

// 16位有符号 × 15位无符号，结果右移后饱和到16位
wire signed [31:0] prod    = y2 * $signed({1'b0, env_mul});
wire signed [31:0] prod_sh = prod >>> OUT_SH;
wire        [15:0] prod_sat = (prod_sh >  32'sd32767) ? 16'h7FFF :
                              (prod_sh < -32'sd32768) ? 16'h8000 : prod_sh[15:0];

always @(posedge clk or posedge rst) begin
    if (rst) begin
        lfsr     <= 16'hACE1;
        env      <= 15'd0;
        env_mul  <= 15'd0;
        side     <= 1'b0;
        y1       <= 16'sd0;
        y2       <= 16'sd0;
        mul_go   <= 1'b0;
        foot_out <= 16'sd0;
    end else begin
        mul_go <= sample_tick;
        if (trig) begin
            env  <= ENV_MAX;
            side <= trig_side;
        end else if (sample_tick) begin
            if (env == 15'd0) begin
                y1      <= 16'sd0;
                y2      <= 16'sd0;
                env_mul <= 15'd0;
            end else begin
                lfsr    <= lfsr_nx;
                y1      <= y1_nx;
                y2      <= y2_nx;
                env_mul <= env;
                env     <= env_nx;
            end
        end
        if (mul_go)
            foot_out <= prod_sat;
    end
end

endmodule
