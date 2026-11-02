"""四段栏目音频打包成 col_bank.pcm，并只读核对卡上目标扇区是否空闲

用法：python pack_and_probe.py E: --start-lba 157016
  --start-lba 为卷内偏移（紧接原 audio_bank 报警音2之后，8 扇区对齐）
只读：读 FAT32 引导扇区与 FAT 表，确认目标扇区所在簇全部未分配；不写卡。
"""
import argparse, struct, wave
import win32con, win32file

SECTOR, ALIGN = 512, 8
IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS = 0x00560000

ap = argparse.ArgumentParser()
ap.add_argument("drive"); ap.add_argument("--start-lba", type=int, required=True)
a = ap.parse_args()

bank, segs = bytearray(), []
for i in range(4):
    with wave.open(f"col{i}.wav", "rb") as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (1, 2, 48000)
        pcm = w.readframes(w.getnframes())
    sec = (len(pcm) + SECTOR - 1) // SECTOR
    off = len(bank) // SECTOR
    bank += pcm + b"\x00" * (sec * SECTOR - len(pcm))
    al = (len(bank) // SECTOR + ALIGN - 1) // ALIGN * ALIGN
    bank += b"\x00" * (al * SECTOR - len(bank))
    segs.append((off, sec))
open("col_bank.pcm", "wb").write(bank)
nsec = len(bank) // SECTOR
print(f"col_bank.pcm {nsec} 扇区，卷内 {a.start_lba}~{a.start_lba + nsec - 1}")

h = win32file.CreateFile(chr(92) * 2 + "." + chr(92) + a.drive, win32con.GENERIC_READ,
                         win32con.FILE_SHARE_READ | win32con.FILE_SHARE_WRITE, None,
                         win32con.OPEN_EXISTING, 0, None)
buf = win32file.DeviceIoControl(h, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, None, 64)
_, _, _, _, start, length = struct.unpack("<IIIIqq", bytes(buf[:32]))
part = start // SECTOR

def rd(lba, n=1):
    win32file.SetFilePointer(h, lba * SECTOR, win32con.FILE_BEGIN)
    return win32file.ReadFile(h, n * SECTOR)[1]

bs = rd(0)
rsv, nfat, spc = struct.unpack_from("<H", bs, 14)[0], bs[16], bs[13]
fatsz = struct.unpack_from("<I", bs, 36)[0]
data0 = rsv + nfat * fatsz
c_lo = (a.start_lba - data0) // spc + 2
c_hi = (a.start_lba + nsec - 1 - data0) // spc + 2
print(f"分区起始物理扇区 {part}，每簇 {spc} 扇区，数据区起 {data0}，目标簇 {c_lo}~{c_hi}")
fs, fe = (c_lo * 4) // SECTOR, (c_hi * 4) // SECTOR
fat = rd(rsv + fs, fe - fs + 1)
used = [c for c in range(c_lo, c_hi + 1)
        if struct.unpack_from("<I", fat, c * 4 - fs * SECTOR)[0] & 0x0FFFFFFF]
print("FAT 中目标簇已分配数：", len(used), used[:5])
nz = sum(any(rd(a.start_lba + k * 997)) for k in range(nsec // 997))
print(f"目标区抽样 {nsec // 997} 个扇区，非零 {nz} 个（旧数据，不影响）")
print("\n填进 top_tf_hdmi_audio_v2.v 的参数：")
for i, (off, sec) in enumerate(segs):
    print(f"    .WAV_COL{i}_START_LBA     (32'd{part + a.start_lba + off}),")
    print(f"    .WAV_COL{i}_TOTAL_SECTORS (32'd{sec}),")
h.Close()
