// ============================================================================
// 文件名称：audio_arc_calculate.v
// 模块名称：audio_arc_calculate
// 功能描述：HDMI音频时钟恢复（ACR）包N/CTS生成
// 目标器件：安路 EG4S20BG256
// ============================================================================
// HDMI音频时钟恢复包(ACR)：每ACR_N/128个音频样本发一次N/CTS。
// 本工程音频采样节拍由video_clk经NCO精确分频得到（与像素时钟同源），
// 每ACR_N/128个样本恰好对应固定的像素时钟拍数，CTS为常数，无需计数测量。
// 25MHz、48kHz、N=6144 时 CTS = 25e6*6144/(128*48e3) = 25000。
module audio_arc_calculate #(
    parameter ACR_N   = 6144,
    parameter ACR_CTS = 25000
    )(
    input wire       I_clk,
    input wire       I_rst,

    input wire       I_audio_valid,

    output reg       O_acr_valid,
    output reg[19:0] O_acr_cts,
    output reg[19:0] O_acr_n
);


    localparam AUDIO_DIV = ACR_N >> 7;

    reg[7:0]  S_audio_div_cnt;
    wire      S_audio_valid_div;


    always @(posedge I_clk or posedge I_rst) begin
        if(I_rst)
            S_audio_div_cnt <= 'd0;
        else
            if(I_audio_valid)
                begin
                    if(S_audio_div_cnt >= AUDIO_DIV-1)
                        S_audio_div_cnt <= 'd0;
                    else
                        S_audio_div_cnt <= S_audio_div_cnt + 'd1;
                end
            else
                S_audio_div_cnt <= S_audio_div_cnt;
    end


    assign S_audio_valid_div = I_audio_valid && (S_audio_div_cnt == AUDIO_DIV-1) ? 1'b1 : 1'b0;

    always @(posedge I_clk) begin
        if(S_audio_valid_div)
            begin
                O_acr_valid <= 1'b1;
                O_acr_cts   <= ACR_CTS;
                O_acr_n     <= ACR_N;
            end
        else    
            begin
                O_acr_valid <= 1'b0;
                O_acr_cts   <= 'd0;
                O_acr_n     <= 'd0;
            end
    end

    
endmodule