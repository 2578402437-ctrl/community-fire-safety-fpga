// ============================================================================
// 文件名称：video_delay.v
// 模块名称：video_delay
// 功能描述：视频同步信号延迟对齐：产生帧缓存读使能，输出A/B两路像素
// 目标器件：安路 EG4S20BG256
// ============================================================================
module video_delay
#(
	parameter DATA_WIDTH = 24                       // Video data one clock data width
)
(
	input                       video_clk,          // Video pixel clock
	input                       rst,
	output                      read_en,            // Read data enable
	input[DATA_WIDTH - 1:0]     read_data,          // Read data
	input                      hs,                 // horizontal synchronization
	input                      vs,                 // vertical synchronization
	input                      de,                 // video valid

	output                      hs_r,                 // horizontal synchronization
	output                      vs_r,                 // vertical synchronization
	output                      de_r,                 // video valid
	output[DATA_WIDTH - 1:0]    vout_data,          // video data
	input[DATA_WIDTH - 1:0]     read_data_b,        // 双路读B路数据（与read_data同拍）
	output[DATA_WIDTH - 1:0]    vout_data_b,        // B路像素，与vout_data同拍
	output                      vs_pre,             // 比vs_r早一拍（与read_data同拍），供转场合成
	output                      de_pre              // 比de_r早一拍（与read_data同拍），供转场合成
);
reg [20:0] hs_d;
reg [20:0] vs_d;
reg [20:0] de_d;
reg[DATA_WIDTH - 1:0]  vout_data_r;

assign read_en = de_d[18];
assign hs_r = hs_d[20];
assign vs_r = vs_d[20];
assign de_r = de_d[20];
assign vs_pre = vs_d[19];
assign de_pre = de_d[19];
assign vout_data = vout_data_r;
reg[DATA_WIDTH - 1:0]  vout_data_b_r;
assign vout_data_b = vout_data_b_r;
always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1)
		vout_data_b_r <= {DATA_WIDTH{1'b0}};
	else if(de_d[19])
		vout_data_b_r <= read_data_b;
	else
		vout_data_b_r <= {DATA_WIDTH{1'b0}};
end
always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1)
		vout_data_r <= {DATA_WIDTH{1'b0}};
	else if(de_d[19])
		vout_data_r <= read_data;
	else
		vout_data_r <= {DATA_WIDTH{1'b0}};
end
always @(posedge video_clk or posedge rst)begin
	if(rst)begin
    	hs_d <= 20'b0;
        vs_d <= 20'b0;
        de_d <= 20'b0;
    end
	else begin
    	
    	hs_d <= {hs_d[19:0],hs};
        vs_d <= {vs_d[19:0],vs};
        de_d <= {de_d[19:0],de};
    end
end
endmodule
