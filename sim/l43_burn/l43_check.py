# 逐像素比对
# 用法：python -I l43_check.py params            生成 params.hex
#       python -I l43_check.py check new old     new=新RTL输出，old=旧RTL输出（同一params）
#   燃烧帧（kind=5）：与 l43_model 位精确比对；其余帧：新旧RTL逐字一致（交叉淡化/撕裂/轮子/光圈不受影响）
#   另查：燃烧 q=0 帧整屏等于A、q=256 帧整屏等于B
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import l43_model as M

# (act, kind, q)
PARAMS = [(0, 0, 0), (1, 0, 0), (1, 0, 128), (1, 0, 256), (1, 1, 100), (1, 3, 160), (1, 4, 90)]
PARAMS += [(1, 5, q) for q in (0, 1, 20, 50, 80, 110, 128, 150, 180, 210, 240, 255, 256)]
PARAMS += [(0, 5, 128), (1, 5, 128), (1, 4, 200), (1, 5, 64)]   # 燃烧帧之间穿插其他帧，查状态不残留
N = len(PARAMS)


def ab(x, y):
    a = (y & 255, x & 255, 0xA5)
    b = ((~x) & 255, (y ^ x) & 255, 0x3C)
    return a, b


def read_frames(path):
    with open(path) as f:
        lines = f.read().split('\n')
    lines = [l for l in lines if l]
    assert len(lines) == N * 480, (path, len(lines))
    return [lines[i * 480:(i + 1) * 480] for i in range(N)]


def main():
    if sys.argv[1] == 'params':
        with open('params.hex', 'w') as f:
            for act, kind, q in PARAMS:
                f.write('%04x\n' % ((act << 12) | (kind << 9) | q))
        print('N =', N)
        return
    new, old = read_frames(sys.argv[2]), read_frames(sys.argv[3])
    bad = 0
    for fi, (act, kind, q) in enumerate(PARAMS):
        if act and kind == 5:
            nb = 0
            for y in range(480):
                row = new[fi][y]
                for x in range(640):
                    a, b = ab(x, y)
                    exp = '%02x%02x%02x' % M.burn_px(a, b, q, x, y)
                    got = row[6 * x:6 * x + 6]
                    if got != exp:
                        if nb < 5:
                            print('frame %d q=%d (%d,%d) got %s exp %s' % (fi, q, x, y, got, exp))
                        nb += 1
                    if q == 0 and got != '%02x%02x%02x' % a:
                        nb += 1
                    if q == 256 and got != '%02x%02x%02x' % b:
                        nb += 1
            print('frame %2d burn q=%3d mismatches %d' % (fi, q, nb))
            bad += nb
        else:
            nb = sum(1 for y in range(480) if new[fi][y] != old[fi][y])
            print('frame %2d act=%d kind=%d q=%3d 与旧RTL不同的行 %d' % (fi, act, kind, q, nb))
            bad += nb
    print('PASS' if bad == 0 else 'FAIL %d' % bad)


if __name__ == '__main__':
    main()
