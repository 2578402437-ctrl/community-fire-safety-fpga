
# ============================================================
# timing.sdc
# 用于：TF 图片轮播 + HDMI(视频+音频) 整合工程
#
# 约束内容：
# 1) 板级输入主时钟 + derive_clocks 自动推导 PLL 输出
# 2) 给 sys_pll / video_pll 的输出时钟命名
# 3) video_clk 与 hdmi_5x_clk 设为 exclusive
# 4) 不对内部 net 直接 create_clock，避免和 derive_clocks 重复
# ============================================================

# ------------------------------------------------------------
# 1. 板级输入主时钟
#    clk=50MHz，周期 20ns
# ------------------------------------------------------------
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

# ------------------------------------------------------------
# 2. 自动推导 PLL 输出时钟
# ------------------------------------------------------------
derive_clocks

# ------------------------------------------------------------
# 3. 给关键 PLL 输出命名
#    路径对应工程中的 PLL 实例名：
#      sys_pll      -> sys_pll_m0
#      video_pll    -> video_pll_m0
#
#    HDMI音频复用video_clk，没有独立的音频时钟。
#    如果综合后实例路径略有不同，就按 Timing Analyzer 里的实际 pin 路径改。
# ------------------------------------------------------------
rename_clock -name {sd_card_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {video_clk}   -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[1]}]
# SDRAM移位时钟（125MHz/180°），供7.5节伪路径约束引用
rename_clock -name {ext_mem_clk_sft} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[2]}]

# ------------------------------------------------------------
# 4. HDMI 像素/串行时钟组关系
#
#    像素时钟 video_clk 与串行时钟 hdmi_5x_clk 由 video_pll 产生，已通过 derive_clocks 建立，
#    这里只设置组关系，不重复 create_clock。
#
#    video_clk 和 hdmi_5x_clk 设成 exclusive。
#    如果后面 Timing Analyzer 明确显示两者之间需要做同步时序分析，再把这一条去掉。
# ------------------------------------------------------------
set_clock_groups -exclusive \
    -group [get_clocks {video_clk}] \
    -group [get_clocks {hdmi_5x_clk}]

# ------------------------------------------------------------
# 5. 可选：如果 frame_read_write 内部异步 FIFO 已经完全处理好了跨域，
#    且报告里总出现 video_clk / sd_card_clk / ext_mem_clk 之间的大量伪违例，
#    可以打开下面这组异步分组。
#
#    建议先不要开，先看报告；
#    只有确认这些跨域都只经过 FIFO / 同步器时再开。
# ------------------------------------------------------------
# set_clock_groups -asynchronous \
#     -group [get_clocks {sd_card_clk}] \
#     -group [get_clocks {ext_mem_clk}] \
#     -group [get_clocks {video_clk}] \
#     -group [get_clocks {hdmi_5x_clk}]

# ------------------------------------------------------------
# 6. 其余 Input/Output delay 暂不约束
# ------------------------------------------------------------

# ------------------------------------------------------------
# 7. 补充时序约束：
#    切掉复位/同步器第一级等伪路径，约束HDMI ODDR输出，
#    收紧保持时间不确定性，切掉SDRAM移位时钟这类硬IP内部路径。
# ------------------------------------------------------------

# 7.1 复位信号是异步的，不做时序分析
set_false_path -from [get_ports {rst_n}]

# 7.2 reset_sync/sync_2ff第一级触发器是异步采样，不做时序分析
set_false_path -to [get_regs -hier {*/s1}]

# 7.3 HDMI TMDS（ODDR）输出路径设最大延迟
set_max_delay -from [get_clocks {hdmi_5x_clk}] \
    -to [get_ports {HDMI_CLK_P HDMI_D0_P HDMI_D1_P HDMI_D2_P}] \
    8.000 -datapath_only

# 7.4 保持时间不确定性，默认值可能偏大导致伪违例
set_clock_uncertainty -hold 0.050 \
    [get_clocks {clk sd_card_clk ext_mem_clk video_clk hdmi_5x_clk}]

# 7.5 SDRAM移位时钟是硬IP内部的I/O窗口，不做fabric时序分析
set_false_path -from [get_clocks {ext_mem_clk}] -to [get_clocks {ext_mem_clk_sft}]
set_false_path -from [get_clocks {ext_mem_clk_sft}] -to [get_clocks {ext_mem_clk}]
