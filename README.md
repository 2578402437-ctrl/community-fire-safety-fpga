# 社区消防安全宣传与紧急预警系统（FPGA）

基于安路 EG4S20BG256 的多媒体播放系统：从 TF 卡读取 BMP 图片与 PCM 音频，经 SDRAM 帧缓存，叠加导航栏、字幕、调节界面等图层后，通过 HDMI 1.4b 输出 640×480@60Hz 视频与 48 kHz 音频。

- 开发工具：安路 TD 6.2.1
- 仿真工具：ModelSim
- 顶层模块：`top`（`src/user_source/hdl_source/top/top_tf_hdmi_audio_v2.v`）

## 功能

| 功能 | 说明 |
|---|---|
| 图片浏览 | 读取 TF 卡根目录 `PIC1~PIC4.BMP`，任意分辨率加载时缩放到 640×480 |
| 转场 | 新图在后台预加载后与旧图双路合成，10 种转场按次轮换，不经过黑屏 |
| 缩略图 | 2×2 缩略图浏览，焦点移动，选中后硬切 |
| 自动播放 | 定时切图；当前图片有栏目语音时，在语音间隔切图 |
| 导航栏与字幕 | 顶部四栏目导航栏（消防员小人走到目标栏目），下方分栏目滚动字幕 |
| 亮度 / 音量 | KEY3 调节，16 档；停止操作 2 s 后写入板载 SPI Flash，掉电保存 |
| 紧急预警 | 拨码开关选择 `SW*.BMP` 直显并播放报警音，警示元素与画面红框闪烁 |
| 开机动画 | 背景图上消防员走入并挥手，同时播放开机问候语音 |
| 音频 | 背景音乐、栏目宣传语音、报警音流式播放，叠加切图提示音、脚步声，转场时音量包络 |
| 故障提示 | SD 卡持续初始化失败时整屏显示片上 ROM 提示图 |
| 状态显示 | 6 位数码管显示图片编号、播放状态与错误码 |

## 按键与拨码

| 输入 | 全屏模式 | 缩略图模式 |
|---|---|---|
| KEY1 短按 | 下一张 | 焦点右移 |
| KEY1 长按 | 进入缩略图 | 退出缩略图 |
| KEY2 短按 | 自动播放开/关 | 确认选中 |
| KEY2 长按 | 上一张 | 焦点左移 |
| KEY3 短按 | 循环切换：正常 → 亮度 → 音量 → 正常 | — |
| KEY3 长按 | 亮度/音量模式下每 500 ms 升一档，15 档后回到 0 | — |
| SW1 / SW2 / SW1+SW2 | 显示 `SW1.BMP` / `SW2.BMP` / `SW12.BMP`，播放报警音 1 | |
| SW3 | 显示 `SW3.BMP`，播放报警音 2（优先级最高） | |
| SW4 | 显示音频波形 | |

## 目录结构

```
.
├── README.md
├── src/
│   ├── td_project/                    TD 工程
│   │   ├── HDMI1.4b_Transmitter_v1.0.al   工程文件（源文件列表、器件、顶层）
│   │   └── fast_build.sh                  命令行综合 + 多种子并行布局布线脚本
│   └── user_source/
│       ├── constraints_source/        引脚约束 pin.adc、时序约束 timing.sdc、ChipWatcher 配置
│       └── hdl_source/
│           ├── top/                   系统顶层
│           ├── common/                复位同步、跨时钟域同步、上电脉冲
│           ├── ctrl/                  按键四层架构前两层、数码管、Flash 掉电保存
│           ├── sd/                    SD 卡 SPI 驱动、FAT32 解析、媒体策略与执行层
│           ├── memory/                SDRAM 控制器封装、帧缓存读写通道
│           ├── video/                 视频时序、转场、缩略图、BMP 缩放
│           ├── osd/                   24 位 RGB 叠加图层
│           ├── audio/                 音频节拍、音源、包络、WAV 流式播放、脚步声
│           ├── hdmi/                  RGB 转 AXI-Stream、ACR、TMDS 串行化、HDMI 发送核
│           ├── ip/                    TD IP：PLL、异步 FIFO
│           ├── include/               SDRAM 控制核与宏定义（加密核引用固定路径，勿移动）
│           └── rom/                   ROM 初始化文件（$readmemh）
├── sim/                               ModelSim testbench、参考模型与运行脚本
├── tools/convert/                     图片/字库/ROM/音频生成与 SD 卡写入脚本
└── assets/                            TF 卡图片与音频素材
```

## 模块层次

```
top
├── sys_pll / video_pll                时钟
├── sd_card_bmp_v2                     SD 卡媒体播放子系统
│   ├── dual_key_chord_router          按键第一层：消抖、事件
│   ├── dual_key_long_hold_guard       按键第二层：长按保护、状态
│   ├── media_policy                   按键第三层：策略
│   ├── media_player_control           按键第四层：执行（切图、预加载、转场、自动播放）
│   ├── thumbnail_controller           缩略图交互
│   ├── level_flash_store              亮度/音量掉电保存
│   ├── fat32_volume_scanner           FAT32 卷扫描、资源查找
│   ├── fat32_file_streamer            文件流式读取
│   ├── bmp_scaler_640x480             BMP 缩放
│   ├── wav_stream_player              PCM 流式播放
│   ├── sd_sector_adapter              扇区接口适配
│   └── sd_card_top                    SD 卡 SPI 驱动（sd_card_sec_read_write / sd_card_cmd / spi_master）
├── frame_read_write                   帧缓存（frame_fifo_write / frame_fifo_read）
├── sdram                              SDRAM 控制器（sdr_as_ram）
├── video_timing_data / video_delay    视频时序与对齐
├── video_fade_transition              转场控制
├── transition_shape_mask_24           转场双路合成
├── thumbnail_view                     缩略图显示（thumbnail_layout）
├── fireman_nav_bar_24 … sd_fallback_overlay_24   叠加图层（见视频链路）
├── pcm_media_tone / audio_source_mux / sync_fade_gain / footstep_synth   音频
├── audio_sample_tick_gen              48 kHz 采样节拍
├── audio_arc_calculate                HDMI ACR
├── video_rgb_to_axis_640x480          视频转 AXI-Stream
├── hdmi_1_4b_transmitter_core_wrapper HDMI 1.4b 发送核（加密）
├── hdmi_phy_wrapper                   TMDS 串行化（lane_lvds_10_1）
└── seg_decoder / seg_scan             数码管
```

## 时钟域

| 时钟 | 频率 | 来源 | 用途 |
|---|---|---|---|
| clk | 50 MHz | 板载晶振 | PLL 输入 |
| sd_card_clk | 100 MHz | sys_pll | SD 卡、FAT32、媒体控制、Flash |
| ext_mem_clk / ext_mem_clk_sft | 125 MHz | sys_pll | SDRAM 及其相移时钟 |
| video_clk | 25 MHz | video_pll | 像素时钟、叠加图层、HDMI 音频 |
| hdmi_5x_clk | 125 MHz | video_pll | TMDS 串行时钟 |

跨时钟域：单比特电平用 `sync_2ff` 两级同步，多比特慢变量两级打拍后按帧一致采样，帧缓存经异步 FIFO 隔离。

## 视频链路

```
SDRAM ─ frame_fifo_read（A/B 双路）─ video_delay
  → transition_shape_mask_24   转场双路合成
  → thumbnail_view             缩略图着色
  → KEY3 亮度乘法
  → fireman_nav_bar_24         导航栏（在亮度之后叠加，不受亮度调节影响）
  → scroll_subtitle_24         滚动字幕
  → brightness_bar_24          亮度/音量调节界面
  → promax_audio_waveform      音频波形
  → emergency_element_flash_24 紧急元素闪烁
  → fireman_intro_24           开机动画
  → sd_fallback_overlay_24     SD 卡故障提示
  → video_rgb_to_axis_640x480 → HDMI 发送核 → hdmi_phy_wrapper
```

各叠加图层为组合叠加，不增加像素流水延迟，保证与 HDMI 数据岛调度依赖的行场对齐。

## 音频链路

```
wav_stream_player（SD 卡 PCM）┐
pcm_media_tone（提示音/琶音）  ┴→ audio_source_mux → 转场音量包络 → KEY3 音量 → + footstep_synth → HDMI 音频
```

采样节拍由 `audio_sample_tick_gen` 在 video_clk 域经 NCO 分频得到 48 kHz，与像素时钟同源，ACR 的 CTS 为常数（N=6144，CTS=25000）。

## TF 卡内容

FAT32 格式，根目录文件（8.3 文件名）：

| 文件 | 说明 |
|---|---|
| `PIC1.BMP` ~ `PIC4.BMP` | 浏览图片，24 位 BMP，任意分辨率 |
| `SW1.BMP` `SW2.BMP` `SW3.BMP` `SW12.BMP` | 拨码紧急场景图（可选） |
| `BG.BMP` | 开机动画背景（可选） |

音频以裸 PCM（48 kHz、16 位、单声道、小端）写在卷内固定扇区，起始物理 LBA 与扇区数由顶层 `sd_card_bmp_v2` 例化参数 `WAV_*_START_LBA` / `WAV_*_TOTAL_SECTORS` 指定，物理 LBA = 卷内偏移 + 分区起始扇区 8192：

| 音频段 | 生成脚本 |
|---|---|
| 背景音乐、报警音 1、报警音 2 | `tools/convert/make_audio_bank.py` → `audio_bank.pcm` |
| 四个栏目的背景乐 + 宣传语音 | `tools/convert/voice_column/make_column_audio.py` 混音 → `pack_and_probe.py` 打包成 `col_bank.pcm` |
| 开机问候 | 背景乐 + 问候语音预混的 48 kHz 单声道 16 位 PCM，用 `sync_audio_to_sd.py` 写入 |

各段 PCM 均用 `sync_audio_to_sd.py` 写入卡上对应扇区。

## 编译

1. 用 TD 6.2.1 打开 `src/td_project/HDMI1.4b_Transmitter_v1.0.al`。
2. 依次运行综合、布局布线、生成 bit 流，产物在 `HDMI1.4b_Transmitter_v1.0_Runs/` 下。
3. 也可以在 Git Bash 中运行 `sh src/td_project/fast_build.sh`：综合后用多个布局种子并行布线，自动挑选时序最好的结果。源文件列表取自 TD 上次综合生成的 `.prj`，增删源文件后须先在 TD 中综合一次。

ROM 初始化文件路径相对 `td_project/HDMI1.4b_Transmitter_v1.0_Runs/syn_1`，`include/` 目录被加密核按固定相对路径引用，两者都不要移动。

## 仿真

每个 `sim/` 子目录是一个独立测试，包含 testbench（`tb_*.v`）、参考模型或比对脚本（`*.py`）以及运行脚本（`*.sh`）。例如顶层展开检查：

```sh
cd sim/l66_level_flash
sh elab.sh        # 按 top_list.txt 编译全部源文件，vsim 加载 top 检查端口连接
```

## 工具脚本

脚本均在 `tools/convert/` 下。依赖：Python 3、Pillow、NumPy；音频转码与混音需要 `ffmpeg`；直接读写 SD 卡扇区的脚本需要 Windows 管理员权限与 `pywin32`。

| 脚本 | 用途 |
|---|---|
| `convert_images_to_bmp.py` | 图片转 24 位 BMP |
| `make_nav_assets.py` | 导航栏小人、栏目标签、字幕字库 ROM |
| `make_subtitle_font.py` / `make_brightness_font.py` | 字幕、调节界面点阵 |
| `make_fallback_1bit.py` | SD 卡故障提示图 ROM |
| `make_audio_bank.py` | 背景音乐与报警音打包 |
| `voice_column/make_column_audio.py` | 栏目背景乐与宣传语音混音 |
| `voice_column/pack_and_probe.py` | 四段栏目音频打包，并只读核对卡上目标扇区是否空闲 |
| `sync_to_sd.py` / `sync_audio_to_sd.py` | 图片、音频写入 SD 卡 |
