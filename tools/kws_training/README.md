# KWS Training Pipeline

从 TTS 合成音频到 M4 可部署模型的完整流水线，用于识别中文唤醒词 "小王"。

## 环境准备

```bash
cd tools/kws_training
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# 需要系统安装 ffmpeg（用于 MP3 → WAV 转换）
sudo apt install ffmpeg
```

> Python 3.10+ 推荐。TensorFlow 2.15 需要 Python <= 3.11。

## 快速开始（完整流程）

```bash
# 1. 合成数据集
python3 synth_dataset.py          # 约 30-60 分钟（取决于网络）

# 2. 数据增强
python3 augment.py                # 加噪、变速

# 3. 提取特征（匹配 M4 microfrontend）
python3 prepare_features.py       # 约 10-30 分钟

# 4. 训练 DS-CNN
python3 train_dscnn.py            # 约 30-60 分钟（CPU）

# 5. 量化
python3 quantize.py               # < 5 分钟

# 6. 导出到 M4
python3 export_for_m4.py          # 需要 stedgeai CLI
```

---

## 详细说明

### Step 1: synth_dataset.py — TTS 音频合成

使用 [Edge-TTS](https://github.com/rany2/edge-tts) 调用 Microsoft 神经语音，生成多发音人、多语速的 "小王" 训练样本。

**输出目录：**
```
data/synth/
├── xiao_wang/         # ~3000 条 "小王" WAV
├── unknown/           # ~3000 条其他中文词
│   ├── unknown_nxxx/
│   └── ...
└── silence/           # 1000 条低幅度噪声片段
```

**参数（config.yaml → synth 节）：**
- `voices`：6 个中文神经语音
- `count_per_voice`：每个语音合成 500 条
- `rate_range`：语速随机偏移 ±15%

### Step 2: augment.py — 数据增强

对合成音频添加背景噪声、时间伸缩。

- 背景噪声：优先读 `data/noise/*.wav`；若不存在则自动生成粉红噪声
- SNR 范围：-20 dB 到 0 dB
- 每个源文件生成 3 条增强版本（`augment_factor=3`）

**建议**：把你自己录的背景噪声（工厂噪声、风扇声、说话声等）放到 `data/noise/` 中，可显著提升真实麦克风上的识别率。

### Step 3: prepare_features.py — 特征提取

使用与 M4 完全相同的参数提取 log-Mel 特征。

**优先级：**
1. `tf.lite.experimental.microfrontend`（调用与 M4 相同的 C 代码）→ 完全匹配
2. numpy 实现（近似，在 TF 不支持时使用）→ 约 95% 精度

**输出：**
```
data/features/
├── silence.npz      # X: [N, 49, 40]  float32
├── unknown.npz
└── xiao_wang.npz
```

**⚠️ 关键约束：** `config.yaml` 中的特征参数必须与 `stm32_m4/CM4/Core/Src/kws_frontend.c` **完全一致**。任何参数差异都会造成训练-推理失配，严重影响识别率。

### Step 4: train_dscnn.py — DS-CNN 训练

DS-CNN-S 架构（参考 ARM ML-KWS-for-MCU 论文）：

```
输入 [49, 40, 1]
→ Conv2D(64, 10×4, stride 2×2) + BN + ReLU + Dropout(0.2)
→ DepthwiseSepConv(64, 3×3) × 4 + BN + ReLU + Dropout(0.2)
→ GlobalAveragePool
→ Dense(3)  # num_classes
```

| 配置 | n_filters | 参数量 | int8 权重 |
|------|-----------|--------|-----------|
| 默认 | 64        | ~23K   | ~23 KB    |
| small（`--small`）| 32 | ~6K | ~6 KB |

**内存预算参考（M4 SRAM1 = 160 KB）：**
- 激活区：约 12-20 KB（视 X-CUBE-AI 优化）
- 权重：20-60 KB（取决于配置）
- FreeRTOS 堆：32 KB
- 合计需控制在 140 KB 以内

如 X-CUBE-AI 报内存溢出，改用 `--small` 或减小 `ds_cnn_filters`。

**训练预期指标：**
- val_acc > 95%（合成数据集）
- 真实麦克风验证集 acc > 85%

### Step 5: quantize.py — 训练后 int8 量化

使用 TFLite Post-Training Quantization（PTQ），以训练集作为校准数据集。

输出：
- `models/kws_model_quantized.tflite`
- `models/quant_params.json`（量化参数，供 export_for_m4.py 使用）

验证：量化精度损失应 < 2%。

### Step 6: export_for_m4.py — 导出到 M4

**A. X-CUBE-AI 代码生成**

需要安装 [X-CUBE-AI 9.x](https://www.st.com/en/embedded-software/x-cube-ai.html)，或通过 STM32CubeIDE 的 X-CUBE-AI 插件转换。

如没有 `stedgeai` CLI，可跳过：
```bash
python3 export_for_m4.py --skip-cubeai
```
然后手动在 STM32CubeIDE 中导入 `models/kws_model_quantized.tflite`，生成代码后替换 `stm32_m4/micro_speech/network.c` 和 `network_data.c`。

**B. 自动生成的文件**

```
stm32_m4/CM4/Core/Inc/kws_model_meta.h          # M4 模型元数据头文件
boards/.../rootfs-overlay/etc/kws/labels.json    # CA7 标签映射
```

`kws_model_meta.h` 包含：
- `KWS_NUM_CLASSES`、`KWS_CLASS_*` 宏
- `kws_class_labels[]` 字符串数组
- `KWS_TRIGGER_CLASS_MASK` 触发掩码
- 量化参数（`KWS_IN_SCALE_INV_x1000` 等）

---

## 采集真实样本（推荐）

纯 TTS 合成的数据通常会在真实麦克风上出现 5-15% 的精度下降。建议：

```bash
# 在开发机上录 200 条 "小王" 真实样本
python3 record_samples.py --keyword xiao_wang

# 在板上录（通过 SSH 连接）
python3 record_samples.py --keyword xiao_wang --board
```

录完后重新运行 Step 3-6 即可将真实样本加入训练。

---

## 验证流程（端到端）

```bash
# 1. 烧录新固件并启动开发板
./build.sh flash full

# 2. SSH 进入开发板，检查 M4 状态
dmesg | grep remoteproc
pgrep -f kws_listener.py

# 3. 实时查看日志
tail -f /var/log/kws.log

# 4. 测试
# 说 "小王"  → 期望日志: WAKE class_id=2 label='xiao_wang' conf=85+
# 说 "你好"  → 期望: 无触发
# 保持安静  → 期望: 60s 内无误触发
```

---

## 常见问题

### `import edge_tts` 报错
```bash
pip install edge-tts --upgrade
```

### ffmpeg 不存在
```bash
sudo apt install ffmpeg
```

### TF microfrontend op 不可用
这不是错误，会自动切换到 numpy fallback。若要精确匹配：
```bash
pip install tflite-support
```

### X-CUBE-AI 不可用
使用 `--skip-cubeai`，然后在 STM32CubeIDE 中手动转换。

### 模型 SRAM1 溢出
```bash
python3 train_dscnn.py --small
python3 quantize.py && python3 export_for_m4.py
```

### 真实麦克风识别率低（< 70%）
1. 录制更多真实样本（`record_samples.py`）
2. 增加来自目标环境的背景噪声（放到 `data/noise/`）
3. 检查采样率是否匹配（arecord 默认可能是 44.1kHz，需要 16kHz）
