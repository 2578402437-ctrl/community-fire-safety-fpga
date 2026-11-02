# -*- coding: utf-8 -*-
"""SD卡故障提示图 → 片上ROM数据（320×240 单色位图）生成脚本。

显示端 SD/sd_fallback_overlay_24.v 在视频输出末端按 2×2 放大成 640×480 叠加，
SD卡识别不到时整屏显示这张图。不经过SDRAM帧缓存，不占用写端口。

图片要求：640×480 的"底色+单一前景色"提示图（例如橙底白字）。
每个 2×2 像素块先取平均，再按它在 底色→前景色 连线上的位置二值化（≥THRESH 记为前景）。

ROM 格式：16位/字，每行 20 字（320 位），共 240 行 = 4800 字；
          行序为屏幕从上到下，字内 bit15 为最左像素，1=前景色、0=底色。
底色/前景色以 RGB 常量形式打印出来，需与 sd_fallback_overlay_24.v 的 BG_COLOR/FG_COLOR 一致。

输出：
  src/user_source/hdl_source/rom/sd_fallback_1bit.hex   $readmemh 用（综合）
  tools/convert/output_bmp/sd_fallback_1bit_preview.png   按硬件同算法还原的 640×480 预览图，用于肉眼核对

用法：python make_fallback_1bit.py [图片路径]   （默认 Desktop/生图/SD.bmp）
"""
import sys
from collections import Counter
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SRC = Path.home() / "Desktop" / "生图" / "SD.bmp"
HEX_OUT = ROOT / "src/user_source/hdl_source/rom/sd_fallback_1bit.hex"
PREVIEW_OUT = ROOT / "tools/convert/output_bmp/sd_fallback_1bit_preview.png"

W, H = 640, 480
SW, SH = W // 2, H // 2       # ROM 内分辨率
THRESH = 0.3                  # 2×2块平均前景占比阈值；取0.3让细线、小字笔画不丢
WORDS_PER_ROW = SW // 16      # 20


def dist2(a, b):
    return sum((a[i] - b[i]) ** 2 for i in range(3))


def main():
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SRC
    im = Image.open(src).convert("RGB")
    if im.size != (W, H):
        raise SystemExit(f"图片尺寸须为 {W}x{H}，实际 {im.size}")
    px = im.load()

    cnt = Counter(im.getdata())
    bg = cnt.most_common(1)[0][0]
    fg = next((c for c, _ in cnt.most_common() if dist2(c, bg) > 100 ** 2), None)
    if fg is None:
        raise SystemExit("找不到与底色差异足够大的前景色")
    d = [fg[c] - bg[c] for c in range(3)]
    dd = sum(v * v for v in d)

    bits = [[0] * SW for _ in range(SH)]
    for y in range(SH):
        for x in range(SW):
            t = 0.0
            for dy in (0, 1):
                for dx in (0, 1):
                    p = px[2 * x + dx, 2 * y + dy]
                    t += sum((p[c] - bg[c]) * d[c] for c in range(3)) / dd
            bits[y][x] = 1 if t / 4 >= THRESH else 0

    words = []
    for y in range(SH):
        for w in range(WORDS_PER_ROW):
            v = 0
            for b in range(16):
                v = (v << 1) | bits[y][w * 16 + b]
            words.append(v)

    HEX_OUT.parent.mkdir(parents=True, exist_ok=True)
    HEX_OUT.write_text("".join(f"{v:04x}\n" for v in words), encoding="ascii")

    # 按硬件同算法还原预览：每个ROM像素放大成 2×2
    prev = Image.new("RGB", (W, H))
    pp = prev.load()
    for y in range(H):
        for x in range(W):
            pp[x, y] = fg if bits[y // 2][x // 2] else bg
    PREVIEW_OUT.parent.mkdir(parents=True, exist_ok=True)
    prev.save(PREVIEW_OUT)

    print(f"底色/前景色 : 24'h{bg[0]:02X}{bg[1]:02X}{bg[2]:02X} / 24'h{fg[0]:02X}{fg[1]:02X}{fg[2]:02X}")
    print(f"ROM 字数    : {len(words)}（{len(words) * 16} 位）")
    print(f"输出        : {HEX_OUT}")
    print(f"预览        : {PREVIEW_OUT}")


if __name__ == "__main__":
    main()
