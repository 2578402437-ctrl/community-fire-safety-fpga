# -*- coding: utf-8 -*-
"""消防员行走导航栏 + 分栏目滚动字幕 资源生成脚本。

生成（均在 src/user_source/hdl_source/rom/ 下，供 $readmemh 读取）：
  nav_sprite_4bit.hex   消防员小人 4帧×32行×32列（帧0~2为面朝右的行走动作，帧3为正面站立）（每像素1个十六进制数，只用低3位，第24~31列为透明填充）
                        地址 = {帧号2位, 行5位, 列5位}；0=透明 1=红 2=黄 3=肤色 4=深灰 5=黑描边
  nav_label_1bit.hex    导航栏标签点阵 16行×1024列（1024行，每行16位，bit15为最左像素），只用前640列
  subtitle_glyph32.hex  滚动字幕字库 N字×32行，每行32位（bit31为最左像素）
并把以下内容写回 Verilog 标记段（改文字后重跑本脚本即可）：
  SD/scroll_subtitle_24.v   "// SENT_BEGIN" ~ "// SENT_END"：字库字数、每句字数、每句的字序→字库编号表
  SD/fireman_nav_bar_24.v   "// LABEL_BEGIN" ~ "// LABEL_END"：每个标签的半宽（选中下划线用）

用法：python make_nav_assets.py [预览图输出目录]
"""
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

FONT_PATH = r"C:\Windows\Fonts\simhei.ttf"

# 栏目顺序 = 图片编号 0~3（PIC1~PIC4）
LABELS = ["充电桩安全", "公共区域安全", "家庭用电安全", "消防通道安全"]
SENTENCES = [
    "规范充电不飞线，人走断电保平安",
    "公共区域守规范，消防安全记心间",
    "用电安全无小事，随手断电防火灾",
    "生命通道严禁占用，保持畅通就是守护生命",
]

H_ACTIVE = 640
CELL_W = 160
LABEL_PITCH = 18                 # 标签字距（16点阵+2像素间隔）
LABEL_GLYPH = 16
SUB_GLYPH = 32
SPR_W, SPR_H, SPR_COLS = 24, 32, 32

ROOT = Path(__file__).resolve().parents[2]
HDL = ROOT / "src/user_source/hdl_source"
ROM = HDL / "rom"
SUB_V = HDL / "SD/scroll_subtitle_24.v"
NAV_V = HDL / "SD/fireman_nav_bar_24.v"

PUNCT = set("，。、；：！？")


def render_glyph(ch, font, size, thresh):
    """渲染单字为 size×size 单色点阵（行列表，每行 size 个 0/1）。
    汉字按墨迹包围盒居中；标点按参考字"国"的位置对齐，保持在左下角。"""
    canvas = Image.new("L", (size * 2, size * 2), 0)
    ImageDraw.Draw(canvas).text((size // 2, size // 2), ch, font=font, fill=255)
    if ch in PUNCT:
        ref = Image.new("L", (size * 2, size * 2), 0)
        ImageDraw.Draw(ref).text((size // 2, size // 2), "国", font=font, fill=255)
        rb = ref.getbbox()
        ox = rb[0] - (size - (rb[2] - rb[0])) // 2
        oy = rb[1] - (size - (rb[3] - rb[1])) // 2
        glyph = canvas.crop((ox, oy, ox + size, oy + size))
    else:
        glyph = Image.new("L", (size, size), 0)
        bb = canvas.getbbox()
        if bb:
            crop = canvas.crop(bb)
            glyph.paste(crop, ((size - crop.width) // 2, (size - crop.height) // 2))
    return [[1 if glyph.getpixel((x, y)) >= thresh else 0 for x in range(size)] for y in range(size)]


# ---------------- 消防员小人 ----------------
T, R, Y, S, D, K = 0, 1, 2, 3, 4, 5


def outline(px):
    """自动描边：透明像素的4邻域有实心像素 → 黑色。"""
    out = [row[:] for row in px]
    for y in range(SPR_H):
        for x in range(SPR_W):
            if px[y][x] == T and any(
                    0 <= x + dx < SPR_W and 0 <= y + dy < SPR_H and px[y + dy][x + dx] != T
                    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                out[y][x] = K
    return out


def sprite_front():
    """第3帧：正面站立。只画左半边（第0~11列）再左右镜像，保证对称，硬件镜像时不变。"""
    im = Image.new("L", (SPR_W, SPR_H), T)
    d = ImageDraw.Draw(im)
    # 头盔：圆顶 + 帽檐 + 正中红色徽章
    d.pieslice([6, 0, 17, 10], 180, 360, fill=Y)
    d.rectangle([4, 5, 11, 6], fill=Y)
    d.rectangle([10, 1, 11, 3], fill=R)
    # 脸 + 眼睛 + 嘴
    d.rectangle([8, 7, 11, 11], fill=S)
    d.point((9, 8), fill=K)
    d.point((11, 10), fill=D)
    # 身体 + 两道反光条 + 中缝
    d.rectangle([6, 12, 11, 21], fill=R)
    d.line([(6, 15), (11, 15)], fill=Y)
    d.line([(6, 19), (11, 19)], fill=Y)
    # 手臂（垂在身侧）+ 手
    d.rectangle([3, 13, 5, 19], fill=R)
    d.line([(3, 17), (5, 17)], fill=Y)
    d.rectangle([3, 20, 5, 21], fill=S)
    # 腿 + 反光条 + 靴子
    d.rectangle([7, 22, 10, 27], fill=R)
    d.line([(7, 25), (10, 25)], fill=Y)
    d.rectangle([6, 28, 10, 30], fill=D)
    px = [[im.getpixel((x, y)) for x in range(SPR_W)] for y in range(SPR_H)]
    for y in range(SPR_H):
        for x in range(SPR_W // 2):
            px[y][SPR_W - 1 - x] = px[y][x]
    return outline(px)


def sprite_frame(f):
    """第f帧（0=前腿迈出 1=并腿 2=后腿迈出），面朝右；f=3为正面站立。返回 SPR_H 行 × SPR_W 列的颜色编号。"""
    if f == 3:
        return sprite_front()
    im = Image.new("L", (SPR_W, SPR_H), T)
    d = ImageDraw.Draw(im)
    lf = [5, 0, -5, 0][f]        # 前腿脚尖相对髋部的水平偏移
    knee = [0, 2, 0, 2][f]
    # 后腿
    d.line([(11, 19), (11 - lf + knee, 25), (11 - lf, 28)], fill=R, width=4)
    d.rectangle([11 - lf - 2, 28, 11 - lf + 3, 30], fill=D)
    # 身体 + 反光条
    d.rectangle([7, 10, 16, 20], fill=R)
    d.line([(7, 13), (16, 13)], fill=Y)
    d.line([(7, 17), (16, 17)], fill=Y)
    # 前腿 + 反光条
    d.line([(12, 19), (12 + lf + knee, 25), (12 + lf, 28)], fill=R, width=4)
    d.line([(10 + lf + knee, 24), (14 + lf + knee, 24)], fill=Y)
    d.rectangle([12 + lf - 2, 28, 12 + lf + 4, 30], fill=D)
    # 脸 + 眼睛 + 头盔
    d.rectangle([9, 5, 15, 9], fill=S)
    d.point((14, 6), fill=K)
    d.pieslice([7, 0, 17, 9], 180, 360, fill=Y)
    d.rectangle([6, 4, 19, 5], fill=Y)
    # 手臂（与腿反向摆动）
    ha = [-4, 0, 4, 0][f]
    d.line([(12, 11), (12 + ha, 17)], fill=R, width=3)
    d.rectangle([12 + ha - 1, 17, 12 + ha + 1, 18], fill=S)
    px = [[im.getpixel((x, y)) for x in range(SPR_W)] for y in range(SPR_H)]
    return outline(px)


def main():
    preview_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else None

    # ---- 小人 ----
    frames = [sprite_frame(f) for f in range(4)]
    lines = []
    for f in range(4):
        for y in range(SPR_H):
            for x in range(SPR_COLS):
                lines.append("%x" % (frames[f][y][x] if x < SPR_W else 0))
    (ROM / "nav_sprite_4bit.hex").write_text("\n".join(lines) + "\n", encoding="ascii")

    # ---- 标签 ----
    lfont = ImageFont.truetype(FONT_PATH, LABEL_GLYPH)
    strip = [[0] * 1024 for _ in range(LABEL_GLYPH)]
    halves = []
    for i, s in enumerate(LABELS):
        w = len(s) * LABEL_PITCH - (LABEL_PITCH - LABEL_GLYPH)
        half = w // 2
        halves.append(half)
        x0 = CELL_W * i + CELL_W // 2 - half
        for k, ch in enumerate(s):
            g = render_glyph(ch, lfont, LABEL_GLYPH, 110)
            for y in range(LABEL_GLYPH):
                for x in range(LABEL_GLYPH):
                    if g[y][x]:
                        strip[y][x0 + k * LABEL_PITCH + x] = 1
    lines = []
    for y in range(LABEL_GLYPH):
        for w in range(64):
            v = 0
            for b in range(16):
                if strip[y][w * 16 + b]:
                    v |= 1 << (15 - b)
            lines.append("%04x" % v)
    (ROM / "nav_label_1bit.hex").write_text("\n".join(lines) + "\n", encoding="ascii")

    # ---- 字幕字库 ----
    chars = []
    for s in SENTENCES:
        for ch in s:
            if ch not in chars:
                chars.append(ch)
    if len(chars) > 64:
        raise SystemExit("字库超过64字，需加宽sent_char输出位宽")
    for s in SENTENCES:
        if len(s) > 31:
            raise SystemExit("单句超过31字，需加宽字序位宽")
    sfont = ImageFont.truetype(FONT_PATH, 30)
    glyphs = [render_glyph(ch, sfont, SUB_GLYPH, 128) for ch in chars]
    lines = []
    for g in glyphs:
        for y in range(SUB_GLYPH):
            v = 0
            for x in range(SUB_GLYPH):
                if g[y][x]:
                    v |= 1 << (31 - x)
            lines.append("%08x" % v)
    (ROM / "subtitle_glyph32.hex").write_text("\n".join(lines) + "\n", encoding="ascii")

    # ---- 写回 Verilog 标记段 ----
    body = ["    localparam integer NUM_GLYPHS = %d;   // 字库字数：%s" % (len(chars), "".join(chars)),
            "",
            "    // 每句字数",
            "    function [4:0] sent_len;",
            "        input [1:0] s;",
            "        begin",
            "            case (s)"]
    for i, s in enumerate(SENTENCES):
        body.append("            2'd%d: sent_len = 5'd%d;   // %s" % (i, len(s), s))
    body += ["            default: sent_len = 5'd0;",
             "            endcase",
             "        end",
             "    endfunction",
             "",
             "    // {句号, 字序} → 字库编号",
             "    function [5:0] sent_char;",
             "        input [6:0] addr;",
             "        begin",
             "            case (addr)"]
    for i, s in enumerate(SENTENCES):
        for k, ch in enumerate(s):
            body.append("            {2'd%d, 5'd%2d}: sent_char = 6'd%2d;   // %s" % (i, k, chars.index(ch), ch))
    body += ["            default: sent_char = 6'd0;",
             "            endcase",
             "        end",
             "    endfunction"]
    patch(SUB_V, "SENT", body)

    body = ["    // 每个标签的半宽（像素），标签以栏目中央为中心",
            "    function [6:0] label_half;",
            "        input [1:0] i;",
            "        begin",
            "            case (i)"]
    for i, h in enumerate(halves):
        body.append("            2'd%d: label_half = 7'd%d;   // %s" % (i, h, LABELS[i]))
    body += ["            default: label_half = 7'd0;",
             "            endcase",
             "        end",
             "    endfunction"]
    patch(NAV_V, "LABEL", body)

    print("字库 %d 字：%s" % (len(chars), "".join(chars)))
    print("每句字数：", [len(s) for s in SENTENCES])
    print("标签半宽：", halves)

    if preview_dir:
        preview_dir.mkdir(parents=True, exist_ok=True)
        pal = {T: (255, 0, 255), R: (208, 24, 24), Y: (255, 200, 0), S: (245, 192, 138),
               D: (42, 42, 42), K: (16, 16, 16)}
        im = Image.new("RGB", (4 * (SPR_W + 4), SPR_H), (255, 0, 255))
        for f in range(4):
            for y in range(SPR_H):
                for x in range(SPR_W):
                    im.putpixel((f * (SPR_W + 4) + x, y), pal[frames[f][y][x]])
        im.resize((im.width * 6, im.height * 6), Image.NEAREST).save(preview_dir / "sprite_frames.png")
        im = Image.new("L", (H_ACTIVE, LABEL_GLYPH), 0)
        for y in range(LABEL_GLYPH):
            for x in range(H_ACTIVE):
                im.putpixel((x, y), 255 * strip[y][x])
        im.resize((H_ACTIVE * 2, LABEL_GLYPH * 2), Image.NEAREST).save(preview_dir / "labels.png")
        im = Image.new("L", (SUB_GLYPH * len(chars), SUB_GLYPH), 0)
        for c, g in enumerate(glyphs):
            for y in range(SUB_GLYPH):
                for x in range(SUB_GLYPH):
                    im.putpixel((c * SUB_GLYPH + x, y), 255 * g[y][x])
        im.save(preview_dir / "subtitle_glyphs.png")


def patch(path, tag, body):
    src = path.read_text(encoding="utf-8")
    new, n = re.subn(r"(// %s_BEGIN).*?(\n[ \t]*// %s_END)" % (tag, tag),
                     lambda m: m.group(1) + "\n" + "\n".join(body) + m.group(2), src, flags=re.S)
    if n != 1:
        raise SystemExit("%s 中未找到 %s_BEGIN/%s_END 标记" % (path, tag, tag))
    path.write_text(new, encoding="utf-8")


if __name__ == "__main__":
    main()
