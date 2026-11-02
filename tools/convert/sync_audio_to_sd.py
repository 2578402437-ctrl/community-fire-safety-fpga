"""
FPGA SD卡 WAV音频裸扇区写入工具（配合 wav_stream_player.v 流式播放）

与 sync_to_sd.py（图片同步，走正常文件系统拷贝）不同，本脚本写的是
"裸PCM数据"，不经过FAT32文件系统，直接把文件内容写到TF卡的指定物理
扇区上——因为 wav_stream_player.v 读音频时用的是固定的 start_lba/
total_sectors 两个物理扇区参数，不走文件名查找。

使用前必须确认：
  1. 待写入的PCM文件已经是 16位有符号、小端序、48kHz、单声道 的裸数据
     （用 ffmpeg -ar 48000 -ac 1 -f s16le -acodec pcm_s16le 转出来的那种，
     不带任何WAV文件头）。
  2. 选定的起始扇区号 start_lba 必须落在FAT32文件系统实际占用范围之外，
     否则会破坏图片和文件系统！本工程 sd_card_bmp_v2 的 SCAN_MAX_SECTOR
     默认是 131071（卡的前64MB），只要你格式化TF卡时建的FAT32分区没有
     超过64MB，131072号扇区往后就是安全的。
  3. 只能对"可移动磁盘"（SD读卡器识别出来的盘）操作，脚本会检查盘符类型，
     不是可移动磁盘会直接拒绝，防止误写系统盘。
  4. 必须以管理员权限运行终端，否则无法获得卷的独占锁定，写入会失败。

用法：
    python sync_audio_to_sd.py E: di_yi_tian_20s.pcm --start-lba 140000

写完后脚本会打印出实际占用的扇区数，把这两个数字（start_lba和打印出的
total_sectors）填进 top_tf_hdmi_audio_v2.v 里 sd_card_bmp_v2 实例化的
.WAV_START_LBA / .WAV_TOTAL_SECTORS 参数，重新综合烧录即可。
"""

import os
import sys
import argparse

try:
    import win32file
    import win32con
    import winioctlcon
except ImportError:
    print("[错误] 缺少 pywin32，请先: pip install pywin32")
    sys.exit(1)

SECTOR_SIZE = 512


def check_removable(drive_root):
    """drive_root形如 'E:\\'，只允许对可移动磁盘操作，防止误写系统盘。"""
    drive_type = win32file.GetDriveType(drive_root)
    if drive_type != win32con.DRIVE_REMOVABLE:
        type_names = {
            0: "未知", 1: "无根目录", 2: "可移动磁盘",
            3: "固定磁盘(本地硬盘)", 4: "网络磁盘", 5: "光驱", 6: "内存盘",
        }
        print(f"[拒绝] {drive_root} 的磁盘类型是「{type_names.get(drive_type, drive_type)}」，"
              f"不是可移动磁盘，为防止误写系统盘/数据盘，本脚本只允许对可移动磁盘(SD/TF卡)操作。")
        sys.exit(1)


def lock_and_dismount(handle):
    win32file.DeviceIoControl(handle, winioctlcon.FSCTL_LOCK_VOLUME, None, 0)
    win32file.DeviceIoControl(handle, winioctlcon.FSCTL_DISMOUNT_VOLUME, None, 0)


def unlock(handle):
    try:
        win32file.DeviceIoControl(handle, winioctlcon.FSCTL_UNLOCK_VOLUME, None, 0)
    except Exception:
        pass


def get_partition_start_sector(handle):
    """查询卷所在分区在物理盘上的起始扇区（IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS）"""
    import struct
    IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS = 0x00560000
    buf = win32file.DeviceIoControl(handle, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, None, 64)
    _, _, _, _, start_bytes, _ = struct.unpack("<IIIIqq", bytes(buf[:32]))
    return start_bytes // SECTOR_SIZE


def write_raw_sectors(drive, pcm_path, start_lba):
    drive = drive.rstrip('\\').rstrip('/')
    if not drive.endswith(':'):
        print(f"[错误] 盘符格式应为 'E:' 这种，收到的是: {drive}")
        sys.exit(1)

    drive_root = drive + '\\'
    check_removable(drive_root)

    if not os.path.isfile(pcm_path):
        print(f"[错误] 找不到文件: {pcm_path}")
        sys.exit(1)

    file_size = os.path.getsize(pcm_path)
    total_sectors = (file_size + SECTOR_SIZE - 1) // SECTOR_SIZE
    pad = total_sectors * SECTOR_SIZE - file_size

    print(f"源文件: {pcm_path}")
    print(f"文件大小: {file_size} 字节")
    print(f"占用扇区数: {total_sectors} (末尾补{pad}字节到扇区边界)" if pad else f"占用扇区数: {total_sectors} (正好整除扇区边界)")
    print(f"目标: {drive_root}  起始扇区(LBA): {start_lba}")
    print(f"字节偏移: {start_lba * SECTOR_SIZE}")
    print()
    print("!!! 写入操作不可撤销，请再次确认 start_lba 落在FAT32分区之外 !!!")
    confirm = input(f"确认无误请输入目标盘符 {drive} 以继续: ").strip()
    if confirm.upper() != drive.upper():
        print("输入不匹配，已取消。")
        sys.exit(1)

    volume_path = r"\\.\{}".format(drive)
    handle = win32file.CreateFile(
        volume_path,
        win32con.GENERIC_READ | win32con.GENERIC_WRITE,
        win32con.FILE_SHARE_READ | win32con.FILE_SHARE_WRITE,
        None,
        win32con.OPEN_EXISTING,
        0,
        None
    )

    try:
        lock_and_dismount(handle)

        with open(pcm_path, 'rb') as f:
            data = f.read()
        if pad:
            data += b'\x00' * pad

        win32file.SetFilePointer(handle, start_lba * SECTOR_SIZE, win32con.FILE_BEGIN)
        win32file.WriteFile(handle, data)

        print()
        print(f"写入完成！共写入 {len(data)} 字节 ({total_sectors} 扇区)。")
        print()
        # 注意：\.\E: 是"卷句柄"，上面的start_lba是相对分区起点的偏移；
        # FPGA读的是物理LBA，必须加上分区在物理盘上的起始扇区
        part_start = get_partition_start_sector(handle)
        phys_lba = start_lba + part_start
        print(f"分区起始物理扇区: {part_start}  =>  音频物理起始LBA: {phys_lba}")
        print()
        print("请把下面两个值填进 top_tf_hdmi_audio_v2.v 的 sd_card_bmp_v2 实例化参数：")
        print(f"    .WAV_START_LBA     (32'd{phys_lba}),")
        print(f"    .WAV_TOTAL_SECTORS (32'd{total_sectors})")
    finally:
        unlock(handle)
        win32file.CloseHandle(handle)
        print("\n卷已解锁，可以安全弹出SD卡了。")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="FPGA SD卡 WAV裸PCM扇区写入工具")
    parser.add_argument('drive', help='SD卡盘符，例如 E:')
    parser.add_argument('pcm_file', help='已转换好的裸PCM文件路径（16bit/48kHz/单声道/小端序）')
    parser.add_argument('--start-lba', type=int, required=True,
                         help='起始物理扇区号，必须落在FAT32分区范围之外（建议>=140000）')
    args = parser.parse_args()

    write_raw_sectors(args.drive, args.pcm_file, args.start_lba)
