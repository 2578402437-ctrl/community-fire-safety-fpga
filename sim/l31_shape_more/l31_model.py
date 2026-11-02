# 新增形状转场位精确模型：4=圆形光圈 5=方块溶解
# 两种新形状统一写成 "可见 ⇔ 度量 < vis"，vis = 进场 q / 退场 256-q（0~256）。
# 1~3 号形状模型在 sim/l19_shape_transition/tools/mask_model.py。
import os, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                '..', 'l19_shape_transition', 'tools'))
import mask_model as m19  # noqa: E402

W, H = 640, 480

# ---------- 光圈 ----------
# 像素中心坐标 u=2x-639、v=479-2y（单位半像素），中心到角 = 800 半像素。
# 半径 R = vis*800/256 = vis*3 + vis>>3，vis=256 时 R=800，整屏可见。


def iris_r2(vis):
    r = vis * 3 + (vis >> 3)
    return r * r


def iris_d2(x, y):
    u, v = 2 * x - 639, 479 - 2 * y
    return u * u + v * v


# ---------- 方块溶解 ----------
BS = 16                 # 方块边长
NX = W // BS            # 每行 40 块
C1 = 0x9E5              # 块序号乘数（按块累加实现）
C2 = 0x5A3              # 二次混合乘数（寄存器间常数乘）
K_ROW = (NX * C1) & 0xFFF   # 每换一行块 x1 增加量


def dissolve_t(bx, by):
    x1 = ((by * NX + bx) * C1) & 0xFFF
    x2 = x1 ^ (x1 >> 6)
    return ((x2 * C2) & 0xFFF) >> 4


def visible_vis(kind, vis, x, y):
    if kind == 4:
        return iris_d2(x, y) < iris_r2(vis)
    if kind == 5:
        return dissolve_t(x // BS, y // BS) < vis
    raise ValueError(kind)


def expect_code(kind, s_in, q, x, y):
    """结果码：0=黑 1=直通，与 l19_shape_transition 的 testbench 输出一致"""
    if kind in (4, 5):
        vis = q if s_in else 256 - q
        return 1 if visible_vis(kind, vis, x, y) else 0
    return m19.expect_code(kind, s_in, q, x, y)


# ---------- 控制器曲线（与 video_fade_transition.v 一致，FADE_FRAMES=90）----------
FADE_FRAMES = 90
STEP_Q8 = 65536 // FADE_FRAMES


def _alpha(ramp):
    return 255 if ramp == FADE_FRAMES else (ramp * STEP_Q8) >> 8


def _vis9(a):
    return 256 if a == 255 else a


def transition_seq(hold_frames=20):
    """逐帧 (阶段, shape_in, shape_q)：退场 ramp 90→0，全黑等待，进场 ramp 0→89"""
    seq = []
    for ramp in range(FADE_FRAMES, -1, -1):
        seq.append(('out', 0, 256 - _vis9(_alpha(ramp))))
    for _ in range(hold_frames):
        seq.append(('hold', 0, 256))
    for ramp in range(0, FADE_FRAMES):
        seq.append(('in', 1, _vis9(_alpha(ramp))))
    return seq
