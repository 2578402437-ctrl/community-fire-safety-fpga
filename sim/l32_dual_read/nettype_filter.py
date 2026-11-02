# 从 vlog 输出里挑出"端口表以外"的隐式线网报错（vlog-2892）
# 用法：vlog ... 2>&1 | python -I nettype_filter.py
import re, sys

bad = 0
total = 0
for line in sys.stdin.buffer.read().decode('gbk', 'replace').splitlines():
    m = re.search(r'Error: (\S+)\((\d+)\): \(vlog-(\d+)\)', line)
    if not m:
        continue
    total += 1
    f, ln, code = m.group(1), int(m.group(2)), m.group(3)
    src = open(f, 'rb').read().decode('utf-8', 'replace').splitlines()[ln - 1]
    if code == '2892' and re.match(r'\s*(input|output|inout)\b', src):
        continue
    bad += 1
    print('%s:%d vlog-%s  %s' % (f, ln, code, src.strip()))
print('errors_total=%d  non_port_errors=%d' % (total, bad))
