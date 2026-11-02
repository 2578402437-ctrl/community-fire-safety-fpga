#!/bin/sh
# 变异：流读器的 busy 不含 owner_change（切换拍可能误认请求已被接收），应挂死或出错
cd "$(dirname "$0")"
H=../../src/user_source/hdl_source
mkdir -p mut; cp new/arb_chunk.vh mut/arb_chunk.vh
sed -i 's/^wire grant_busy_img  = !(sel_img  \&\& !owner_change) || arb_sector_busy;/wire grant_busy_img  = !sel_img || arb_sector_busy;/' mut/arb_chunk.vh
grep -a "grant_busy_img  =" mut/arb_chunk.vh
rm -rf mut/work; vlib mut/work >/dev/null
vlog -work mut/work +incdir+mut $H/sd/sd_sector_adapter.v $H/sd/fat32_file_streamer.v $H/audio/wav_stream_player.v tb_arb_rr.v > mut/vlog.log 2>&1
vsim -c -lib mut/work tb_arb_rr -do "run -all; quit -f" > mut/vsim.log 2>&1
grep -a "load \|accepted\|err=\|samples\|PASS\|FAIL\|HANG\|_ERR" mut/vsim.log | head -20
