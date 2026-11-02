# 双路合成逐像素比对
# 用法：python -I mix_check.py params | check
#   形状（1~5）：C(q)内应为B、其余为A（形状几何复用 l31_model，shape_in=1）
#   交叉淡化（0）：每通道 A + floor((B-A)*q/256)，按公式独立计算
#   act=0：整帧直通A
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'l31_shape_more'))
import l31_model as M  # noqa: E402

Q_LIST = [0, 1, 37, 64, 100, 128, 129, 192, 230, 255, 256]


def param_list():
    ps = [(0, 3, 128)]                      # 未激活：类型/比例任意也应直通A
    for kind in (0, 1, 2, 3, 4, 5):
        for q in Q_LIST:
            ps.append((1, kind, q))
    ps.append((0, 0, 200))
    ps.append((0, 5, 256))
    return ps


def a_of(x, y):
    return ((y & 255) << 16) | ((x & 255) << 8) | 0xA5


def b_of(x, y):
    return ((~x & 255) << 16) | (((y ^ x) & 255) << 8) | 0x3C


def blend(a, b, q):
    out = 0
    for sh in (16, 8, 0):
        ca, cb = (a >> sh) & 255, (b >> sh) & 255
        out |= (ca + (((cb - ca) * q) // 256)) << sh     # Python // 为向下取整，与 >>> 一致
    return out


def gen():
    ps = param_list()
    with open(os.path.join(HERE, 'params.hex'), 'w') as f:
        for act, kind, q in ps:
            f.write('%04x\n' % ((act << 12) | (kind << 9) | q))
    print('params ok, N =', len(ps))


def check():
    lines = open(os.path.join(HERE, 'mix_out.txt')).read().split()
    ps = param_list()
    assert len(lines) == len(ps) * M.H, (len(lines), len(ps) * M.H)
    total = 0
    for fi, (act, kind, q) in enumerate(ps):
        rows = lines[fi * M.H:(fi + 1) * M.H]
        bad = nb = 0
        for y in range(M.H):
            r = rows[y]
            if act and kind == 0:
                assert len(r) == M.W * 6
                for x in range(M.W):
                    got = int(r[6 * x:6 * x + 6], 16)
                    exp = blend(a_of(x, y), b_of(x, y), q)
                    if got != exp:
                        bad += 1
                    if got == b_of(x, y):
                        nb += 1
            else:
                assert len(r) == M.W, len(r)
                for x in range(M.W):
                    if act:
                        exp = 'b' if M.expect_code(kind, 1, q, x, y) else 'a'
                    else:
                        exp = 'a'
                    if r[x] != exp:
                        bad += 1
                    if r[x] == 'b':
                        nb += 1
        total += bad
        print('frame%3d act=%d kind=%d q=%3d  B_pixels=%6d  mismatch=%d' % (fi + 1, act, kind, q, nb, bad))
    print('TOTAL_MISMATCH', total)
    print('PASS' if total == 0 else 'FAIL')


if __name__ == '__main__':
    {'params': gen, 'check': check}[sys.argv[1]]()
