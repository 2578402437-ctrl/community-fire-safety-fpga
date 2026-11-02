# 第二版模型：三角牌只闪边框环带（外三角-内三角）+ 标题矩形压暗；亮相加屏幕四周红框
from PIL import Image
M=6; KNEE=16; S=2; BORDER=16; RED=(255,0,0)
# xc, ya, yt, yb, K, W(内缩), yb_in(内三角止行), 标题矩形
P={'SW1':(320,39,52,318,32,16,298,(150,330,492,392)),
   'SW2':(317,78,66,316,36,12,296,(165,325,475,381)),
   'SW3':(320,46,56,344,31,18,302,(90,360,552,416)),
   'SW12':(320,15,6,326,38,10,314,(176,333,466,373))}
def region(p,x,y):
    xc,ya,yt,yb,K,W,ybi,(x0,y0,x1,y1)=p
    dy=max(y-ya,0); base=(dy*K)>>6
    outer = yt<=y<=yb and abs(x-xc)<=base+M
    inner = y<=ybi and base>W and abs(x-xc)<=base-W
    return (outer and not inner) or (x0<=x<x1 and y0<=y<y1)
f=lambda c: c if c<KNEE else KNEE+((c-KNEE)>>S)
def border(x,y): return x<BORDER or x>=640-BORDER or y<BORDER or y>=480-BORDER
if __name__=='__main__':
    for n,p in P.items():
        im=Image.open('C:/Users/guang/Desktop/%s.bmp'%n).convert('RGB'); a=im.load()
        br=im.copy(); b=br.load(); dk=im.copy(); d=dk.load(); dbg=im.copy(); g=dbg.load()
        for y in range(480):
            for x in range(640):
                if border(x,y): b[x,y]=RED
                if region(p,x,y):
                    r,gg,bb=a[x,y]; d[x,y]=(f(r),f(gg),f(bb))
                    if not (region(p,x-1,y) and region(p,x+1,y) and region(p,x,y-1) and region(p,x,y+1)): g[x,y]=(0,255,0)
        c=Image.new('RGB',(1280,480)); c.paste(br,(0,0)); c.paste(dk,(640,0)); c.save('%s_cmp2.png'%n); dbg.save('%s_dbg2.png'%n)
    print('ok')
