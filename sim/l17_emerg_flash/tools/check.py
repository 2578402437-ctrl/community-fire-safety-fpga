# 仿真输出与Python模型逐像素比对
import sys
sys.argv=[sys.argv[0],'16','2']
exec(open('tools/sim.py',encoding='utf-8').read().split('f=lambda')[0])  # 复用P/inside
f=lambda c: c if c<16 else 16+((c-16)>>2)
names=['SW1','SW2','SW3','SW12']; allok=True
for i,n in enumerate(names):
    src=[int(l,16) for l in open('img%d.hex'%i)]
    exp=[]
    for k,v in enumerate(src):
        x,y=k%640,k//640
        if inside(P[n],x,y):
            r,g,b=v>>16,(v>>8)&255,v&255; exp.append((f(r)<<16)|(f(g)<<8)|f(b))
        else: exp.append(v)
    res={}
    for tag,ref in (('bright',src),('dark',exp),('f6',src),('f8',src),('f9',src)):
        out=[int(l,16) for l in open('r%d/out_%s.hex'%(i,tag))]
        bad=sum(a!=b for a,b in zip(out,ref)); res[tag]=bad; allok&= bad==0
    changed=sum(a!=b for a,b in zip(src,exp))
    print(n,'失配像素',res,'暗相被压暗像素数',changed)
print('全部通过' if allok else '存在失配')
