# -*- coding: utf-8 -*-
"""开机动画：侧身慢走 → 转正面边走边挥手 → 转回侧身继续往右走 → 到位交接 PIC1（定点模型 + 预览）

相对侧身直线走入的行走方式：
  - 行走 WALK_N=360 帧（约6.0 s，与开机问候语音等长），速度约为原来的一半，脚步节奏不变（每32帧一步）；
  - 第 0~FRONT_T0-1 帧侧身（迈步/并腿交替），FRONT_T0~FRONT_T1-1 帧换正面图原地站定挥手（不移动、不颠动、无脚步声；用户 10-20：打招呼时人不要移动），
    之后转回侧身继续往右走到终点；
  - 正面阶段挥手：举起的前臂和手按行左右错切（以肘部 PIVOT 行为轴），每行偏移
        dx = (s * (PIVOT - row)) >> 5，s = 挥手表[(t-FRONT_T0) & 31]（0..WAVE_A，只向外摆，不压到脸）
    错切区：第 TOP1~TOP2-1 行只动 SPLIT1 列以右（手顶白边，避开耳朵），第 TOP2~PIVOT 行动 SPLIT2 列以右；
    偏移后空出的列取 SPLIT 列本身的像素（拉伸），不露背景；
  - 到位（ARRIVE）与之后的交接、背景图模式与侧身直线走入方式相同。
不占新 ROM：正面图、侧身图都用原 ROM。
用法：python -I l63_model.py preview <输出目录>
"""
import math
import sys
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "l28_sticker_intro"))
import make_l28_assets as m28  # noqa: E402

W, H, BG = m28.W, m28.H, m28.BG
STAND_N, WALK_N, ARRIVE_N = 180, 368, 16   # 368帧≈6.13s，与问候语音（含换曲延迟）对齐
FRONT_T0, FRONT_T1 = 120, 248             # 正面挥手帧段（128帧=4次挥手，结束时手回原位）
BOB = m28.BOB
LEG_Y, LEG_SPLIT = m28.LEG_Y, m28.LEG_SPLIT
X_TGT, Y_TGT, AY0 = 456, 217, 458
FRONT_HALF = 82                       # 正面图脚底中心 = x0 + 82（164/2）
MOVE_N = WALK_N - 1 - (FRONT_T1 - FRONT_T0)   # 实际移动的帧数（正面挥手期间不动）
VX = 41                               # Q4 像素/帧（约2.56像素/帧）
AX0 = X_TGT + FRONT_HALF - (MOVE_N * VX >> 4)   # 使终点正好落在到位位置
# 挥手错切区
TOP1, SPLIT1 = 96, 142
TOP2, SPLIT2 = 103, 120
PIVOT = 140
WAVE_A = 6
WAVE = [round(WAVE_A * (1 - math.cos(2 * math.pi * k / 32)) / 2) for k in range(32)]


def frame_states(boot_from, nframes):
    """(状态, t, px, 脉冲, 侧)；状态 0=站立 1=行走 3=到位 2=结束"""
    st, s_cnt, t, px, a = 0, 0, 0, 0, 0
    out = []
    for n in range(1, nframes + 1):
        pulse, side = 0, 0
        if st == 0:
            if s_cnt == STAND_N:
                if n >= boot_from:
                    st, t, px, pulse, side = 1, 0, 0, 1, 0
            else:
                s_cnt += 1
        elif st == 1:
            if t == WALK_N - 1:
                st, a, pulse = 3, 0, 1
            else:
                nf = FRONT_T0 <= t + 1 < FRONT_T1          # 下一帧是正面挥手（原地站定）
                if t + 1 == FRONT_T0:
                    pulse, side = 1, 0 if (t >> 5) & 1 else 1   # 站定，出一声立定脚步
                elif t & 31 == 31 and not nf:
                    pulse, side = 1, 0 if (t >> 5) & 1 else 1
                t += 1
                if not nf:
                    px += VX
        elif st == 3:
            if a == ARRIVE_N - 1:
                st = 2
            else:
                a += 1
        out.append((st, t, px, pulse, side))
    return out


def wave_dx(t, row):
    s = WAVE[(t - FRONT_T0) & 31]
    return (s * (PIVOT - row)) >> 5


def render(state, p, words, under):
    st, t, px_ = state[:3]
    info, pal, white = p["info"], p["palette"], p["white"]
    if st == 2:
        return under
    img = Image.new("RGB", (W, H), BG)
    if st == 0:
        return img
    px = img.load()
    ud = under.load()
    front = st == 3 or FRONT_T0 <= t < FRONT_T1
    name = "FRONT" if front else ("PASS" if t & 16 else "STEP")
    sw, sh, wpr, base_ = info[name]["w"], info[name]["h"], info[name]["wpr"], info[name]["base"]
    k = 1 if front else 2
    ax = AX0 + (px_ >> 4)
    if st == 3:
        x0, y0 = X_TGT, Y_TGT
    elif front:
        x0, y0 = ax - FRONT_HALF, Y_TGT
    else:
        x0, y0 = ax - sw, AY0 - 2 * sh - (BOB if name == "PASS" else 0)
    waving = st == 1 and front
    dark_front = (t >> 5) & 1
    for y in range(max(0, y0), min(H, y0 + k * sh)):
        ry = (y - y0) // k
        rb = base_ + ry * wpr
        split = SPLIT1 if TOP1 <= ry < TOP2 else SPLIT2 if TOP2 <= ry <= PIVOT else None
        dx = wave_dx(t, ry) if waving and split is not None else 0
        for x in range(max(0, x0), min(W, x0 + k * sw)):
            c = (x - x0) // k
            if dx and c >= split:
                c = max(c - dx, split)
            code = (words[rb + c // 3] >> (5 * (c % 3))) & 31
            if code < 2:
                continue
            if st == 3:
                px[x, y] = ud[x, y]
                continue
            col = tuple(pal[code - 2])
            if name == "STEP" and ry >= LEG_Y and ((c < LEG_SPLIT) != bool(dark_front)) and not white[code - 2]:
                col = tuple(v - (v >> 2) for v in col)
            px[x, y] = col
    return img


def preview(outdir, boot_at=20):
    p, words = m28.load_model()
    out = Path(outdir)
    out.mkdir(parents=True, exist_ok=True)
    under = Image.open(m28.SCENE).convert("RGB")
    states = frame_states(boot_at, STAND_N + 1 + WALK_N + ARRIVE_N + 30)
    gif = []
    w0 = STAND_N + 1          # 行走第0帧的帧号
    keys = {w0: "走0", w0 + 60: "侧身走", w0 + FRONT_T0 - 1: "侧身末帧", w0 + FRONT_T0: "转正面",
            w0 + FRONT_T0 + 16: "挥手_最外", w0 + FRONT_T1 - 1: "正面末帧", w0 + FRONT_T1: "转回侧身",
            w0 + 320: "侧身走2", w0 + WALK_N - 1: "行走末帧", w0 + WALK_N: "到位"}
    for i, s in enumerate(states):
        img = render(s, p, words, under)
        if i >= STAND_N - 30 and i % 2 == 0:
            gif.append(img.convert("P", palette=Image.Palette.ADAPTIVE, colors=128))
        if i + 1 in keys:
            img.save(out / f"frame_{i + 1:03d}_{keys[i + 1]}.png")
        if s[0] == 1 and (s[1] - FRONT_T0) in (0, 8, 16, 24):
            img.crop((max(0, AX0 + (s[2] >> 4) - 100), 180, min(W, AX0 + (s[2] >> 4) + 100), 470)) \
               .resize((400, 580), Image.Resampling.NEAREST).save(out / f"wave_zoom_ph{s[1] - FRONT_T0:02d}.png")
    gif[0].save(out / "intro_l63.gif", save_all=True, append_images=gif[1:], duration=33, loop=0)
    print("AX0", AX0, "终点脚底", AX0 + (MOVE_N * VX >> 4), "站定挥手处脚底", AX0 + ((FRONT_T0 - 1) * VX >> 4))
    print("挥手表", WAVE)
    print("脚步脉冲帧（相对行走第0帧）：", [i + 1 - w0 for i, s in enumerate(states) if s[3]])


if __name__ == "__main__":
    if sys.argv[1] == "preview":
        preview(sys.argv[2])
