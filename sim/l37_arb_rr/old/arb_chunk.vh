localparam OWN_SCAN = 2'd0, OWN_IMG = 2'd1, OWN_WAV = 2'd2;

wire        wav_sector_req;
wire [31:0] wav_sector_lba;
wire        wav_stream_end_wr;
wire        wav_stream_idle_wr;

wire image_wants_bus = streamer_sector_req || streamer_busy;
wire wav_wants_bus    = wav_sector_req;

reg        bus_committed;
reg [1:0]  bus_owner;

wire committed_now = bus_committed || arb_sector_req;

always @(posedge clk or posedge rst) begin
    if (rst)
        bus_committed <= 1'b0;
    else if (arb_sector_done)
        bus_committed <= 1'b0;
    else if (arb_sector_req)
        bus_committed <= 1'b1;
end

always @(posedge clk or posedge rst) begin
    if (rst)
        bus_owner <= OWN_SCAN;
    else if (!committed_now) begin
        if (scanner_busy)
            bus_owner <= OWN_SCAN;
        else if (image_wants_bus)
            bus_owner <= OWN_IMG;
        else if (wav_wants_bus)
            bus_owner <= OWN_WAV;
        // 三者都不请求：保持原owner，等下一次有人请求时再判定
    end
end

wire sel_scan = (bus_owner == OWN_SCAN);
wire sel_img  = (bus_owner == OWN_IMG);
wire sel_wav  = (bus_owner == OWN_WAV);

assign arb_sector_req = sel_scan ? scanner_sector_req :
                        sel_img  ? streamer_sector_req : wav_sector_req;
assign arb_sector_lba = sel_scan ? scanner_sector_lba :
                        sel_img  ? streamer_sector_lba : wav_sector_lba;

