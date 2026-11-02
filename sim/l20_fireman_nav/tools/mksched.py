# -*- coding: utf-8 -*-
"""生成 sched.hex：每帧 {dump, enable, target}。"""
import sys
N = 1400
en = [1] * N
tg = [0] * N
def seg(a, b, t):
    for f in range(a, min(b, N)):
        tg[f] = t
seg(10, 200, 1)      # 0→1 向右
seg(200, 380, 2)     # 1→2
seg(380, 560, 3)     # 2→3
seg(560, 740, 0)     # 3→0 从右边走出、左边走进
seg(740, 920, 3)     # 0→3 向左（镜像，从左边走出右边走进）
seg(920, 1260, 1)    # 3→1 相隔两格，向右走两格（经过右边界）
tg[1260] = 2         # 单帧毛刺：应被两次一致采样滤掉
seg(1261, 1270, 1)
seg(1270, 1300, 2)   # 隐藏期间换目标：应直接落位
for f in range(1275, 1290):
    en[f] = 0
seg(1300, 1340, 0)   # 1→... 向左走一段
seg(1340, N, 1)      # 中途改回1：掉头
dump = [0] * N
for f in range(0, N, 17):
    dump[f] = 1
for c in (636, 641, 650, 735, 760, 812, 818, 1090, 1095, 1276, 1291, 1345):
    for f in range(c - 2, c + 2):
        dump[f] = 1
with open(sys.argv[1], "w") as fo:
    for f in range(N):
        fo.write("%x\n" % ((dump[f] << 3) | (en[f] << 2) | tg[f]))
print("dump frames:", sum(dump))
