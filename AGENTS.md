# AGENTS.md

给在这个仓库里工作的人和 AI 编码助手（Claude Code、Codex、Cursor 等）看的约定。
项目介绍和使用方法见 [README.md](README.md)；这里只写「改代码时必须知道的事」。

## 项目是什么

STM32MP157（2× Cortex-A7 跑 Linux + Cortex-M4 跑 FreeRTOS）的板级支持包。
**不托管上游源码**：ST 官方 release tag + 本仓库的补丁序列，按需拉取、打补丁、构建。

| 组件 | 基线（`scripts/sources.list`） | 本地改动 |
| --- | --- | --- |
| TF-A | `v2.10-stm32mp-r3` | `patches/tf-a/` |
| U-Boot | `v2020.01-stm32mp-r2.2` | `patches/u-boot/` |
| Linux | `v5.4-stm32mp-r2.4` | `patches/linux/` |
| BusyBox | `1_37_0` | `patches/busybox/` |
| M4 固件 | STM32CubeIDE 工程 | `firmware/m4/`（普通源码） |
| 板级配置、rootfs overlay、Buildroot 外部树 | — | `boards/stm32mp157/onedots_stm32mp157/` |

## 改上游代码的唯一方式

```bash
scripts/fetch-sources.sh linux          # sources/linux = 官方 tag + patches/linux/*
cd sources/linux && <修改> && git commit  # 拆分 / 改标题用 git rebase -i
cd ../.. && scripts/export-patches.sh linux
git add patches/linux && git commit
```

- **不要手工编辑 `patches/*.patch`**，也不要直接改 `sources/` 后不导出。`sources/` 被 `.gitignore` 忽略，改了不导出就等于丢了。
- `export-patches.sh` 要求 `sources/<组件>` 基于 `sources.list` 里的 tag、且没有未提交修改；未改动的补丁重新导出不会产生 diff。
- 改完补丁后做一次**往返校验**：重新 `fetch-sources.sh <组件>`，结果应与你的工作分支逐字节一致（`git diff` 为空）。

## 补丁规则

- **一个补丁只做一件事**，提交信息写清「为什么」。厂商代码导入和本地修复必须分开（参考 `linux/0006` 纯厂商导入、`0007` 本地修复）。
- **补丁里不能留调试打印、实验代码、注释掉的旧代码。** 排查过程写进问题记录，不进补丁。
- 新补丁在提交信息末尾标明来源：`Upstream-Status: Backport [<上游 commit>]`、`Submitted [<链接>]`、`Pending` 或 `Inappropriate [board specific]`。
- 上游已经包含的修复，升级基线时直接删掉对应补丁。
- 补丁编号由 `export-patches.sh` 生成；插入或拆分补丁后，README / LICENSE.md 里引用的编号要同步更新。

## 新代码放哪

| 内容 | 放法 |
| --- | --- |
| 修改上游已有文件（bug 修复、DTS、defconfig、时钟） | 补丁 |
| 新增的独立驱动（自己写的或厂商的） | 优先作为外部模块放在仓库里，用 `make -C <内核> M=<目录>` 构建；不要把大段新代码塞进补丁 |
| 用户态程序、服务、配置 | `boards/.../buildroot/`（BR2_EXTERNAL）或 `rootfs-overlay/` |
| M4 固件 | `firmware/m4/` |
| 厂商二进制（WiFi/BT 固件、ST 运行库以外的 blob） | 不进仓库，在 README 里写明从哪获取 |

## 构建与验证

```bash
./build.sh all                 # TF-A → U-Boot → Linux → M4 → FIP → BusyBox → rootfs，产物在 output/<板名>/
./build.sh kernel              # 单独构建：atf | uboot | kernel | busybox | rootfs | m4
./build.sh flash full          # STM32CubeProgrammer 烧写，见 boards/stm32mp157/common/flash/
```

- 交叉工具链：`arm-linux-gnueabi-gcc`；M4 用 STM32CubeIDE 自带工具链（`SRAM1_text` 只有 160 KB，换工具链或 `-O0` 会溢出）。
- Buildroot 路径见 README「Buildroot（可选）」，产物必须与 `build.sh` 的启动链一致。
- **没有上板验证过的改动，提交信息和 README 里要写明「未上板验证」。** 只编译通过不等于修好了。

## 容易写错的硬件事实

这些在旧文档里错过，改代码或写文档前以此为准：

- **启动链是 AArch32**：BootROM → TF-A BL2 → **SP_MIN（BL32，Monitor 模式常驻，提供 PSCI/SCMI）** → U-Boot（BL33）→ Linux。没有 BL31、没有 EL3 这些 AArch64 概念；没有集成 OP-TEE。
- **板上没有 PMIC**（分立 DC-DC）：最深只能到 s2idle，LPLV-Stop / Standby 物理不可达。
- **SAI1 音频**：PB2 = `SAI1_SD_A`（A7 放音 → WM8960 DACDAT），PF6 = `SAI1_SD_B`（WM8960 ADCDAT → M4 采音），PF7/PF8/PF9 = MCLK_B/SCK_B/FS_B。SAI1_B 是时钟主，SAI1_A 通过 `st,sync` 跟随。原理图音频页的网络名标反了，不要照抄。
- **PF3** 在原理图上接 WM8960 的 ADCLRC/GPIO1，但 Linux DTS 把它放在 `wifi_fixed_pins_a` 里输出低，待上板时移除。
- **RCC 的 MP/MC 两套使能**：M4 用到的外设时钟只开 MC 侧，A7 睡眠时可能被关掉。
- **DMA1 由 M4 独占**：Linux DTS 禁用了 `dma1`，否则 s2idle 会因通道 0 忙而失败。
- Linux 是 ST 分支，不是主线；rootfs 是 BusyBox init，不是 systemd。

## 提交与 PR

- 提交信息用英文，`<组件>: <做了什么>`，正文写为什么和怎么验证的。
- 不提交：`sources/`、`output/`、`.config`、构建产物、厂商固件、任何密钥或 WiFi 密码（`wpa_supplicant.conf` 里保持 `YOUR_SSID` / `YOUR_PASSWORD` 占位）。

## 排查记录（维护者）

排查过程、实测数据和待办记在维护者的 Notion（私有，外部人员打不开）：

- 项目页：https://app.notion.com/p/400249a2411481bd82b6c94e374387bb
- 问题记录：https://app.notion.com/p/400249a241148124880ac33f70540aa0（标题以 `[MP157]` 开头，按页面里的模板写）

解决一个值得记录的问题后，新建一条问题记录，并更新项目页的待办。
