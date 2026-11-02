"""四个栏目的"背景音乐 + 宣传语音"预混音

每段布局（秒）：[前导 LEAD 只有背景乐][语音][间隔 GAP][语音][间隔 GAP][语音][间隔 GAP-LEAD]
FPGA 播完整段后从段首循环，所以段尾 GAP-LEAD 加上段首 LEAD 正好是 GAP。
前导用来躲开切图转场时的音量压低（转场 1.5 s）。
背景乐保持原电平，语音期间压低 DUCK_DB 便于听清；段首/段尾短淡入淡出，避免循环接缝咔声。
语音先经 VOICE_COMP 压缩（降低峰均比、抬高平均响度）再峰值归一，语音期间背景乐压低 12 dB。
输入（放在当前目录）：背景乐 舒缓钢琴曲.wav，四个栏目的宣传语音 voice0_<名>.mp3 ~ voice3_<名>.mp3
      （<名> 由命令行第 1 个参数指定，默认 YunyangNeural）。
输出：colN.wav（48 kHz 单声道 16 位，可直接试听），再用 pack_and_probe.py 打包成 col_bank.pcm。
用法：python make_column_audio.py [<名>]
"""
import subprocess, sys, wave
import numpy as np

SR = 48000
LEAD, GAP, REPEAT = 1.5, 5.0, 3
DUCK_DB = -12.0         # 语音期间背景乐压低量
RAMP = 0.3              # 压低/恢复过渡时长
VOICE_PEAK_DB = -1.0    # 语音峰值归一化
# 语音压缩（ffmpeg acompressor，阈值约 -24 dB、4:1），空串=不压缩
VOICE_COMP = "acompressor=threshold=0.063:ratio=4:attack=5:release=100"
SEAM_FADE = (0.05, 0.4) # 段首淡入、段尾淡出
BGM = "舒缓钢琴曲.wav"
VOICE = sys.argv[1] if len(sys.argv) > 1 else "YunyangNeural"


def load(path, af=""):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ar", str(SR), "-ac", "1",
                          *(["-af", af] if af else []), "-f", "f32le", "-"], stdout=subprocess.PIPE, check=True).stdout
    return np.frombuffer(raw, np.float32).astype(np.float64)


def trim(x, th=10 ** (-50 / 20)):
    idx = np.nonzero(np.abs(x) > th)[0]
    return x[idx[0]:idx[-1] + 1]


bgm = load(BGM)
for i in range(4):
    v = trim(load(f"voice{i}_{VOICE}.mp3", VOICE_COMP))
    v *= 10 ** (VOICE_PEAK_DB / 20) / np.max(np.abs(v))
    nl, ng, nv = int(LEAD * SR), int(GAP * SR), len(v)
    n = nl + REPEAT * (nv + ng) - nl
    if n > len(bgm):
        sys.exit(f"段{i}长 {n / SR:.1f}s 超过背景乐 {len(bgm) / SR:.1f}s")
    voice = np.zeros(n)
    mask = np.zeros(n)
    for k in range(REPEAT):
        s = nl + k * (nv + ng)
        voice[s:s + nv] = v
        mask[s:s + nv] = 1.0
    # 压低包络：掩码做 RAMP 长度的滑动平均，得到平滑过渡（提前 RAMP/2 开始压）
    r = int(RAMP * SR)
    c = np.concatenate(([0.0], np.cumsum(mask)))
    lo = np.clip(np.arange(n) - r // 2, 0, n)
    env = (c[np.clip(lo + r, 0, n)] - c[lo]) / r
    duck = 10 ** (DUCK_DB * env / 20)
    b = bgm[:n] * duck
    fi, fo = int(SEAM_FADE[0] * SR), int(SEAM_FADE[1] * SR)
    b[:fi] *= np.linspace(0, 1, fi)
    b[-fo:] *= np.linspace(1, 0, fo)
    y = b + voice
    peak = np.max(np.abs(y))
    if peak > 0.97:
        y *= 0.97 / peak
    pcm = np.round(y * 32767).astype("<i2")
    with wave.open(f"col{i}.wav", "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"col{i}.wav: {n / SR:.2f}s 语音 {nv / SR:.2f}s 峰值 {20 * np.log10(peak):.1f}dBFS"
          f"{' (已整体压到-0.3dB)' if peak > 0.97 else ''}")
print(f"背景乐峰值 {20 * np.log10(np.max(np.abs(bgm))):.1f}dBFS RMS {20 * np.log10(np.sqrt(np.mean(bgm ** 2))):.1f}dBFS")
