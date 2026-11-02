module sys_pll (refclk, clk0_out, clk1_out, clk2_out, reset, locked);
    input [63:0] refclk;
    input [63:0] clk0_out;
    input [63:0] clk1_out;
    input [63:0] clk2_out;
    input [63:0] reset;
    input [63:0] locked;
endmodule

module video_pll (refclk, clk0_out, clk1_out, reset, locked);
    input [63:0] refclk;
    input [63:0] clk0_out;
    input [63:0] clk1_out;
    input [63:0] reset;
    input [63:0] locked;
endmodule

module wfifo_32_32_512 (clkr, clkw, rst, we, re, di, empty_flag, full_flag, wrusedw, rdusedw, dout);
    input [63:0] clkr;
    input [63:0] clkw;
    input [63:0] rst;
    input [63:0] we;
    input [63:0] re;
    input [63:0] di;
    input [63:0] empty_flag;
    input [63:0] full_flag;
    input [63:0] wrusedw;
    input [63:0] rdusedw;
    input [63:0] dout;
endmodule

module rfifo_32_32_512 (clkr, clkw, rst, we, re, di, empty_flag, full_flag, wrusedw, rdusedw, dout);
    input [63:0] clkr;
    input [63:0] clkw;
    input [63:0] rst;
    input [63:0] we;
    input [63:0] re;
    input [63:0] di;
    input [63:0] empty_flag;
    input [63:0] full_flag;
    input [63:0] wrusedw;
    input [63:0] rdusedw;
    input [63:0] dout;
endmodule

module sdram (Clk, Clk_sft, Rst, Sdr_init_done, Sdr_init_ref_vld, Sdr_busy, App_wr_en, App_wr_addr, App_wr_dm, App_wr_din, App_rd_en, App_rd_addr, Sdr_rd_en, Sdr_rd_dout);
    input [63:0] Clk;
    input [63:0] Clk_sft;
    input [63:0] Rst;
    input [63:0] Sdr_init_done;
    input [63:0] Sdr_init_ref_vld;
    input [63:0] Sdr_busy;
    input [63:0] App_wr_en;
    input [63:0] App_wr_addr;
    input [63:0] App_wr_dm;
    input [63:0] App_wr_din;
    input [63:0] App_rd_en;
    input [63:0] App_rd_addr;
    input [63:0] Sdr_rd_en;
    input [63:0] Sdr_rd_dout;
endmodule

module pcm_media_tone (clk, rst, sample_tick, media_id, audio_valid, audio_left, audio_right);
    input [63:0] clk;
    input [63:0] rst;
    input [63:0] sample_tick;
    input [63:0] media_id;
    input [63:0] audio_valid;
    input [63:0] audio_left;
    input [63:0] audio_right;
endmodule

module hdmi_1_4b_transmitter_core_wrapper #(parameter DEVICE = 0, parameter HTOTAL = 0, parameter HSA = 0, parameter HFP = 0, parameter HBP = 0, parameter HACTIVE = 0, parameter VTOTAL = 0, parameter VSA = 0, parameter VFP = 0, parameter VBP = 0, parameter VACTIVE = 0, parameter VIDEO_VIC = 0, parameter VIDEO_TPG = 0, parameter VIDEO_FORMAT = 0, parameter AUDIO_SAMPLE_RATE = 0, parameter IIC_SCL_DIV = 0) (I_pixel_clk, I_rst, I_edid_read_trig, O_edid_read_valid, O_edid_read_data, I_axis_s_user, I_axis_s_valid, I_axis_s_last, I_axis_s_data, O_axis_s_ready, I_audio_valid, I_audio_left_data, I_audio_right_data, I_acr_valid, I_acr_cts, I_acr_n, O_video_locked, O_ddc_scl, IO_ddc_sda, O_ch0_tmds_data, O_ch1_tmds_data, O_ch2_tmds_data, O_clk_tmds_data);
    input [63:0] I_pixel_clk;
    input [63:0] I_rst;
    input [63:0] I_edid_read_trig;
    input [63:0] O_edid_read_valid;
    input [63:0] O_edid_read_data;
    input [63:0] I_axis_s_user;
    input [63:0] I_axis_s_valid;
    input [63:0] I_axis_s_last;
    input [63:0] I_axis_s_data;
    input [63:0] O_axis_s_ready;
    input [63:0] I_audio_valid;
    input [63:0] I_audio_left_data;
    input [63:0] I_audio_right_data;
    input [63:0] I_acr_valid;
    input [63:0] I_acr_cts;
    input [63:0] I_acr_n;
    input [63:0] O_video_locked;
    input [63:0] O_ddc_scl;
    input [63:0] IO_ddc_sda;
    input [63:0] O_ch0_tmds_data;
    input [63:0] O_ch1_tmds_data;
    input [63:0] O_ch2_tmds_data;
    input [63:0] O_clk_tmds_data;
endmodule

module EG_LOGIC_ODDR (clk, rst, d1, d0, q);
    input [63:0] clk;
    input [63:0] rst;
    input [63:0] d1;
    input [63:0] d0;
    input [63:0] q;
endmodule
