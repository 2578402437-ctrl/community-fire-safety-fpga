#!/bin/sh
# 一键快速编译：命令行综合 → 多个布局种子并行布局布线 → 自动挑时序最好的放进 best_result
#
# 用法（Git Bash，任意目录）：
#   sh fast_build.sh              综合 + 默认种子 30 60 0 40
#   sh fast_build.sh 30 60 10     综合 + 指定种子
#   sh fast_build.sh -p 30 60     跳过综合，直接用上次 fast_syn 的结果跑布局布线
#
# 说明：
#   - 不动 TD 自己的 syn_1/phy_1 和 .al，TD 开着也可以跑；工作目录为 Runs/fast_syn、Runs/fast_s<N>
#   - 源文件清单取自 syn_1 的 .prj（TD 上次综合时生成）；新增/删除 .v 后须先在 TD 里综合一次
#   - 只选 SWNS、HWNS 都 ≥0 的种子；原 best_result 先备份到 Runs/best_result_prev/
cd "$(dirname "$0")/HDMI1.4b_Transmitter_v1.0_Runs" || exit 1
TDP=C:/Anlogic/TD_6.2.1_Engineer_6.2.168.116/bin/td_commands_prompt.exe
PRJ=HDMI1.4b_Transmitter_v1.0
T0=$(date +%s)

SKIP_SYN=0
if [ "$1" = "-p" ]; then SKIP_SYN=1; shift; fi
SEEDS="$*"
[ -z "$SEEDS" ] && SEEDS="30 60 0 40"

# 源文件清单是否过期：.al 比 syn_1 的 .prj 新，说明 TD 里改过工程（如新增文件）但还没综合
if [ ../$PRJ.al -nt syn_1/$PRJ.prj ]; then
    echo "【停止】工程文件 .al 比 syn_1 的源文件清单新（可能新增/删除了 .v）。"
    echo "        请先在 TD 里跑一次综合（Synthesize），再运行本脚本。"
    exit 1
fi

# ---------- 1. 综合 ----------
if [ $SKIP_SYN -eq 0 ]; then
    echo "[$(date +%H:%M:%S)] 综合开始"
    rm -rf fast_syn; mkdir fast_syn
    cp syn_1/$PRJ.prj syn_1/$PRJ.tcl syn_1/settings.cfg fast_syn/
    (cd fast_syn && "$TDP" $PRJ.tcl > run.log 2>&1)
    if [ ! -f fast_syn/${PRJ}_gate.db ] || grep -a -q " ERROR" fast_syn/run.log; then
        echo "【综合失败】错误如下（完整日志 Runs/fast_syn/run.log）："
        grep -a " ERROR" fast_syn/run.log | head -20
        exit 1
    fi
    echo "[$(date +%H:%M:%S)] 综合完成"
elif [ ! -f fast_syn/${PRJ}_gate.db ]; then
    echo "【停止】没有 fast_syn 综合结果，去掉 -p 重新运行"; exit 1
fi

# ---------- 2. 多种子并行布局布线 ----------
echo "[$(date +%H:%M:%S)] 布局布线开始，种子：$SEEDS（并行）"
for s in $SEEDS; do
    d=fast_s$s; rm -rf $d; mkdir $d
    cp phy_1/$PRJ.prj phy_1/$PRJ.tcl phy_1/settings.cfg $d/
    sed -i 's#^set parent .*#set parent ../fast_syn#' $d/settings.cfg
    echo "set phyWildParams {flow enable_seed on place seed $s}" >> $d/settings.cfg
    (cd $d && "$TDP" $PRJ.tcl > run.log 2>&1) &
done
wait

# ---------- 3. 挑选并放入 best_result ----------
BEST=""; BEST_W=-999
for s in $SEEDS; do
    ts=fast_s$s/${PRJ}_phy.ts
    if [ ! -f fast_s$s/$PRJ.bit ] || [ ! -f $ts ]; then
        echo "  种子 $s：失败（$(grep -a ' ERROR' fast_s$s/run.log | head -1 | cut -c1-60)）"
        continue
    fi
    sw=$(sed -n 's/.*SWNS: *\(-\{0,1\}[0-9.]*\)ns.*/\1/p' $ts)
    hw=$(sed -n 's/.*HWNS: *\(-\{0,1\}[0-9.]*\)ns.*/\1/p' $ts)
    echo "  种子 $s：建立 SWNS ${sw} ns，保持 HWNS ${hw} ns"
    if awk "BEGIN{exit !($sw >= 0 && $hw >= 0 && $sw > $BEST_W)}"; then BEST=$s; BEST_W=$sw; fi
done

T1=$(date +%s)
if [ -z "$BEST" ]; then
    echo "【没有时序通过的种子】best_result 未改动。可换种子重跑：sh fast_build.sh -p 10 20 50 70"
    echo "总用时 $((T1-T0)) 秒"
    exit 1
fi
rm -rf best_result_prev; cp -rp best_result best_result_prev
cp -p fast_s$BEST/$PRJ.bit fast_s$BEST/${PRJ}_inst.bid fast_s$BEST/${PRJ}_phy.ts best_result/
echo "The implemented result of fast_s$BEST (place seed $BEST, built by fast_build.sh $(date '+%m-%d %H:%M')) is saved as best result." > best_result/readMe.txt
grep -a -E "^#(lut|reg|bram|dsp) " fast_s$BEST/${PRJ}_phy.area | sed 's/^/  /'
echo "【完成】已采用种子 $BEST，bit 在 Runs/best_result/$PRJ.bit（原 bit 备份在 Runs/best_result_prev/）"
echo "总用时 $((T1-T0)) 秒"
