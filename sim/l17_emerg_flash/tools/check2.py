# 比对：亮相=原图+四周红框，暗相=三角边框环带+标题压暗、无红框
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim2 import P, region, f, border
names=['SW1','SW2','SW3','SW12']; allok=True
for i,n in enumerate(names):
    src=[int(l,16) for l in open('img%d.hex'%i)]
    brt=[]; drk=[]
    for k,v in enumerate(src):
        x,y=k%640,k//640
        brt.append(0xFF0000 if border(x,y) else v)
        if region(P[n],x,y):
            r,g,b=v>>16,(v>>8)&255,v&255; drk.append((f(r)<<16)|(f(g)<<8)|f(b))
        else: drk.append(v)
    res={}
    # f6：换图后亮相（新图编号对应的区域无关，亮相只有红框）
    for tag,ref in (('bright',brt),('dark',drk),('f6',brt),('f8',src),('f9',src)):
        out=[int(l,16) for l in open('r%d/out_%s.hex'%(i,tag))]
        bad=sum(a!=b for a,b in zip(out,ref)); res[tag]=bad; allok&= bad==0
    print(n,'mismatch',res,'dimmed',sum(a!=b for a,b in zip(src,drk)))
print('ALL PASS' if allok else 'FAIL')
