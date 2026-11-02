# 比对 tb_footstep 输出的 rtl_out.txt 与定点模型
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import footstep_model as m

f = m.Foot()
ref = []
for n in range(12800 * 3):
    if n % 12800 == 0:
        f.trig((n // 12800) % 2)
    ref.append(f.tick())
rtl = [int(x) for x in open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "rtl_out.txt"))]
bad = [i for i in range(len(ref)) if i >= len(rtl) or rtl[i] != ref[i]]
print("samples=%d rtl=%d mismatch=%d" % (len(ref), len(rtl), len(bad)))
if bad:
    i = bad[0]
    print("first mismatch at %d: ref=%d rtl=%s" % (i, ref[i], rtl[i] if i < len(rtl) else None))
print("PASS" if not bad else "FAIL")
