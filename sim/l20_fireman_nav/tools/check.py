# -*- coding: utf-8 -*-
"""比对 state.txt / pix_out.txt 与 nav_model，并导出若干预览图。"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import nav_model as M  # noqa: E402

d = Path(sys.argv[1]); prev = Path(sys.argv[2]); prev.mkdir(exist_ok=True)
ROWS = 100
roms = M.load_roms()
sched = [int(l, 16) for l in (d / "sched.hex").read_text().split()]
N = len(sched)
nav, sub = M.Nav(), M.Sub(roms[3])
states = {}
for f in range(0, N + 1):
    en, tg = (1, 0) if f == 0 else ((sched[f - 1] >> 2) & 1, sched[f - 1] & 3)
    cur_old = nav.cur
    sub.frame_start(en, cur_old)
    nav.frame_start(en, tg)
    states[f] = ((nav.en, nav.tgt, nav.pos, nav.face, nav.walk, nav.step, nav.cur, sub.en, sub.sent, sub.scroll),
                 (vars(nav).copy(), {k: v for k, v in vars(sub).items() if k != 'tab'}))

err = 0
nstate = 0
for line in (d / "state.txt").read_text().split("\n"):
    if not line.strip():
        continue
    v = [int(t) for t in line.split()]
    f = v[0]
    exp = states[f][0]
    nstate += 1
    if tuple(v[1:]) != exp:
        err += 1
        if err < 10:
            print("状态失配 帧%d DUT=%s 模型=%s" % (f, v[1:], exp))
print("状态比对 %d 帧，失配 %d" % (nstate, err))

# 像素
from PIL import Image  # noqa: E402
txt = (d / "pix_out.txt").read_text().split("\n")
i = 0; nfr = 0; perr = 0
saved = 0
while i < len(txt):
    if not txt[i].startswith("F "):
        i += 1; continue
    f = int(txt[i][2:]); i += 1
    rows = [[int(r[k:k + 6], 16) for k in range(0, 3840, 6)] for r in txt[i:i + ROWS]]
    i += ROWS
    ns, ss = states[f][1]
    n2, s2 = M.Nav(), M.Sub(roms[3])
    n2.__dict__.update(ns); s2.__dict__.update(ss)
    exp = M.render(n2, s2, roms, ROWS)
    bad = sum(1 for y in range(ROWS) for x in range(640) if rows[y][x] != exp[y][x])
    nfr += 1
    if bad:
        perr += 1
        print("像素失配 帧%d：%d 个" % (f, bad))
    if f in (637, 642, 761, 813, 1091, 1346) or (saved < 3 and f > 20):
        im = Image.new("RGB", (640, ROWS))
        for y in range(ROWS):
            for x in range(640):
                c = rows[y][x]; im.putpixel((x, y), (c >> 16, (c >> 8) & 255, c & 255))
        im.resize((1280, ROWS * 2), Image.NEAREST).save(prev / ("frame_%04d.png" % f))
        saved += 1
print("像素比对 %d 帧，失配帧 %d" % (nfr, perr))
print("PASS" if err == 0 and perr == 0 and nfr > 0 and nstate == N else "FAIL")
