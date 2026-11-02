# -*- coding: utf-8 -*-
"""KEY3亮度/音量调节：屏幕中央"亮度调节"/"音量调节"字幕点阵生成脚本。

复用 make_subtitle_font.py 的 render_char（Windows黑体 32×32），
生成Verilog函数体替换 SD/brightness_bar_24.v 中 "// FONT_BEGIN" 与 "// FONT_END" 之间的内容。
字库固定6个字（模块按3位字号寻址）：0~3为亮度标题，4、5替换音量标题的前两字，
第2、3字两个标题共用（默认"亮度调节音量" → "亮度调节"/"音量调节"）。

用法：python make_brightness_font.py [6个字]
"""
import re
import sys
from pathlib import Path

from PIL import ImageFont

from make_subtitle_font import FONT_PATH, FONT_SIZE, GLYPH, render_char

TEXT = sys.argv[1] if len(sys.argv) > 1 else "亮度调节音量"
ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "src/user_source/hdl_source/osd/brightness_bar_24.v"


def main():
    if len(TEXT) != 6:
        raise SystemExit(f"必须正好6个字（当前{len(TEXT)}字），否则需同步修改模块char_id映射与ROM寻址位宽")
    font = ImageFont.truetype(FONT_PATH, FONT_SIZE)
    lines = []
    for ci, ch in enumerate(TEXT):
        rows = render_char(ch, font)
        lines.append(f"            // 第{ci}字：{ch}")
        for ri, v in enumerate(rows):
            lines.append(f"            {{3'd{ci}, 5'd{ri:2d}}}: glyph_row = 32'h{v:08x};")
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
