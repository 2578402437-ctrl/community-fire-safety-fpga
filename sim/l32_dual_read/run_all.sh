#!/bin/sh
# 双路读三组回归，结果写 res_*.log
cd "$(dirname "$0")"
vsim -c -lib work_m1    -do "run -all; quit -f" tb_dual_read -voptargs=+acc > res_mix1_lat6.log  2>&1 &
vsim -c -lib work_m1l14 -do "run -all; quit -f" tb_dual_read -voptargs=+acc > res_mix1_lat14.log 2>&1 &
vsim -c -lib work_m0    -do "run -all; quit -f" tb_dual_read -voptargs=+acc > res_mix0_lat6.log  2>&1 &
wait
grep -a "RESULT" res_*.log
