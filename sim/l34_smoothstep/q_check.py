# 核对 RTL 打印的 q 序列 = smoothstep 定点模型
# 用法：python -I q_check.py vsim.log
import re, sys

N = 90
def q_model(r):
    return ((3*r*r*N - 2*r**3) * 256 + N**3 // 2) // N**3

def gain_model(q):
    d = 0 if q >= 256 else (256 - q if q >= 128 else q)
    return 255 - d

tbl = [q_model(r) for r in range(N + 1)]
err = []
assert tbl[0] == 0 and tbl[N] == 256, "端点错误"
assert all(b >= a for a, b in zip(tbl, tbl[1:])), "不单调"
asym = [r for r in range(N + 1) if tbl[r] + tbl[N - r] != 256]
print("table head", tbl[:8], "mid", tbl[44:47], "tail", tbl[-6:])
print("max step", max(b - a for a, b in zip(tbl, tbl[1:])), "asym(rounding) idx", asym)

runs = {}
for line in open(sys.argv[1], encoding="latin-1"):
    m = re.search(r"Q run=(\d+) f=(\d+) st=(\d+) kind=(\d+) q=(\d+) gain=(\d+)", line)
    if m:
        run, f, st, kind, q, gain = map(int, m.groups())
        runs.setdefault(run, []).append((f, st, kind, q, gain))

for run, rows in runs.items():
    mix = [r for r in rows if r[1] == 2]
    qs = [r[3] for r in mix]
    if qs != tbl:
        err.append("run%d S_MIX q序列不符：%d帧" % (run, len(qs)))
    for f, st, kind, q, gain in rows:
        exp_q = 256 if st == 3 else (q if st == 2 else 0)
        if q != exp_q:
            err.append("run%d f%d st%d q=%d 期望%d" % (run, f, st, q, exp_q))
        if gain != gain_model(q):
            err.append("run%d f%d gain=%d 期望%d" % (run, f, gain, gain_model(q)))
    seq = [r[1] for r in rows]
    print("run%d kind=%d PREP=%d MIX=%d HAND=%d back_to_IDLE=%s" % (
        run, mix[0][2] if mix else -1, seq.count(1), seq.count(2), seq.count(3), seq[-1] == 0))

print("ALL PASS" if not err and len(runs) == 2 else "FAIL\n" + "\n".join(err[:20]))
