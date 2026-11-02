localparam OWN_SCAN = 2'd0, OWN_IMG = 2'd1, OWN_WAV = 2'd2;

wire        wav_sector_req;
wire [31:0] wav_sector_lba;
wire        wav_stream_end_wr;
wire        wav_stream_idle_wr;
wire        scaler_hold;      // 缩放器像素FIFO快满，暂停SD读取

reg        bus_committed;
reg [1:0]  bus_owner;
reg        last_img;          // 最近一次被接收的扇区请求来自流读器（用于与WAV交替）
reg        wav_want_r;        // wav_sector_req打一拍：只用于选owner，不让WAV请求经过选owner逻辑再到适配器

// WAV请求是电平，被接收前一直保持，晚一拍判定不会丢；本拍刚被接收的请求不再算（避免读完后多判一次）
wire image_wants_bus = streamer_sector_req || (streamer_busy && !scaler_hold);
wire wav_wants_bus   = wav_want_r;

wire sel_scan = (bus_owner == OWN_SCAN);
wire sel_img  = (bus_owner == OWN_IMG);
wire sel_wav  = (bus_owner == OWN_WAV);

wire arb_req_raw = sel_scan ? scanner_sector_req :
                   sel_img  ? streamer_sector_req : wav_sector_req;
wire arb_locked  = bus_committed || (arb_req_raw && !sel_wav);

reg  [1:0] owner_next;
always @(*) begin
    if (scanner_busy)
        owner_next = OWN_SCAN;
    else if (image_wants_bus && wav_wants_bus)
        owner_next = last_img ? OWN_WAV : OWN_IMG;
    else if (image_wants_bus)
        owner_next = OWN_IMG;
    else if (wav_wants_bus)
        owner_next = OWN_WAV;
    else
        owner_next = bus_owner;   // 三者都不请求：保持原owner
end
wire owner_change = !arb_locked && (owner_next != bus_owner);

assign arb_sector_req = arb_req_raw && !owner_change;
assign arb_sector_lba = sel_scan ? scanner_sector_lba :
                        sel_img  ? streamer_sector_lba : wav_sector_lba;

// 各请求方看到的busy：不是主人、或本拍正在换主人，都为1
wire grant_busy_scan = !(sel_scan && !owner_change) || arb_sector_busy;
wire grant_busy_img  = !sel_img || arb_sector_busy;
wire grant_busy_wav  = !(sel_wav  && !owner_change) || arb_sector_busy;

always @(posedge clk or posedge rst) begin
    if (rst)
        bus_committed <= 1'b0;
    else if (arb_sector_done)
        bus_committed <= 1'b0;
    else if (arb_sector_req)
        bus_committed <= 1'b1;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bus_owner  <= OWN_SCAN;
        last_img   <= 1'b0;
        wav_want_r <= 1'b0;
    end else begin
        wav_want_r <= wav_sector_req && !(sel_wav && arb_sector_req && !arb_sector_busy);
        if (owner_change)
            bus_owner <= owner_next;
        if (arb_sector_req && !arb_sector_busy)
            last_img <= sel_img;
    end
end

