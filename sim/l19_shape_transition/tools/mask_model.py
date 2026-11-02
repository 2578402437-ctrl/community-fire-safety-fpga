# 形状转场遮罩：参数表 + 位精确模型 + 理想几何模型
import math

W, H = 640, 480
Q_LIST = [0, 1, 37, 64, 100, 128, 129, 192, 230, 255, 256]


def param_list():
    """返回每个检查帧的 (kind, in, q)，顺序即 params.hex 行序"""
    ps = [(0, 1, 128)]
    for kind in (1, 2, 3):
        for s_in in (0, 1):
            for q in Q_LIST:
                ps.append((kind, s_in, q))
    ps.append((0, 0, 200))
    return ps


SIN_TAB = [round(256 * math.sin(2 * math.pi * i / 256)) for i in range(65)]


def sin_full(a):
    a &= 0xFF
    idx = a & 63
    m = SIN_TAB[64 - idx] if (a >> 6) & 1 else SIN_TAB[idx]
    return -m if a >> 7 else m


def covered_hw(kind, q, x, y):
    """与RTL一致的整数算法"""
    dist = 319 - x if x < 320 else x - 320
    half_w = q + (q >> 2)
    if kind == 1:
        return dist < half_w
    if kind == 2:
        return dist + half_w >= 320
    if q >= 256:
        return True
    ang = q & 0xFF
    s, c = sin_full(ang), sin_full(ang + 64)
    cross = (2 * x - 639) * c - (479 - 2 * y) * s
    u_pos = x >= 320
    return (u_pos or cross < 0) if ang >= 128 else (u_pos and cross < 0)


def covered_ideal(kind, q, x, y):
    """理想几何：撕裂按连续半宽，轮子按精确角度（像素中心）"""
    dx, dy = x + 0.5 - 320, y + 0.5 - 240
    half_w = 320.0 * q / 256
    if kind == 1:
        return abs(dx) < half_w
    if kind == 2:
        return abs(dx) >= 320 - half_w
    phi = math.atan2(dx, -dy) % (2 * math.pi)     # 自12点顺时针
    return phi < 2 * math.pi * q / 256


def expect_code(kind, s_in, q, x, y, cov=covered_hw):
    if kind == 0:
        return 1
    c = cov(kind, q, x, y)
    vis = c if s_in else not c
    return 1 if vis else 0
