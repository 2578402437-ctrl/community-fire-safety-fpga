# 脚步声合成定点模型（与 SD/footstep_synth.v 逐位一致）
# 用法：python -I footstep_model.py [输出目录]
# 生成：footstep_preview.wav（每0.267秒一步、左右脚交替，共4秒），并打印峰值/持续时间
import sys, struct, wave, os

FS        = 48000
STEP_SAMP = 12800          # 16帧@60Hz = 0.2667 s = 12800 个采样
ENV_MAX   = 32767
DECAY_SH  = 11             # 包络每采样衰减 env>>11，再减1（时间常数约43 ms）
LP_SH_L   = 2              # 左脚低通移位（约1.9 kHz，偏"啪"）
LP_SH_R   = 3              # 右脚低通移位（约950 Hz，偏"咚"）
OUT_SH    = 12             # 输出 = (y2*env)>>>OUT_SH

def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v

def asr(v, n):             # 算术右移（Python 的 >> 对负数即为算术右移）
    return v >> n

class Foot:
    def __init__(self):
        self.lfsr = 0xACE1
        self.env = 0
        self.side = 0
        self.y1 = 0
        self.y2 = 0
        self.out = 0

    def trig(self, side):
        self.env = ENV_MAX
        self.side = side

    def tick(self):
        if self.env == 0:
            self.y1 = self.y2 = 0
            self.out = 0
            return 0
        # 16位Galois LFSR，多项式 x^16+x^14+x^13+x^11+1（0xB400）
        lsb = self.lfsr & 1
        self.lfsr >>= 1
        if lsb:
            self.lfsr ^= 0xB400
        x = s16(self.lfsr) >> 1                  # ±16384
        sh = LP_SH_R if self.side else LP_SH_L
        self.y1 = s16(self.y1 + asr(x - self.y1, sh))
        self.y2 = s16(self.y2 + asr(self.y1 - self.y2, sh))
        # 输出用本拍更新前的包络（与RTL寄存时序一致）
        p = self.y2 * self.env                   # 16x16 有符号×无符号
        o = asr(p, OUT_SH)
        o = max(-32768, min(32767, o))
        self.out = o
        dec = (self.env >> DECAY_SH) + 1
        self.env = self.env - dec if self.env > dec else 0
        return o

def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
    f = Foot()
    n_total = FS * 4
    samples = []
    side = 0
    peak = 0
    first_len = None
    for n in range(n_total):
        if n % STEP_SAMP == 0:
            f.trig(side)
            side ^= 1
        o = f.tick()
        samples.append(o)
        peak = max(peak, abs(o))
        if first_len is None and n > 0 and f.env == 0:
            first_len = n
    path = os.path.join(outdir, "footstep_preview.wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(FS)
        w.writeframes(b"".join(struct.pack("<h", s) for s in samples))
    print("peak=%d (%.1f dBFS)" % (peak, 20 * __import__("math").log10(peak / 32768.0)))
    print("one step length = %d samples = %.1f ms" % (first_len, first_len * 1000.0 / FS))
    print("wav:", path)

if __name__ == "__main__":
    main()
