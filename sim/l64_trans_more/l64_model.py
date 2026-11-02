# -*- coding: utf-8 -*-
"""新增 5 种转场的定点模型（按 RTL 公式逐像素计算）+ 预览

kind（4 位）：0 交叉淡化 1 中间往两边 3 轮子 4 圆形光圈 5 燃烧（原有，不在此建模）
  6 方块溶解：16×16 块哈希 t < q
  7 横百叶窗：(y & 31) < q>>3
  8 菱形光圈：|u|+|v| < R，R = 4q + q>>2 + q>>3（u=2x-639、v=479-2y，半像素单位）
  9 五角星光圈：5 条直线 n_k·p < d 围成，至多违反 1 条即在星内；d = q²>>6，
     n_k 角度 = q>>2 + 64 + round(51.2k)（256=一周，64=正上），sin/cos 用轮子的四分之一周期表（×256）；
     星外 G 内（至多违反 1 条 n_k·p < d+G）为金色光带：A 向金色按 kg = m + m>>1（m=min(q,256-q)）混合
  10 卷帘：卷筒底边 edge = 516 - (2q + q>>1 - q>>6)（行）；edge-36 ≤ y < edge 为卷筒（A 按行查表变暗/提亮），
     y ≥ edge 为 B（紧贴卷筒下方按行查表压暗做投影），其余为 A
混合一律 A + ((T-A)*k)>>8（与交叉淡化共用乘法器的写法，>>8 为算术移位）。
用法：python -I l64_model.py preview <旧图> <新图> <输出目录>
      python -I l64_model.py tables            打印卷帘查表（写进 RTL）
"""
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image

W, H = 640, 480
Y, X = np.mgrid[0:H, 0:W].astype(np.int64)
U, V = 2 * X - 639, 479 - 2 * Y
GOLD = (255, 215, 110)
STAR_G = 24                       # 光带宽（半像素）
ROLL_R2 = 36                      # 卷筒高（行）
ROLL_SH_N = 64                    # 投影表长度（行）


def sin_tab(i):
    return round(256 * math.sin(2 * math.pi * i / 256))


def sin_full(a):
    a &= 255
    m = sin_tab(64 - (a & 63)) if a & 64 else sin_tab(a & 63)
    return -m if a & 128 else m


def roll_tables():
    """卷筒段（36 行）与投影（64 行）：返回 [(白=1/黑=0, k)]，按 128 灰度把预览公式折成单次混合"""
    band = []
    for e in range(ROLL_R2):
        u = (e + 0.5) / ROLL_R2
        f = 0.85 * (0.55 + 0.75 * math.sin(math.pi * u) ** 1.5)
        h = math.exp(-((u - 0.35) / 0.08) ** 2) * 0.35
        g = 128 * f
        g = g + (255 - g) * h
        band.append((1, min(256, round((g - 128) / 127 * 256))) if g >= 128 else (0, round((128 - g) / 128 * 256)))
    shadow = [round(0.45 * math.exp(-d / 14) * 256) for d in range(ROLL_SH_N)]
    return band, shadow


def mixk(a, t, k):
    """A + ((T-A)*k) >> 8，逐通道，k 可为标量或 HxW"""
    k = np.asarray(k, dtype=np.int64)
    if k.ndim == 2:
        k = k[..., None]
    return a + (((t - a) * k) >> 8)


def frame(a, b, kind, q):
    a = a.astype(np.int64)
    b = b.astype(np.int64)
    y = Y
    if kind == 6:
        idx = (y >> 4) * 40 + (X >> 4)
        x1 = (idx * 0x9E5) & 0xFFF
        x2 = x1 ^ (x1 >> 6)
        t = ((x2 * 0x5A3) & 0xFFF) >> 4
        return np.where((t < q)[..., None], b, a)
    if kind == 7:
        return np.where(((y & 31) < (q >> 3))[..., None], b, a)
    if kind == 8:
        r = 4 * q + (q >> 2) + (q >> 3)
        return np.where((abs(U) + abs(V) < r)[..., None], b, a)
    if kind == 9:
        d = (q * q) >> 6
        ang = q >> 2
        viol = np.zeros((H, W), np.int64)
        violg = np.zeros((H, W), np.int64)
        for k in range(5):
            al = ang + 64 + (0, 51, 102, 154, 205)[k]
            acc = U * sin_full(al + 64) + V * sin_full(al)
            viol += acc >= (d << 8)
            violg += acc >= ((d + STAR_G) << 8)
        star = viol <= 1
        band = (~star) & (violg <= 1)
        m = min(q, 256 - q)
        kg = m + (m >> 1)
        out = np.where(star[..., None], b, a)
        g = mixk(a, np.array(GOLD), kg)
        return np.where(band[..., None], g, out)
    if kind == 10:
        band_t, shadow_t = roll_tables()
        edge = 516 - (2 * q + (q >> 1) - (q >> 6))
        out = a.copy()
        for yy in range(H):
            e = yy - (edge - ROLL_R2)
            if 0 <= e < ROLL_R2:
                white, k = band_t[e]
                out[yy] = mixk(a[yy], np.array((255, 255, 255) if white else (0, 0, 0)), k)
            elif e >= ROLL_R2:
                dy = yy - edge
                k = shadow_t[dy] if dy < ROLL_SH_N else 0
                out[yy] = mixk(b[yy], np.array((0, 0, 0)), k)
        return out
    raise ValueError(kind)


def q_seq(n=90):
    return [round(256 * (3 * (r / n) ** 2 - 2 * (r / n) ** 3)) for r in range(n + 1)]


def preview(fa, fb, outdir):
    a = np.asarray(Image.open(fa).convert("RGB").resize((W, H)))
    b = np.asarray(Image.open(fb).convert("RGB").resize((W, H)))
    out = Path(outdir)
    out.mkdir(parents=True, exist_ok=True)
    names = {6: "溶解", 7: "横百叶窗", 8: "菱形光圈", 9: "五角星光圈", 10: "卷帘"}
    sheet = Image.new("RGB", (W // 2 * 4, H // 2 * 5))
    for row, kind in enumerate(names):
        qs = q_seq()
        frames = [Image.fromarray(np.clip(frame(a, b, kind, q), 0, 255).astype(np.uint8)) for q in qs[::2]]
        frames[0].save(out / f"{kind}_{names[kind]}.gif", save_all=True, append_images=frames[1:],
                       duration=33, loop=0)
        for col, q in enumerate((40, 100, 160, 220)):
            im = Image.fromarray(np.clip(frame(a, b, kind, q), 0, 255).astype(np.uint8)).resize((W // 2, H // 2))
            sheet.paste(im, (col * W // 2, row * H // 2))
        e0 = frame(a, b, kind, 0)
        e1 = frame(a, b, kind, 256)
        print(f"kind {kind} {names[kind]}: q=0 等于A {np.array_equal(e0, a)}，q=256 等于B {np.array_equal(e1, b)}")
    sheet.save(out / "sheet_q40_100_160_220.png")


if __name__ == "__main__":
    if sys.argv[1] == "preview":
        preview(sys.argv[2], sys.argv[3], sys.argv[4])
    elif sys.argv[1] == "tables":
        bt, st = roll_tables()
        print("band", bt)
        print("shadow", st)
