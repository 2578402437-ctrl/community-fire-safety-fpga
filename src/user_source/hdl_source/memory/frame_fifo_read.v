// ============================================================================
// 文件名称：frame_fifo_read.v
// 模块名称：frame_fifo_read
// 功能描述：帧缓存读通道：按帧突发读SDRAM，支持缩略图抽取读与A/B双路读
// 目标器件：安路 EG4S20BG256
// ============================================================================
`timescale 1ns/1ps
module frame_fifo_read
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,
	parameter FIFO_DEPTH             = 512,
	parameter BURST_SIZE             = 128,
	// 缩略图读模式参数（2×2格，每格THUMB_WIDTH×THUMB_HEIGHT，源图FRAME_WIDTH宽）
	parameter FRAME_WIDTH            = 640,
	parameter THUMB_HEIGHT           = 240,
	parameter THUMB_STEP             = 2                         // 最近邻抽取步长 = 640/320 = 480/240（铺满全屏的2×2）
)               
(
	input                            rst,                  
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
    input							 Sdr_rd_en,
	input							 App_wr_busy,
    output							 O_rd_busy,
	/*
    output reg                       rd_burst_req,               // to external memory controller,send out a burst read request  
	output reg[BURST_BITS - 1:0]     rd_burst_len,               // to external memory controller,data length of the burst read request, not bytes 
	output reg[ADDR_BITS - 1:0]      rd_burst_addr,              // to external memory controller,base address of the burst read request
	input                            rd_burst_data_valid,        // from external memory controller,read request data valid    
	input                            rd_burst_finish,            // from external memory controller,burst read finish
	*/
	output 							 App_rd_en,
	output  [ADDR_BITS - 1:0]		 App_rd_addr,
	
	input                            read_req,                   // data read module read request,keep '1' until read_req_ack = '1'
	output reg                       read_req_ack,               // data read module read request response
	output                           read_finish,                // data read module read request finish
	input[ADDR_BITS - 1:0]           read_addr_0,                // data read module read request base address 0, used when read_addr_index = 0
	input[ADDR_BITS - 1:0]           read_addr_1,                // data read module read request base address 1, used when read_addr_index = 1
	input[ADDR_BITS - 1:0]           read_addr_2,                // data read module read request base address 1, used when read_addr_index = 2
	input[ADDR_BITS - 1:0]           read_addr_3,                // data read module read request base address 1, used when read_addr_index = 3
	input[1:0]                       read_addr_index,            // select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
	input[ADDR_BITS - 1:0]           read_len,                   // data read module read request data length
	output reg                       fifo_aclr,                  // to fifo asynchronous clear
	input[9:0]                      wrusedw,                    // from fifo write used words
	// 缩略图读模式
	input                            thumb_mode,                 // 像素域本帧模式(view_mode_frame)，异步，S_ACK期间采样
	output                           rd_fifo_we,                 // 读FIFO写使能：全屏=Sdr_rd_en；缩略图=每THUMB_STEP个数据留1个
	// 双路读模式（B路FIFO）
	input                            mix_en,                     // 双路读使能，异步慢变化，S_ACK期间采样；缩略图帧不启用
	input[1:0]                       mix_addr_index,             // B路图片bank号，异步慢变化
	input[9:0]                       wrusedw_b,                  // B路FIFO写侧已用字数
	output                           rd_fifo_we_b                // B路FIFO写使能

);
localparam ONE                       = 256'd1;                   //256 bit '1'   you can use ONE[n-1:0] for n bit '1'
localparam ZERO                      = 256'd0;                   //256 bit '0'
//read state machine code
localparam S_IDLE                    = 0;                        //idle state,waiting for frame read
localparam S_ACK                     = 1;                        //read request response
localparam S_CHECK_FIFO              = 2;                        //check the FIFO status, ensure that there is enough space to burst read
localparam S_READ_BURST              = 3;                        //begin a burst read
localparam S_READ_BURST_END          = 4;                        //a burst read complete
localparam S_END                     = 5;                        //a frame of data is read to complete

reg                                  read_req_d0;                //asynchronous read request, synchronize to 'mem_clk' clock domain,first beat
reg                                  read_req_d1;                //second
reg                                  read_req_d2;                //third,Why do you need 3 ? Here's the design habit
reg[ADDR_BITS - 1:0]                 read_len_d0;                //asynchronous read_len(read data length), synchronize to 'mem_clk' clock domain first
reg[ADDR_BITS - 1:0]                 read_len_d1;                //second
reg[ADDR_BITS - 1:0]                 read_len_latch;             //lock read data length
reg[ADDR_BITS - 1:0]                 read_cnt;                   //read data counter
reg[3:0]                             state;                      //state machine
reg[1:0]                             read_addr_index_d0;         //synchronize to 'mem_clk' clock domain first
reg[1:0]                             read_addr_index_d1;         //synchronize to 'mem_clk' clock domain second
reg [ADDR_BITS - 1:0]	 App_rd_addr_r;

reg [BURST_BITS - 1:0]				burst_cnt;
wire								rd_burst_finish;
reg App_rd_en_r;
reg App_rd_en_d0;

// ===================== 缩略图读模式 =====================
// 每条屏幕行(t_line=0~2*THUMB_HEIGHT-1)读2段(t_half=0左格/1右格)，每段是源图一整行
// (FRAME_WIDTH字)。段内突发长度与全屏模式相同(BURST_SIZE=256)，最后一次读剩余部分
// (640 = 256+256+128)。段首地址是256的整数倍，所以每次突发都对齐SDRAM页、不跨页，
// 访问模式与全屏模式一致：
//   源图编号 = {t_line>=THUMB_HEIGHT, t_half}（上排0/1、下排2/3）
//   源行号   = (t_line % THUMB_HEIGHT) * THUMB_STEP
//   段首地址 = read_addr_[源图编号] + 源行号*FRAME_WIDTH（t_row_off累加得到，无乘法器）
// 数据回来后每THUMB_STEP个只写1个进FIFO，即 source_x = local_x*THUMB_STEP 的最近邻抽取。
// 总读量 2*THUMB_HEIGHT*2*FRAME_WIDTH：每格320×240时为614400字/帧，是全屏模式的2倍
// （每个源行只用一半像素，另一半读出后丢弃），按125MHz、突发效率约90%估算占用约40%带宽。
localparam integer THUMB_ROW_STRIDE = FRAME_WIDTH * THUMB_STEP;            // 相邻缩略行的源地址跨度（640*2=1280）

reg                                  thumb_mode_d0;
reg                                  thumb_mode_d1;
reg                                  thumb_mode_latch;           // 本帧是否缩略图读模式
reg [11:0]                           t_seg_left;                 // 当前段(一个源行)还剩多少字没读
reg                                  t_half;                     // 0=左格 1=右格
reg [8:0]                            t_line;                     // 缩略图屏幕行 0~2*THUMB_HEIGHT-1
reg [ADDR_BITS - 1:0]                t_row_off;                  // 源行偏移 = (t_line%THUMB_HEIGHT)*THUMB_STEP*FRAME_WIDTH
reg                                  t_done;                     // 本帧缩略图数据已全部读出
reg [3:0]                            rd_word_cnt;                // 返回数据计数（模THUMB_STEP）

wire                                 t_seg_last    = (t_seg_left <= BURST_SIZE);   // 本次突发读完当前段
wire [BURST_BITS:0]                  cur_burst_len = (thumb_mode_latch && t_seg_last) ? t_seg_left[BURST_BITS:0] : BURST_SIZE;
wire [1:0]                           t_src_idx     = {(t_line >= THUMB_HEIGHT), t_half};
reg  [ADDR_BITS - 1:0]               t_src_base;

always @(*) begin
	case (t_src_idx)
		2'd0:    t_src_base = read_addr_0;
		2'd1:    t_src_base = read_addr_1;
		2'd2:    t_src_base = read_addr_2;
		default: t_src_base = read_addr_3;
	endcase
end

// ===================== 双路读模式 =====================
// 本帧同时读两张图：A路 = read_addr_index 对应bank，B路 = mix_addr_index 对应bank，
// 各写一个读FIFO，像素端两路同拍读出。突发严格交替 A,B,A,B…，每次BURST_SIZE字，
// 一帧共 2*read_len 字（640×480 时每路1200次突发，正好整除，不出现零头突发）。
// 地址：App_rd_addr_r 为当前路的读指针，mix_alt_addr 存另一路的下一地址，每次突发结束互换。
// 返回数据的去向按"已返回字数"计数（每BURST_SIZE字换一次路），不依赖SDRAM核的读延迟。
// 缩略图帧不启用双路读（mix_latch=0），全屏时按单路逐拍读取。
reg                                  mix_en_d0;
reg                                  mix_en_d1;
reg[1:0]                             mix_index_d0;
reg[1:0]                             mix_index_d1;
reg                                  mix_latch;                  // 本帧是否双路读
reg                                  mix_cur_b;                  // 当前/下一次突发读B路
reg[ADDR_BITS - 1:0]                 mix_alt_addr;               // 另一路的下一次突发地址
reg[ADDR_BITS - 1:0]                 mix_base_b;
reg                                  ret_b;                      // 当前返回数据属于B路
reg[BURST_BITS - 1:0]                ret_cnt;                    // 本次突发已返回字数

always @(*) begin
	case (mix_index_d1)
		2'd0:    mix_base_b = read_addr_0;
		2'd1:    mix_base_b = read_addr_1;
		2'd2:    mix_base_b = read_addr_2;
		default: mix_base_b = read_addr_3;
	endcase
end

wire [ADDR_BITS - 1:0]               frame_words  = mix_latch ? {read_len_latch[ADDR_BITS - 2:0], 1'b0} : read_len_latch;
wire [9:0]                           cur_wrusedw  = (mix_latch && mix_cur_b) ? wrusedw_b : wrusedw;

assign rd_fifo_we   = Sdr_rd_en & (mix_latch ? ~ret_b : (~thumb_mode_latch | (rd_word_cnt == 4'd0)));
assign rd_fifo_we_b = Sdr_rd_en & mix_latch & ret_b;


wire rd_vld;
reg [3:0] rd_delay;

assign App_rd_addr = {App_rd_addr_r[ADDR_BITS - 1:0]};
assign rd_vld = (state == S_READ_BURST && burst_cnt >= cur_burst_len);

assign O_rd_busy = (state == S_READ_BURST);//读指令期间
//burst_cnt代表发送的读指令
//但rd_burst_finish需要在发送完十个时钟后拉高，此时数据全部读出
assign rd_burst_finish = (rd_vld && rd_delay == 4'd10);
assign read_finish = (state == S_END) ? 1'b1 : 1'b0;             //read finish at state 'S_END'
assign App_rd_en = App_rd_en_d0;
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		read_req_d0    <=  1'b0;
		read_req_d1    <=  1'b0;
		read_req_d2    <=  1'b0;
		read_len_d0    <=  ZERO[ADDR_BITS - 1:0];               //equivalent to read_len_d0 <= 0;
		read_len_d1    <=  ZERO[ADDR_BITS - 1:0];               //equivalent to read_len_d1 <= 0;
		read_addr_index_d0 <= 2'b00;
		read_addr_index_d1 <= 2'b00;
		thumb_mode_d0  <=  1'b0;
		thumb_mode_d1  <=  1'b0;
		mix_en_d0      <=  1'b0;
		mix_en_d1      <=  1'b0;
		mix_index_d0   <=  2'b00;
		mix_index_d1   <=  2'b00;
	end
	else
	begin
		mix_en_d0      <=  mix_en;
		mix_en_d1      <=  mix_en_d0;
		mix_index_d0   <=  mix_addr_index;
		mix_index_d1   <=  mix_index_d0;
		read_req_d0    <=  read_req;
		read_req_d1    <=  read_req_d0;
		read_req_d2    <=  read_req_d1;     
		read_len_d0    <=  read_len;
		read_len_d1    <=  read_len_d0; 
		read_addr_index_d0 <= read_addr_index;
		read_addr_index_d1 <= read_addr_index_d0;
		thumb_mode_d0  <=  thumb_mode;
		thumb_mode_d1  <=  thumb_mode_d0;
	end 
end

always @(posedge mem_clk or posedge rst)
begin
	if(rst || App_rd_en)begin
        rd_delay <= 4'd0;
    end
    else if(rd_delay < 4'd10)begin
    	rd_delay <= rd_delay + 1'b1;
    end
end
always @(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		burst_cnt <= ZERO[BURST_BITS - 1:0];
		App_rd_addr_r <= ZERO[ADDR_BITS - 1:0];
		App_rd_en_d0 <= 1'b0;
	end
	else begin
	
		if(state == S_CHECK_FIFO)
			burst_cnt <= ZERO[BURST_BITS - 1:0];
		else if(App_rd_en)
			burst_cnt <= burst_cnt + 1'b1;
		else
			burst_cnt <= burst_cnt;
		//
		if(state == S_ACK)
			begin
				// 缩略图模式从图0第0行开始（thumb_mode_d1与thumb_mode_latch在S_ACK期间同值）
				if(thumb_mode_d1)
					App_rd_addr_r <= read_addr_0;
				else if(read_addr_index_d1 == 2'd0)
					App_rd_addr_r <= read_addr_0;
				else if(read_addr_index_d1 == 2'd1)
					App_rd_addr_r <= read_addr_1;
				else if(read_addr_index_d1 == 2'd2)
					App_rd_addr_r <= read_addr_2;
				else if(read_addr_index_d1 == 2'd3)
					App_rd_addr_r <= read_addr_3;
			end
		else if(state == S_READ_BURST_END && thumb_mode_latch && t_seg_left == FRAME_WIDTH)
			// 缩略图模式：上一段(一整行源像素)读完，跳到下一段的段首地址
			App_rd_addr_r <= t_src_base + t_row_off;
		else if(state == S_READ_BURST_END && mix_latch)
			// 双路读：本路读指针存起来，换到另一路
			App_rd_addr_r <= mix_alt_addr;
		else if(App_rd_en)
			App_rd_addr_r <= App_rd_addr_r + 1'b1;
		else
			App_rd_addr_r <= App_rd_addr_r;
		//
		if(App_rd_en_r && burst_cnt + App_rd_en < cur_burst_len)
			App_rd_en_d0 <= 1'b1;
		else
			App_rd_en_d0 <= 1'b0;
	
	end		
end
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		read_len_latch <= ZERO[ADDR_BITS - 1:0];
		
		//rd_burst_addr <= ZERO[ADDR_BITS - 1:0];
		//rd_burst_req <= 1'b0;
		App_rd_en_r <= 1'b0;
		
		read_cnt <= ZERO[ADDR_BITS - 1:0];
		fifo_aclr <= 1'b0;
		//rd_burst_len <= ZERO[BURST_BITS - 1:0];
		read_req_ack <= 1'b0;
		thumb_mode_latch <= 1'b0;
		t_seg_left <= FRAME_WIDTH;
		t_half <= 1'b0;
		t_line <= 9'd0;
		t_row_off <= ZERO[ADDR_BITS - 1:0];
		t_done <= 1'b0;
	end
	else
		case(state)
			//idle state,waiting for read, read_req_d2 == '1' goto the 'S_ACK'
			S_IDLE:
			begin
				if(read_req_d2 == 1'b1 && Sdr_init_done)
				begin
					state <= S_ACK;
				end
				read_req_ack <= 1'b0;
			end
			//'S_ACK' state completes the read request response, the FIFO reset, the address latch, and the data length latch
			S_ACK:
			begin
				if(read_req_d2 == 1'b0)
				begin
					state <= S_CHECK_FIFO;
					fifo_aclr <= 1'b0;
					read_req_ack <= 1'b0;
				end
				else
				begin
					//read request response
					read_req_ack <= 1'b1;
					//FIFO reset
					fifo_aclr <= 1'b1;
					//select valid base address from read_addr_0 read_addr_1 read_addr_2 read_addr_3
					/*
					if(read_addr_index_d1 == 2'd0)
						App_rd_addr <= read_addr_0;
					else if(read_addr_index_d1 == 2'd1)
						App_rd_addr <= read_addr_1;
					else if(read_addr_index_d1 == 2'd2)
						App_rd_addr <= read_addr_2;
					else if(read_addr_index_d1 == 2'd3)
						App_rd_addr <= read_addr_3;
					*/
					//latch data length
					read_len_latch <= read_len_d1;
				end
				//read data counter reset, read_cnt <= 0;
				read_cnt <= ZERO[ADDR_BITS - 1:0];
				// 锁存本帧读模式，缩略图计数器复位
				thumb_mode_latch <= thumb_mode_d1;
				t_seg_left <= FRAME_WIDTH;
				t_half <= 1'b0;
				t_line <= 9'd0;
				t_row_off <= ZERO[ADDR_BITS - 1:0];
				t_done <= 1'b0;
			end
			S_CHECK_FIFO:
			begin
				//if there is a read request at this time, enter the 'S_ACK' state
				if(read_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the FIFO space is a burst read request, goto burst read state
				//刷新窗口(Sdr_init_ref_vld)内不发起突发，避免刷新后tRFC未满就激活行
				else if(cur_wrusedw < (FIFO_DEPTH - BURST_SIZE) && ~App_wr_busy && ~Sdr_init_ref_vld)
				begin
					state <= S_READ_BURST;
					//rd_burst_len <= BURST_SIZE[BURST_BITS - 1:0];
					//rd_burst_req <= 1'b1;
					App_rd_en_r <= 1'b1;
				end
			end
			
			S_READ_BURST:
			begin
				//burst finish  
				if(rd_burst_finish == 1'b1)
				begin
					App_rd_en_r <= 1'b0;
					state <= S_READ_BURST_END;
					//read counter + burst length
					read_cnt <= read_cnt + cur_burst_len;
					// 缩略图模式推进 突发→段(左/右格)→屏幕行
					if(thumb_mode_latch)
					begin
						if(t_seg_last)
						begin
							t_seg_left <= FRAME_WIDTH;
							if(t_half == 1'b0)
								t_half <= 1'b1;
							else
							begin
								t_half <= 1'b0;
								if(t_line == 2 * THUMB_HEIGHT - 1)
									t_done <= 1'b1;
								else
								begin
									t_line <= t_line + 1'b1;
									// 每排缩略图的第一行回到源图第0行
									if(t_line == THUMB_HEIGHT - 1)
										t_row_off <= ZERO[ADDR_BITS - 1:0];
									else
										t_row_off <= t_row_off + THUMB_ROW_STRIDE;
								end
							end
						end
						else
							t_seg_left <= t_seg_left - BURST_SIZE;
					end
					//the next burst read address is generated
					//rd_burst_addr <= rd_burst_addr + BURST_SIZE[ADDR_BITS - 1:0];
				end     
			end
			S_READ_BURST_END:
			begin
				//if there is a read request at this time, enter the 'S_ACK' state
				if(read_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the read counter value is less than the frame length, continue read,
				//otherwise the read is complete
				else if(thumb_mode_latch ? !t_done : (read_cnt < frame_words))
				begin
					state <= S_CHECK_FIFO;
				end
				else
				begin
					state <= S_END;
				end
			end
			S_END:
			begin
				state <= S_IDLE;
			end
			default:
				state <= S_IDLE;
		endcase
end
// 返回数据计数，缩略图模式下每THUMB_STEP个数据只写1个进FIFO
always @(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
		rd_word_cnt <= 4'd0;
	else if(state == S_ACK)
		rd_word_cnt <= 4'd0;
	else if(Sdr_rd_en)
		rd_word_cnt <= (rd_word_cnt == THUMB_STEP - 1) ? 4'd0 : rd_word_cnt + 4'd1;
end
// 双路读：本帧模式锁存、两路读指针互换、返回数据按字数分路
always @(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		mix_latch    <= 1'b0;
		mix_cur_b    <= 1'b0;
		mix_alt_addr <= ZERO[ADDR_BITS - 1:0];
		ret_b        <= 1'b0;
		ret_cnt      <= ZERO[BURST_BITS - 1:0];
	end
	else if(state == S_ACK)
	begin
		mix_latch    <= mix_en_d1 & ~thumb_mode_d1;
		mix_cur_b    <= 1'b0;
		mix_alt_addr <= mix_base_b;
		ret_b        <= 1'b0;
		ret_cnt      <= ZERO[BURST_BITS - 1:0];
	end
	else
	begin
		if(state == S_READ_BURST_END && mix_latch)
		begin
			mix_alt_addr <= App_rd_addr_r;
			mix_cur_b    <= ~mix_cur_b;
		end
		if(Sdr_rd_en && mix_latch)
		begin
			if(ret_cnt == BURST_SIZE - 1)
			begin
				ret_cnt <= ZERO[BURST_BITS - 1:0];
				ret_b   <= ~ret_b;
			end
			else
				ret_cnt <= ret_cnt + 1'b1;
		end
	end
end
endmodule
