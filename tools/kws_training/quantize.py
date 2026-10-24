#!/usr/bin/env python3
"""
Post-training int8 quantization of the DS-CNN model.

Uses TFLite representative dataset from training features to calibrate
input/output quantization scales. Outputs:
  models/kws_model_quantized.tflite

Verifies:
  - Quantization accuracy drop < 2% vs float model
  - Input tensor dtype = int8 with quantization params

Usage:
    python3 quantize.py [--config config.yaml]
"""

import argparse
from pathlib import Path

import numpy as np
import yaml


def load_config(path: str) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def load_calibration_data(feat_dir: Path, classes: list,
                          n_samples: int = 500) -> np.ndarray:
    """
    Load a balanced subset of training features for calibration.
    Returns float32 array [n_samples, 49, 40, 1] normalized to [0, 1].
    """
    per_class = max(1, n_samples // len(classes))
    X_all = []
    for label in classes:
        npz = feat_dir / f"{label}.npz"
        if not npz.exists():
            continue
        data = np.load(str(npz))["X"]
        idx = np.random.choice(len(data), min(per_class, len(data)), replace=False)
        X_all.append(data[idx])

    X = np.concatenate(X_all, axis=0).astype(np.float32)
    X_max = X.max()
    if X_max > 0:
        X = X / X_max
    return X[..., np.newaxis]  # [N, 49, 40, 1]


def quantize(config_path: str):
    import tensorflow as tf

    cfg = load_config(config_path)
    base_dir = Path(config_path).parent
    model_dir = base_dir / cfg["train"]["model_dir"]
    feat_dir = base_dir / "data" / "features"
    tflite_path = base_dir / cfg["export"]["tflite_path"]
    tflite_path.parent.mkdir(parents=True, exist_ok=True)

    classes = cfg["classes"]
    saved_model_path = model_dir / "saved_model"
    if not saved_model_path.exists():
        raise FileNotFoundError(
            f"{saved_model_path} not found — run train_dscnn.py first"
        )

    # Load calibration data
    print("Loading calibration data...")
    X_cal = load_calibration_data(feat_dir, classes)
    print(f"  {len(X_cal)} samples, shape: {X_cal.shape}")

    # Representative dataset generator
    def representative_dataset():
        for i in range(len(X_cal)):
            yield [X_cal[i:i+1]]

    # Convert to int8 TFLite
    print("Converting to int8 TFLite...")
    converter = tf.lite.TFLiteConverter.from_saved_model(str(saved_model_path))
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.representative_dataset = representative_dataset
    converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
    converter.inference_input_type = tf.int8
    converter.inference_output_type = tf.int8

    tflite_model = converter.convert()
    tflite_path.write_bytes(tflite_model)
    size_kb = len(tflite_model) / 1024
    print(f"  Saved: {tflite_path} ({size_kb:.1f} KB)")

    # ── Verify quantization accuracy ──────────────────────────────────────
    print("\nVerifying accuracy on test set...")

    # Load float model for comparison
    float_model = tf.keras.models.load_model(str(saved_model_path))

    # Load test data
    X_all, y_all = [], []
    for cidx, label in enumerate(classes):
        npz = feat_dir / f"{label}.npz"
        if not npz.exists():
            continue
        data = np.load(str(npz))
        X_all.append(data["X"])
        y_all.append(data["y"])
    X_full = np.concatenate(X_all).astype(np.float32)
    y_full = np.concatenate(y_all).astype(np.int32)
    X_max_val = X_full.max()
    if X_max_val > 0:
        X_full = X_full / X_max_val
    X_full = X_full[..., np.newaxis]

    # Random 20% test split
    rng = np.random.default_rng(42)
    idx = rng.permutation(len(X_full))[:int(0.2 * len(X_full))]
    X_te, y_te = X_full[idx], y_full[idx]

    # Float model accuracy
    y_pred_float = np.argmax(float_model.predict(X_te, verbose=0), axis=1)
    float_acc = (y_pred_float == y_te).mean()
    print(f"  Float model accuracy:  {float_acc*100:.1f}%")

    # Quantized model accuracy
    interpreter = tf.lite.Interpreter(model_content=tflite_model)
    interpreter.allocate_tensors()
    in_detail = interpreter.get_input_details()[0]
    out_detail = interpreter.get_output_details()[0]

    in_scale = in_detail["quantization"][0]
    in_zero_pt = in_detail["quantization"][1]
    out_scale = out_detail["quantization"][0]
    out_zero_pt = out_detail["quantization"][1]

    print(f"\n  Input  quantization: scale={in_scale:.8f} zero_pt={in_zero_pt}")
    print(f"  Output quantization: scale={out_scale:.8f} zero_pt={out_zero_pt}")

    correct = 0
    for i in range(len(X_te)):
        # Quantize input: int8 = round(float / scale) + zero_pt
        x_q = np.clip(
            np.round(X_te[i:i+1] / in_scale) + in_zero_pt, -128, 127
        ).astype(np.int8)
        interpreter.set_tensor(in_detail["index"], x_q)
        interpreter.invoke()
        out_q = interpreter.get_tensor(out_detail["index"])[0]
        # Dequantize: float = (int8 - zero_pt) * scale
        out_f = (out_q.astype(np.float32) - out_zero_pt) * out_scale
        if np.argmax(out_f) == y_te[i]:
            correct += 1
    quant_acc = correct / len(X_te)
    drop = float_acc - quant_acc
    print(f"  Quantized accuracy:    {quant_acc*100:.1f}%  (drop: {drop*100:.1f}%)")

    if drop > 0.02:
        print(f"  [warn] Accuracy drop {drop*100:.1f}% > 2% — "
              "consider more calibration data or re-training")
    else:
        print("  [ok] Accuracy drop within 2% threshold")

    # Save quantization params for export_for_m4.py
    quant_info = {
        "in_scale": float(in_scale),
        "in_zero_pt": int(in_zero_pt),
        "out_scale": float(out_scale),
        "out_zero_pt": int(out_zero_pt),
        "feat_max": float(X_max_val),
    }
    import json
    quant_json = model_dir / "quant_params.json"
    quant_json.write_text(json.dumps(quant_info, indent=2))
    print(f"\n  Saved quant params: {quant_json}")

    print("\nDone. Run export_for_m4.py next.")
    return quant_info


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="config.yaml")
    args = parser.parse_args()
    quantize(args.config)
