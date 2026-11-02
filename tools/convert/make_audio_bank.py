"""
FPGA 多段WAV音频打包工具（配合拨码开关切换曲目）

把三段任意格式的WAV（采样率/声道不限）用ffmpeg转成 wav_stream_player.v 要求的
裸PCM（16位有符号、小端序、48kHz、单声道，无文件头），每段按扇区对齐后依次
拼成一个 bank 文件，再用 sync_audio_to_sd.py 一次性写入TF卡。

段内顺序（与 sd_card_bmp_v2.v 参数对应）：
    段0 背景音乐  -> WAV_START_LBA        / WAV_TOTAL_SECTORS          （拨码全关）
    段1 报警音1   -> WAV_ALARM1_START_LBA / WAV_ALARM1_TOTAL_SECTORS   （SW1/SW2/SW1+SW2）
    段2 报警音2   -> WAV_ALARM2_START_LBA / WAV_ALARM2_TOTAL_SECTORS   （SW3）

用法：
    python make_audio_bank.py 背景.wav 报警1.wav 报警2.wav -o audio_bank.pcm
    python sync_audio_to_sd.py E: audio_bank.pcm --start-lba 140000

本脚本按 --start-lba 与 --part-start（分区起始物理扇区，默认8192）预先算出
三段的物理LBA；写卡后请核对 sync_audio_to_sd.py 打印的"分区起始物理扇区"
是否与 --part-start 一致，不一致就用实际值重跑本脚本取参数。
"""

import argparse
import os
import subprocess
import sys

SECTOR_SIZE = 512
ALIGN_SECTORS = 8          # 每段起点按8扇区(4KB)对齐，便于核对
SAMPLE_RATE = 48000


def wav_to_pcm(path):
    """调用ffmpeg转码为48kHz单声道s16le裸PCM，返回bytes"""
    cmd = ["ffmpeg", "-v", "error", "-i", path,
           "-ar", str(SAMPLE_RATE), "-ac", "1",
           "-f", "s16le", "-acodec", "pcm_s16le", "-"]
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        print(f"[错误] ffmpeg转码失败: {path}\n{result.stderr.decode(errors='replace')}")
        sys.exit(1)
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description="FPGA 多段WAV音频打包工具")
    parser.add_argument("bgm", help="段0：背景音乐（拨码全关时循环播放）")
    parser.add_argument("alarm1", help="段1：SW1/SW2/SW1+SW2 拨上时播放")
    parser.add_argument("alarm2", help="段2：SW3 拨上时播放")
    parser.add_argument("-o", "--output", default="audio_bank.pcm", help="输出bank文件")
    parser.add_argument("--start-lba", type=int, default=140000,
                        help="bank写入的卷内起始扇区（与sync_audio_to_sd.py的--start-lba一致）")
    parser.add_argument("--part-start", type=int, default=8192,
                        help="分区起始物理扇区（以sync_audio_to_sd.py打印值为准）")
    args = parser.parse_args()

    names = ["WAV", "WAV_ALARM1", "WAV_ALARM2"]
    bank = bytearray()
    params = []
    for name, path in zip(names, [args.bgm, args.alarm1, args.alarm2]):
        if not os.path.isfile(path):
            print(f"[错误] 找不到文件: {path}")
            sys.exit(1)
        pcm = wav_to_pcm(path)
        sectors = (len(pcm) + SECTOR_SIZE - 1) // SECTOR_SIZE
        offset = len(bank) // SECTOR_SIZE
        bank += pcm
        # 段尾补0到扇区边界，再补到下一段的对齐起点
        bank += b"\x00" * (sectors * SECTOR_SIZE - len(pcm))
        aligned = (len(bank) // SECTOR_SIZE + ALIGN_SECTORS - 1) // ALIGN_SECTORS * ALIGN_SECTORS
        bank += b"\x00" * (aligned * SECTOR_SIZE - len(bank))
        phys = args.part_start + args.start_lba + offset
        params.append((name, phys, sectors))
        print(f"{os.path.basename(path)}: {len(pcm) / 2 / SAMPLE_RATE:.2f}秒, "
              f"{sectors}扇区, bank内偏移{offset}扇区, 物理LBA {phys}")

    with open(args.output, "wb") as f:
        f.write(bank)
    print(f"\n已生成 {args.output}: {len(bank)} 字节 ({len(bank) // SECTOR_SIZE} 扇区)")
    print(f"卷内占用扇区 {args.start_lba} ~ {args.start_lba + len(bank) // SECTOR_SIZE - 1}")
    print("\n请把下面的值填进 top_tf_hdmi_audio_v2.v 的 sd_card_bmp_v2 实例化参数：")
    for name, phys, sectors in params:
        print(f"    .{name}_START_LBA     (32'd{phys}),")
        print(f"    .{name}_TOTAL_SECTORS (32'd{sectors}),")


if __name__ == "__main__":
    main()
