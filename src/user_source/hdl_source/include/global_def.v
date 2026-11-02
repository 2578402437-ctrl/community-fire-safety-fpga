


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

`define	  SDR_CLK_PERIOD				1000000000/125000000
// 自动刷新间隔（Sdr_clk 拍数）：规格 64 ms 内 4096 次 = 15.6 us = 1953 拍，
// 取 1500 拍（12 us）留余量；原式不带括号，整数除法结果为 0，刷新从未发出
`define   SELF_REFRESH_INTERVAL			1500

