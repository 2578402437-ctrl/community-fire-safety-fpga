# 遮罩逐像素比对
# 用法：python -I l31_check.py params   —— 生成 params.hex（{kind[2:0],in,q[8:0]}，13位）
#       python -I l31_check.py check    —— 比对 mask_out.txt 与 l31_model 位精确模型
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import l31_model as M  # noqa: E402

Q_LIST = [0, 1, 37, 64, 100, 128, 129, 192, 230, 255, 256]
KIND_NAME = {0: '不遮罩', 1: '中间往两边', 2: '两边往中间', 3: '轮子', 4: '光圈', 5: '溶解'}
HERE = os.path.dirname(os.path.abspath(__file__))


def param_list():
    ps = [(0, 1, 128)]
    for kind in (1, 2, 3, 4, 5):
        for s_in in (0, 1):
            for q in Q_LIST:
                ps.append((kind, s_in, q))
    ps.append((0, 0, 200))
    return ps


def gen_params():
    ps = param_list()
    with open(os.path.join(HERE, 'params.hex'), 'w') as f:
        for kind, s_in, q in ps:
            f.write('%04x\n' % ((kind << 10) | (s_in << 9) | q))
    print('params ok, N =', len(ps))


def check():
    lines = open(os.path.join(HERE, 'mask_out.txt')).read().split()
    ps = param_list()
    assert len(lines) == len(ps) * M.H, (len(lines), len(ps) * M.H)
    total_bad = 0
    for fi, (kind, s_in, q) in enumerate(ps):
        rows = lines[fi * M.H:(fi + 1) * M.H]
        bad = err2 = 0
        for y in range(M.H):
            r = rows[y]
            assert len(r) == M.W
            for x in range(M.W):
                got = r[x]
                if got == '2':
                    err2 += 1
                if int(got) != M.expect_code(kind, s_in, q, x, y):
                    bad += 1
        shown = sum(r.count('1') for r in rows)
        total_bad += bad + err2
        print('frame%3d kind=%d(%s) %s q=%3d shown=%6d mismatch=%d other=%d' %
              (fi + 1, kind, KIND_NAME[kind], 'IN ' if s_in else 'OUT', q, shown, bad, err2))
    print('TOTAL_MISMATCH', total_bad)
    print('PASS' if total_bad == 0 else 'FAIL')


if __name__ == '__main__':
    {'params': gen_params, 'check': check}[sys.argv[1]]()
