# Python 位精确模型：逐 tick 复算目标增益/平滑增益/输出，与 RTL 比对；并检查收敛与输出范围
import sys
Q=[307,445,602,778,971,1181,1408,1649,1906,2178,2464,2763,3077,3404,3743,4096]
rows=[list(map(int,l.split())) for l in open('rtl_out.txt')]
g=4096; err=0; mx=0; mn=0
for n,(L,fa,s,fp,g_rtl,o_rtl) in enumerate(rows):
    t=((fa+(fa>>7))*Q[L]+128)>>8
    d=t-g; st=d>>6
    if st==0: st=(d>0)-(d<0)
    g=g+st
    o=(s*g+fp*Q[L]+16)>>5
    mx=max(mx,o); mn=min(mn,o)
    if g!=g_rtl or o!=o_rtl:
        err+=1
        if err<5: print("不一致", n, L, fa, s, fp, g, g_rtl, o, o_rtl)
print("样本", len(rows), "不一致", err, "输出范围", mn, mx, "24位内" if -2**23<=mn and mx<2**23 else "越界")
# 收敛：0dB→最低档 与 最低档→0dB 所需样本数
for a,b in ((4096,307),(307,4096),(4096,2048)):
    g=a; n=0
    while g!=b:
        d=b-g; st=d>>6
        if st==0: st=(d>0)-(d<0)
        g+=st; n+=1
    print(f"{a}->{b}: {n} 样本 ({n/48:.1f} ms)")
