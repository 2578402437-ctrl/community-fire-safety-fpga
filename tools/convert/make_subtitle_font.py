# -*- coding: utf-8 -*-
"""滚动字幕汉字点阵生成脚本。

用Windows黑体把字幕文字渲染成 32×32 单色点阵，生成Verilog函数体，
直接替换 SD/scroll_subtitle_24.v 中 "// FONT_BEGIN" 与 "// FONT_END" 之间的内容。
改字幕文字后重跑本脚本即可（字数需与模块参数 NUM_CHARS 一致）。

用法：python make_subtitle_font.py [字幕文字]
"""
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

TEXT = sys.argv[1] if len(sys.argv) > 1 else "关注消防安全知识"
GLYPH = 32                      # 点阵边长（像素）
FONT_PATH = r"C:\Windows\Fonts\simhei.ttf"
FONT_SIZE = 30                  # 字号略小于点阵，四周留白
THRESHOLD = 128                 # 灰度二值化阈值

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "src/user_source/hdl_source/osd/scroll_subtitle_24.v"


def render_char(ch, font):
    """渲染单个汉字，按墨迹包围盒居中到 GLYPH×GLYPH，返回每行一个整数（bit31=最左像素）。"""
    img = Image.new("L", (GLYPH * 2, GLYPH * 2), 0)
    ImageDraw.Draw(img).text((GLYPH // 2, GLYPH // 2), ch, font=font, fill=255)
    bbox = img.getbbox()
    glyph = Image.new("L", (GLYPH, GLYPH), 0)
    if bbox:
        crop = img.crop(bbox)
        glyph.paste(crop, ((GLYPH - crop.width) // 2, (GLYPH - crop.height) // 2))
    rows = []
    for y in range(GLYPH):
        v = 0
        for x in range(GLYPH):
            if glyph.getpixel((x, y)) >= THRESHOLD:
                v |= 1 << (GLYPH - 1 - x)
        rows.append(v)
    return rows


def main():
    if len(TEXT) != 8:
        raise SystemExit(f"字幕必须正好8个字（当前{len(TEXT)}字），否则需同步修改模块NUM_CHARS与ROM寻址位宽")
    font = ImageFont.truetype(FONT_PATH, FONT_SIZE)
    lines = []
    for ci, ch in enumerate(TEXT):
        rows = render_char(ch, font)
        lines.append(f"            // 第{ci}字：{ch}")
        for ri, v in enumerate(rows):
            lines.append(f"            {{3'd{ci}, 5'd{ri:2d}}}: glyph_row = 32'h{v:08x};")
        # 终端预览，便于核对字形
        print(f"--- {ch} ---")
        for v in rows:
            print("".join("#" if (v >> (GLYPH - 1 - x)) & 1 else "." for x in range(GLYPH)))

    src = TARGET.read_text(encoding="utf-8")
    body = "\n".join(lines)
    new, n = re.subn(r"(// FONT_BEGIN).*?(\n[ \t]*// FONT_END)",
                     lambda m: m.group(1) + "\n" + body + m.group(2), src, flags=re.S)
    if n != 1:
        raise SystemExit("未找到 FONT_BEGIN/FONT_END 标记")
    TARGET.write_text(new, encoding="utf-8")
    print(f"已写入 {TARGET}（{len(TEXT)}字）")


if __name__ == "__main__":
    main()
