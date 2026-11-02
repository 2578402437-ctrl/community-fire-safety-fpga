# 生成 params.hex：每行 {kind[1:0], in, q[8:0]}
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mask_model import param_list

out = sys.argv[1]
ps = param_list()
with open(os.path.join(out, 'params.hex'), 'w') as f:
    for kind, s_in, q in ps:
        f.write('%03x\n' % ((kind << 10) | (s_in << 9) | q))
print('params ok, N =', len(ps))
