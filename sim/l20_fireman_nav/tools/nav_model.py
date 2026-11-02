# -*- coding: utf-8 -*-
"""导航栏 + 分栏目字幕 位精确模型（按需求独立实现，ROM内容直接读生成的hex）。"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/convert"))
import make_nav_assets as A  # noqa: E402

ROMDIR = ROOT / "src/user_source/hdl_source/rom"
H = 640
CENTER = [80, 240, 400, 560]
PAL = {1: 0xD01818, 2: 0xFFC800, 3: 0xF5C08A, 4: 0x2A2A2A, 5: 0x101010, 6: 0x101010, 7: 0x101010}
SEL, LAB, TXT, NAV_BG = 0xD01818, 0x404040, 0xFFD200, 0xFFFFFF


def load_roms():
    spr = [int(l, 16) for l in (ROMDIR / "nav_sprite_4bit.hex").read_text().split()]
    lab = [int(l, 16) for l in (ROMDIR / "nav_label_1bit.hex").read_text().split()]
    gly = [int(l, 16) for l in (ROMDIR / "subtitle_glyph32.hex").read_text().split()]
    chars = []
    for s in A.SENTENCES:
        for ch in s:
            if ch not in chars:
                chars.append(ch)
    sent = [[chars.index(ch) for ch in s] for s in A.SENTENCES]
    halves = [(len(s) * A.LABEL_PITCH - (A.LABEL_PITCH - A.LABEL_GLYPH)) // 2 for s in A.LABELS]
    return spr, lab, gly, sent, halves


class Nav:
    def __init__(s):
        s.en = 0; s.tgt_q = 0; s.tgt = 0; s.pos = 80; s.face = 0; s.walk = 0; s.step = 0; s.cur = 0

    def frame_start(s, enable, target):
        tx = CENTER[s.tgt]
        old_tgt, old_tq = s.tgt, s.tgt_q
        s.en = enable
        s.tgt_q = target
        if target == old_tq:
            s.tgt = target
        if not enable:
            s.pos = tx; s.cur = old_tgt; s.walk = 0; s.face = 0
        elif s.pos == tx:
            s.cur = old_tgt; s.walk = 0
        else:
            s.walk = 1
            s.step = (s.step + 1) % 32
            right = ((tx - s.pos) % H) <= H // 2
            s.face = 0 if right else 1
            s.pos = (s.pos + (1 if right else -1)) % H


class Sub:
    def __init__(s, sent):
        s.en = 0; s.sent = 0; s.scroll = 0; s.tab = sent

    def frame_start(s, enable, sentence):
        smax = H + len(s.tab[s.sent]) * 32
        if not enable or sentence != s.sent:
            s.scroll = 0
        elif s.scroll + 2 >= smax:
            s.scroll = 0
        else:
            s.scroll += 2
        s.en = enable
        s.sent = sentence


def half_rgb(c):
    return ((c >> 1) & 0x7F7F7F)


def rgb_in(x, y):
    return (((y & 255) ^ 0x5A) << 16) | ((x & 255) << 8) | (((x >> 8) & 3) << 6) | (y & 63)


def render(nav, sub, roms, rows):
    spr, lab, gly, sent, halves = roms
    out = []
    anim = [0, 1, 2, 1][nav.step >> 3] if nav.walk else 3   # 行走 0→1→2→1，站立用正面帧3
    for y in range(rows):
        line = []
        for x in range(H):
            c = rgb_in(x, y)
            if nav.en and y < 52:
                o = NAV_BG
                done = False
                if 2 <= y < 34:
                    sx = (x + 12 - nav.pos) % H
                    if sx < 24:
                        col = 23 - sx if nav.face else sx
                        code = spr[(anim << 10) | ((y - 2) << 5) | col] & 7
                        if code:
                            o = PAL[code]; done = True
                if not done and 34 <= y < 50:
                    w = lab[((y - 34) << 6) | (x >> 4)]
                    if (w >> (15 - (x & 15))) & 1:
                        o = SEL if (x // 160) == nav.cur else LAB
                        done = True
                if not done and 50 <= y < 52:
                    cc, hh = CENTER[nav.cur], halves[nav.cur]
                    if cc - hh <= x < cc + hh:
                        o = SEL
                c = o
            if sub.en and 52 <= y < 92:
                o = half_rgb(c)
                if 56 <= y < 88:
                    tx = x + sub.scroll - H
                    if 0 <= tx < len(sent[sub.sent]) * 32:
                        g = gly[sent[sub.sent][tx >> 5] * 32 + (y - 56)]
                        if (g >> (31 - (tx & 31))) & 1:
                            o = TXT
                c = o
            line.append(c)
        out.append(line)
    return out
