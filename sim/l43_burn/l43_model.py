# 燃烧纸张转场（自下而上）：位精确模型
# 噪声 = 两个八度的格点哈希值噪声（格距64、16）双线性插值，(3*o64 + o16)>>2，0~255
# 度量 m = (479-y) + 噪声/2，底部先烧；d = t - m，t = vis*19>>3
# d>=0 烧穿露出新图（128+32d 羽化），d<0 旧图向焦褐压暗（230+10d），d=-1 附近叠加火光
W, H = 640, 480
SEEDS = ((6, 0x135), (4, 0x7A9))
BROWN = (28, 14, 6)
GLOW = (255, 110, 20)
# t = vis*19/8：vis=0 时 t=0（全屏度量最小 39，连焦黑带都不出现），vis=256 时 t=608（最大 593，整屏烧穿）


def lat_hash(x1):
    x1 &= 0xFFF
    x2 = x1 ^ (x1 >> 6)
    return ((x2 * 0x5A3) & 0xFFF) >> 4


def octave(x, y, sh, seed):
    s = 1 << sh
    ncol = W // s + 1
    i, j, fx, fy = x >> sh, y >> sh, x & (s - 1), y & (s - 1)
    def c(ii, jj):
        return lat_hash((jj * ncol + ii) * 0x9E5 + seed)
    vl = c(i, j) + (((c(i, j + 1) - c(i, j)) * fy) >> sh)
    vr = c(i + 1, j) + (((c(i + 1, j + 1) - c(i + 1, j)) * fy) >> sh)
    return vl + (((vr - vl) * fx) >> sh)


def noise(x, y):
    return (3 * octave(x, y, *SEEDS[0]) + octave(x, y, *SEEDS[1])) >> 2


_NMAP = None


def nmap():
    global _NMAP
    if _NMAP is None:
        _NMAP = [[noise(x, y) for x in range(W)] for y in range(H)]
    return _NMAP


def clamp(x, lo=0, hi=256):
    return lo if x < lo else hi if x > hi else x


def thr(vis):
    return (vis * 19) >> 3


def kg(d):
    """返回 (取新图?, 权重k, 火光g)"""
    if d >= 0:
        neg, k = False, clamp(128 + 32 * d)
    else:
        neg, k = True, clamp(230 + 10 * d)
    g = clamp(255 - 40 * abs(d + 1), 0, 255)
    return neg, k, g


def burn_px(a, b, vis, x, y):
    d = thr(vis) - ((479 - y) + (nmap()[y][x] >> 1))
    neg, k, g = kg(d)
    tc = BROWN if neg else b
    out = []
    for ca, ct, cg in zip(a, tc, GLOW):
        v = ca + (((ct - ca) * k) >> 8)
        out.append(min(255, v + ((cg * g) >> 8)))
    return tuple(out)


if __name__ == '__main__':
    n = nmap()
    lo = min(min(r) for r in n); hi = max(max(r) for r in n)
    ms = [(479 - y) + (n[y][x] >> 1) for y in range(H) for x in range(W)]; m_lo, m_hi = min(ms), max(ms)
    print('noise', lo, hi, 'm', m_lo, m_hi, 't0', thr(0), 't256', thr(256))
    assert thr(0) <= m_lo - 24 and thr(256) >= m_hi + 7
