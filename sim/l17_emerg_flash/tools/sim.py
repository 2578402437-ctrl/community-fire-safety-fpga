# 紧急元素闪烁暗相模拟：三角形区域 + 标题矩形，区域内像素按 c<T?c:T+((c-T)>>S) 压暗
import sys
from PIL import Image, ImageDraw
T=int(sys.argv[1]) if len(sys.argv)>1 else 32
S=int(sys.argv[2]) if len(sys.argv)>2 else 2
M=6  # 三角形外扩余量（像素）
# 每张图：xc, ya(顶点y), yb(底边y), K(半宽斜率*64), 标题矩形(x0,y0,x1,y1) 右/下开区间
P={'SW1':(320,39,52,318,32,(150,330,492,392)),
   'SW2':(317,78,66,316,36,(165,325,475,381)),
   'SW3':(320,46,56,344,31,(90,360,552,416)),
   'SW12':(320,15,6,326,38,(176,333,466,373))}
def inside(p,x,y):
    xc,ya,yt,yb,K,(x0,y0,x1,y1)=p
    if yt<=y<=yb:
        dy=max(y-ya,0); hw=((dy*K)>>6)+M
        if xc-hw<=x<=xc+hw: return True
    return x0<=x<x1 and y0<=y<y1
f=lambda c: c if c<T else T+((c-T)>>S)
for n,p in P.items():
    im=Image.open('C:/Users/guang/Desktop/%s.bmp'%n).convert('RGB'); a=im.load()
    dk=im.copy(); d=dk.load(); dbg=im.copy(); g=dbg.load()
    for y in range(480):
        for x in range(640):
            if inside(p,x,y):
                r,gg,b=a[x,y]; d[x,y]=(f(r),f(gg),f(b))
                if not inside(p,x-1,y) or not inside(p,x+1,y) or not inside(p,x,y-1) or not inside(p,x,y+1): g[x,y]=(0,255,0)
    dk.save('C:/Users/guang/swsim/%s_dark.png'%n); dbg.save('C:/Users/guang/swsim/%s_dbg.png'%n)
    both=Image.new('RGB',(1280,480)); both.paste(im,(0,0)); both.paste(dk,(640,0)); both.save('C:/Users/guang/swsim/%s_cmp.png'%n)
print('ok')
