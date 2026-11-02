#!/bin/sh
# 顶层展开：按 top_list.txt 逐个编译 + IP 空壳，vsim 加载 top 检查端口连接
cd "$(dirname "$0")"
INC=../../src/user_source/hdl_source/include
rm -rf work_top; vlib work_top >/dev/null
: > vlog_top.log
while read f; do
  [ -z "$f" ] && continue
  # 开机动画ROM路径相对TD工程目录，展开检查不需要内容
  vlog -sv -work work_top +incdir+$INC "$f" >> vlog_top.log 2>&1
done < top_list.txt
vlog -sv -work work_top ../l20_fireman_nav/stubs.v >> vlog_top.log 2>&1
grep -a "Error" vlog_top.log | head
vsim -c -lib work_top work_top.top -do "quit -f" > elab.log 2>&1
grep -a -c "Warning" elab.log
grep -a "Error\|Errors:" elab.log | head
