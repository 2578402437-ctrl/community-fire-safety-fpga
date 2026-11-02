#!/bin/sh
# 编译三组库：work_m1(MIX=1,LAT=6) work_m1l14(MIX=1,LAT=14) work_m0(MIX=0,LAT=6)
cd "$(dirname "$0")"
H=../../src/user_source/hdl_source
SRC="$H/memory/frame_read_write.v $H/memory/frame_fifo_read.v $H/memory/frame_fifo_write.v $H/ip/afifo_16_32_256.v $H/ip/afifo_32_16_256.v $H/video/video_timing_data.v $H/video/color_bar.v $H/video/video_delay.v tb_dual_read.v"
for cfg in "work_m1 1 6" "work_m1l14 1 14" "work_m0 0 6"; do
  set -- $cfg
  rm -rf $1; vlib $1 >/dev/null
  vlog -work $1 +define+MIX=$2 +define+LAT=$3 +incdir+$H/video $SRC 2>&1 | grep -E "Error|Errors:"
done
