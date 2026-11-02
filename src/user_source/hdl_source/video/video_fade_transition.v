// ============================================================================
// 文件名称：video_fade_transition.v
// 模块名称：video_fade_transition
// 功能描述：转场控制器：预加载后双路合成，多种转场样式按次轮换，不经全黑
// 目标器件：安路 EG4S20BG256
// ============================================================================
`timescale 1ns/1ps

// 转场控制器（不经全黑）：新图由控制层预先加载到它自己的bank后才发起转场，
// 转场期间显示端双路读：A路=当前显示bank（旧图），B路=目标bank（新图），由顶层
// transition_shape_mask_24 逐像素合成。十种转场按次轮换（0→1→3→4→…→10→0）：
//   0 交叉淡化：逐像素 旧图 + (新图-旧图)*q/256；
//   1 撕裂·从中间往两边：中线向两侧推开的区域显示新图；
//   3 轮子：从12点方向顺时针扫过的扇形显示新图；
//   4 圆形光圈：从中心扩开的圆内显示新图；
//   5 燃烧纸张：自下而上沿不规则火线烧开旧图，火线带焦黑与火光，露出新图；
//   6 方块溶解  7 横百叶窗  8 菱形光圈  9 五角星光圈  10 卷帘（算法见 transition_shape_mask_24）。
//   （2 撕裂·从两边往中间：遮罩模块仍支持，轮换中不使用）
// 流程（像素域）：
//   S_PREP  PREP_FRAMES帧：q=0（仍是旧图），等B路bank号跨到mem域并生效；
//   S_MIX   q从0按smoothstep缓入缓出升到256（q=256·(3t²-2t³)，t=ramp/FADE_FRAMES），共FADE_FRAMES+1帧；
//   S_HAND  q=256（整幅新图，全部来自B路），翻转commit_toggle通知控制层把显示bank
//           切到目标bank；收到index_commit后再保持HAND_FRAMES帧，确保A路已读到新bank，
//           然后回S_IDLE改由A路显示——交接前后两路内容相同，看不出切换。
//           提交丢失时HOLD_TIMEOUT_FRAMES帧后兜底回S_IDLE。
// 画面不再渐暗：alpha_out恒为255（亮度仍由顶层折入）。
// 音频包络gain_alpha_out：转场中点压到约一半再回升（255-min(q,256-q)），其余时间255。
// 播放未激活时的请求直接放行（commit_toggle翻转），控制层硬切。
// FADE_FRAMES=0时整体旁路，next_event直通。
module video_fade_transition #(
    parameter integer FADE_FRAMES = 0,           // 合成阶段帧数，0=旁路
    parameter integer PREP_FRAMES = 4,           // 合成前等待B路生效的帧数
    parameter integer HAND_FRAMES = 4,           // 提交后等待A路读到新bank的帧数
    parameter integer HOLD_TIMEOUT_FRAMES = 180  // 等待提交的最长帧数（约3秒@60Hz）
) (
    // 控制域接口
    input  wire       ctrl_clk,
    input  wire       ctrl_rst_n,
    input  wire       next_event_in,    // 切换请求输入（新图已在目标bank就绪）
    output wire       next_event_out,   // 合成完成、可以提交（脉冲）
    output wire       fade_busy,        // 转场忙
    // 像素域接口
    input  wire       pix_clk,
    input  wire       pix_rst_n,
    input  wire       player_active,
    input  wire       frame_start,      // 帧开始
    input  wire       index_commit,     // 图片索引已切换
    output wire [7:0] alpha_out,        // 画面Alpha值（恒255，不再渐暗）
    output wire [7:0] gain_alpha_out,   // 音频转场包络
    output wire       fade_active,      // 转场进行中
    output wire       mix_active,       // 1=本帧双路合成（S_PREP~S_HAND）
    output wire [3:0] shape_kind,       // 合成类型：0=交叉淡化 1=中间往两边 2=两边往中间 3=轮子 4=光圈 5=燃烧
                                        // 6=溶解 7=横百叶窗 8=菱形光圈 9=五角星光圈 10=卷帘
    output wire       shape_in,         // 恒1（保留端口）
    output wire [8:0] shape_q           // 新图比例 0~256（256=整幅新图）
);
    genvar gi;   // smoothstep查表生成用

    generate
        if (FADE_FRAMES == 0) begin : g_bypass
            // 旁路模式：不启用转场
            assign next_event_out  = next_event_in;
            assign fade_busy       = 1'b0;
            assign alpha_out       = 8'd255;
            assign gain_alpha_out  = 8'd255;
            assign fade_active     = 1'b0;
            assign mix_active      = 1'b0;
            assign shape_kind      = 4'd0;
            assign shape_in        = 1'b1;
            assign shape_q         = 9'd0;
        end else begin : g_fade
            localparam integer CNT_W = (FADE_FRAMES <= 2) ? 2
                                      : $clog2(FADE_FRAMES + 1);
            localparam integer HOLD_W = $clog2(HOLD_TIMEOUT_FRAMES + 1);

            localparam [1:0] S_IDLE = 2'd0;
            localparam [1:0] S_PREP = 2'd1;
            localparam [1:0] S_MIX  = 2'd2;
            localparam [1:0] S_HAND = 2'd3;

            // 跨时钟域共享寄存器
            reg req_toggle;
            reg ack_seen;
            reg commit_sync1, commit_sync2;
            reg busy_sync1, busy_sync2;

            // 像素域寄存器
            reg [1:0] state;
            reg [CNT_W-1:0] ramp;        // S_MIX：0~FADE_FRAMES
            reg [HOLD_W-1:0] hold_cnt;   // S_PREP/S_HAND帧计数
            reg committed;               // S_HAND：已收到index_commit
            reg req_sync1, req_sync2, req_seen;
            reg commit_toggle;
            reg [3:0] cur_kind;    // 本次转场类型
            reg [3:0] next_kind;   // 下一次转场类型（每接受一次请求换下一种，0→1→3→4→5→6→7→8→9→10→0）

            wire fade_running = (state != S_IDLE);
            assign fade_active = fade_running;
            assign mix_active  = fade_running;

            // smoothstep查表：综合时按ramp算好FADE_FRAMES+1个常数，四舍五入，
            // q_tbl[0]=0、q_tbl[FADE_FRAMES]=256，单调且前后对称，不占乘法器
            wire [8:0] q_tbl [0:FADE_FRAMES];
            for (gi = 0; gi <= FADE_FRAMES; gi = gi + 1) begin : g_q_tbl
                assign q_tbl[gi] = ((3*gi*gi*FADE_FRAMES - 2*gi*gi*gi) * 256
                                    + FADE_FRAMES*FADE_FRAMES*FADE_FRAMES/2)
                                   / (FADE_FRAMES*FADE_FRAMES*FADE_FRAMES);
            end
            wire [8:0] q_mix = q_tbl[ramp];
            wire [8:0] q_now = (state == S_HAND) ? 9'd256 :
                               (state == S_MIX)  ? q_mix : 9'd0;
            assign shape_kind = (state == S_IDLE) ? 4'd0 : cur_kind;
            assign shape_in   = 1'b1;
            assign shape_q    = q_now;
            assign alpha_out  = 8'd255;

            // 音量包络：255 - min(q, 256-q)，中点约127（-6dB），两端255
            wire [8:0] q_dist = q_now[8] ? 9'd0 : (q_now[7] ? (9'd256 - q_now) : q_now);
            assign gain_alpha_out = 8'd255 - q_dist[7:0];

            // ========== 像素域状态机 ==========
            always @(posedge pix_clk or negedge pix_rst_n) begin
                if (!pix_rst_n) begin
                    state <= S_IDLE;
                    ramp <= {CNT_W{1'b0}};
                    hold_cnt <= {HOLD_W{1'b0}};
                    committed <= 1'b0;
                    req_sync1 <= 1'b0; req_sync2 <= 1'b0; req_seen <= 1'b0;
                    commit_toggle <= 1'b0;
                    cur_kind <= 4'd0; next_kind <= 4'd0;
                end else begin
                    req_sync1 <= req_toggle;
                    req_sync2 <= req_sync1;
                    // 转场进行中的新请求丢弃（控制层在fade_busy期间也不会再发）
                    if (req_sync2 != req_seen)
                        req_seen <= req_sync2;

                    case (state)
                    S_IDLE: begin
                        if (req_sync2 != req_seen) begin
                            if (player_active) begin
                                state <= S_PREP;
                                hold_cnt <= {HOLD_W{1'b0}};
                                cur_kind  <= next_kind;
                                next_kind <= (next_kind == 4'd10) ? 4'd0 :
                                             (next_kind == 4'd1)  ? 4'd3 : next_kind + 4'd1;
                            end else begin
                                // 尚未显示任何图：直接放行，控制层硬切
                                commit_toggle <= ~commit_toggle;
                            end
                        end
                        // 空闲时的index_commit（拨码硬切、开机首图等）不做转场
                    end

                    S_PREP: begin
                        if (frame_start) begin
                            if (hold_cnt >= PREP_FRAMES - 1) begin
                                state <= S_MIX;
                                ramp <= {CNT_W{1'b0}};
                            end else begin
                                hold_cnt <= hold_cnt + 1'b1;
                            end
                        end
                    end

                    S_MIX: begin
                        if (frame_start) begin
                            if (ramp == FADE_FRAMES) begin
                                // 整幅新图已显示一帧：通知控制层提交
                                state <= S_HAND;
                                hold_cnt <= {HOLD_W{1'b0}};
                                committed <= 1'b0;
                                commit_toggle <= ~commit_toggle;
                            end else begin
                                ramp <= ramp + 1'b1;
                            end
                        end
                    end

                    S_HAND: begin
                        if (index_commit && !committed) begin
                            committed <= 1'b1;
                            hold_cnt <= {HOLD_W{1'b0}};
                        end else if (frame_start) begin
                            if (committed ? (hold_cnt >= HAND_FRAMES - 1)
                                          : (hold_cnt >= HOLD_TIMEOUT_FRAMES - 1))
                                state <= S_IDLE;
                            else
                                hold_cnt <= hold_cnt + 1'b1;
                        end
                    end
                    endcase
                end
            end

            // ========== 控制域握手 ==========
            assign fade_busy = busy_sync2;
            assign next_event_out = (commit_sync2 != ack_seen);

            always @(posedge ctrl_clk or negedge ctrl_rst_n) begin
                if (!ctrl_rst_n) begin
                    req_toggle <= 1'b0;
                    ack_seen <= 1'b0;
                    commit_sync1 <= 1'b0; commit_sync2 <= 1'b0;
                    busy_sync1 <= 1'b0; busy_sync2 <= 1'b0;
                end else begin
                    busy_sync1 <= fade_running;
                    busy_sync2 <= busy_sync1;
                    commit_sync1 <= commit_toggle;
                    commit_sync2 <= commit_sync1;
                    // 转场忙时丢弃新请求
                    if (next_event_in && !busy_sync2)
                        req_toggle <= ~req_toggle;
                    if (commit_sync2 != ack_seen)
                        ack_seen <= commit_sync2;
                end
            end
        end
    endgenerate
endmodule
