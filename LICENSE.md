# 许可证说明

本仓库包含来源不同的内容，各自适用的许可证如下。

| 路径 | 许可证 |
| --- | --- |
| `patches/linux/` | GPL-2.0（与 Linux 内核一致）；`0006` 中的 Broadcom bcmdhd 驱动按其文件头所述，以 GPL-2.0 提供 |
| `patches/u-boot/` | GPL-2.0+（与 U-Boot 一致） |
| `patches/tf-a/` | BSD-3-Clause（与 Trusted Firmware-A 一致） |
| `firmware/m4/Drivers/`、`firmware/m4/Middlewares/` | 以各目录内 LICENSE 文件为准（ST CMSIS / HAL、OpenAMP、libmetal 等） |
| `firmware/m4/**/NetworkRuntime1200_CM4_GCC.a` | ST 软件包许可协议 SLA0104（同目录 `LICENSE.txt`），**不属于**本仓库的开源许可范围，不得以任何开源许可再分发 |
| `firmware/m4/micro_speech/`、`firmware/m4/CM4/micro_speech/` | 同目录 `LICENSE.txt` 所述（X-CUBE-AI 生成代码） |
| `app/sample_led/` | 基于百问网（100ASK）教程示例改写；`led_drv.c` 为内核模块，GPL（见 `MODULE_LICENSE`） |
| 其余原创内容（`build.sh`、`boards/`、`scripts/`、`app/kws_listener.py`、`tools/`、`docs/`、`firmware/m4` 中的原创源文件） | MIT，见下文 |

## MIT License

Copyright (c) 2026 onedots

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
