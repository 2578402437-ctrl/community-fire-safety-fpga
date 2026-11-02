# 比对 mask_out.txt 与位精确模型；统计与理想几何的偏差；可选输出预览图
# 用法：python -I tools/check_mask.py <仿真目录> [预览图输出目录]
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mask_model import param_list, expect_code, covered_ideal, W, H

d = sys.argv[1]
prev_dir = sys.argv[2] if len(sys.argv) > 2 else None
lines = open(os.path.join(d, 'mask_out.txt')).read().split()
ps = param_list()
assert len(lines) == len(ps) * H, (len(lines), len(ps) * H)

KIND_NAME = {0: '淡入淡出(不遮罩)', 1: '中间往两边', 2: '两边往中间', 3: '轮子'}
total_bad = 0
for fi, (kind, s_in, q) in enumerate(ps):
    rows = lines[fi * H:(fi + 1) * H]
    bad = err2 = ideal_diff = 0
    for y in range(H):
        r = rows[y]
        assert len(r) == W
        for x in range(W):
            got = r[x]
            if got == '2':
                err2 += 1
            if int(got) != expect_code(kind, s_in, q, x, y):
                bad += 1
            if int(got) != expect_code(kind, s_in, q, x, y, covered_ideal):
                ideal_diff += 1
    shown = sum(r.count('1') for r in rows)
    total_bad += bad
    print('帧%2d %-10s %s q=%3d  显示%6d  失配%d  非黑非直通%d  与理想几何差%d' %
          (fi + 1, KIND_NAME[kind], '进场' if s_in else '退场', q, shown, bad, err2, ideal_diff))

    if prev_dir and kind == 3 and s_in == 1 and q in (37, 100, 192):
        from PIL import Image
        im = Image.new('RGB', (W, H))
        px = im.load()
        for y in range(H):
            for x in range(W):
                px[x, y] = (230, 120, 40) if rows[y][x] == '1' else (0, 0, 0)
        im.save(os.path.join(prev_dir, 'wheel_in_q%d.png' % q))

print('总失配像素:', total_bad)
print('PASS' if total_bad == 0 else 'FAIL')
