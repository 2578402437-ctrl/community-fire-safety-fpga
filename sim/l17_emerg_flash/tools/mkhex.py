import sys
from PIL import Image
out=sys.argv[1]
for i,n in enumerate(['SW1','SW2','SW3','SW12']):
    im=Image.open('C:/Users/guang/Desktop/%s.bmp'%n).convert('RGB')
    with open(out+'/img%d.hex'%i,'w') as f:
        for r,g,b in im.getdata(): f.write('%02x%02x%02x\n'%(r,g,b))
print('hex ok')
