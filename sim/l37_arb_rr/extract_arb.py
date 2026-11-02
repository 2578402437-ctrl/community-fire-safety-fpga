# 从 sd_card_bmp_v2.v 原样抠出仲裁段（localparam OWN_SCAN 起，到 FAT32 卷扫描器注释前），
# 生成 tb 用的 include 文件，保证仿真的是真实 RTL 文本。
# 用法: python -I extract_arb.py <sd_card_bmp_v2.v> <输出.vh>
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, 'rb') as f:
    lines = f.read().decode('utf-8').split('\n')

start = next(i for i, l in enumerate(lines) if 'localparam OWN_SCAN' in l)
end = next(i for i, l in enumerate(lines) if i > start and '// =============' in l and 'FAT32' in l)
chunk = '\n'.join(lines[start:end]) + '\n'
with open(dst, 'wb') as f:
    f.write(chunk.encode('utf-8'))
print('extracted lines %d..%d -> %s' % (start + 1, end, dst))
