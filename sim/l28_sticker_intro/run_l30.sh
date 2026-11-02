#!/bin/sh
# 正左方水平走入，逐像素比对（短参数 + 真实行走参数）
PY=C:/Users/guang/AppData/Local/Programs/Python/Python311/python.exe
V=../../src/user_source/hdl_source/osd/fireman_intro_24.v
run() {  # $1=名字 $2=STAND $3=WALK $4=ARRIVE $5=BOOT_FROM $6=NFRAMES $7=DUMP_MOD
  rm -rf work_$1; vlib work_$1 >/dev/null
  vlog -work work_$1 +define+STAND=$2 +define+WALK=$3 +define+ARRIVE=$4 +define+BOOT_FROM=$5 +define+NFRAMES=$6 +define+DUMP_MOD=$7 tb_intro.v $V > l30_$1.vlog.txt 2>&1
  vsim -c -lib work_$1 -do "run -all; quit" tb > l30_$1.sim.txt 2>&1
  mv pix.txt pix_l30_$1.txt
  $PY -I make_l28_assets.py check pix_l30_$1.txt $2 $3 $4 $5 $6 > l30_$1.cmp.txt 2>&1
  tail -1 l30_$1.cmp.txt
}
run short 4 64 4 3 76 4
run full 16 192 16 40 240 11
