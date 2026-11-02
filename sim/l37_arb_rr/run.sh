#!/bin/sh
# 用法: sh run.sh new|old [额外vlog define]
cd "$(dirname "$0")"
py=C:/Users/guang/AppData/Local/Programs/Python/Python311/python.exe
H=../../src/user_source/hdl_source
V=$1; shift
mkdir -p $V
if [ "$V" = old ]; then SRC=$H/sd/sd_card_bmp_v2.v.bak_l37_20261017; DEF=+define+OLD_ARB; else SRC=$H/sd/sd_card_bmp_v2.v; DEF=; fi
$py -I extract_arb.py $SRC $V/arb_chunk.vh
rm -rf $V/work; vlib $V/work >/dev/null
vlog -work $V/work +incdir+$V $DEF "$@" $H/sd/sd_sector_adapter.v $H/sd/fat32_file_streamer.v $H/audio/wav_stream_player.v tb_arb_rr.v > $V/vlog.log 2>&1
grep -a "Error\|Errors:" $V/vlog.log | head
vsim -c -lib $V/work tb_arb_rr -do "run -all; quit -f" > $V/vsim.log 2>&1
grep -a "load \|RESULT\|accepted\|err=\|samples\|PASS\|FAIL\|HANG\|_ERR" $V/vsim.log | head -40
