# 从顶层原样抠出音量增益段，生成 include 片段供 tb 使用
import sys
src = open(sys.argv[1], encoding='utf-8').read().split('\n')
def idx(key):
    return next(i for i, l in enumerate(src) if key in l)
a = idx('wire signed [15:0] mix_audio_16'); b = idx('wire signed [29:0] gain_prod')
c = idx('wire signed [29:0] foot_prod');    d = idx('wire signed [30:0] mix_out')
open('gain_chunk.vh', 'w', encoding='utf-8').write('\n'.join(src[a:b+1] + src[c:d+1]) + '\n')
print(a+1, b+1, c+1, d+1)
