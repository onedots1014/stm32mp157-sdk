#!/usr/bin/env python3
"""
Train a DS-CNN keyword spotting model on precomputed features.

Architecture: DS-CNN-S (ARM ML-KWS-for-MCU style)
  Input: [49, 40, 1] float32 microfrontend features
  → Conv2D(n_filters, 10×4, stride 2×2) + BN + ReLU
  → 4 × DepthwiseSeparableConv(n_filters, 3×3) + BN + ReLU
  → GlobalAveragePool
  → Dense(num_classes)

With n_filters=64: ~23K params → ~23KB int8 weights (fits M4 SRAM1 160KB)
With n_filters=32: ~6K params  → ~6KB  int8 weights (fallback for tight SRAM)

Usage:
    python3 train_dscnn.py [--config config.yaml] [--small]
"""

import argparse
from pathlib import Path

import numpy as np
import yaml


def load_config(path: str) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


# ── DS-CNN model ──────────────────────────────────────────────────────────────
def build_dscnn(num_classes: int, num_frames: int, num_mel: int,
                n_filters: int = 64) -> "tf.keras.Model":
    import tensorflow as tf
    from tensorflow.keras import layers, regularizers

    L2 = 1e-4

    inp = tf.keras.Input(shape=(num_frames, num_mel, 1), name="input")

    # Initial conv (stride 2×2 to downsample time and freq axes)
    x = layers.Conv2D(n_filters, (10, 4), strides=(2, 2), padding="same",
                      use_bias=False,
                      kernel_regularizer=regularizers.l2(L2))(inp)
    x = layers.BatchNormalization()(x)
    x = layers.ReLU()(x)
    x = layers.Dropout(0.2)(x)

    # 4 depthwise-separable conv blocks
    for _ in range(4):
        # Depthwise
        x = layers.DepthwiseConv2D((3, 3), padding="same", use_bias=False,
                                   depthwise_regularizer=regularizers.l2(L2))(x)
        x = layers.BatchNormalization()(x)
        x = layers.ReLU()(x)
        # Pointwise
        x = layers.Conv2D(n_filters, (1, 1), padding="same", use_bias=False,
                          kernel_regularizer=regularizers.l2(L2))(x)
        x = layers.BatchNormalization()(x)
        x = layers.ReLU()(x)
        x = layers.Dropout(0.2)(x)

    x = layers.GlobalAveragePooling2D()(x)
    out = layers.Dense(num_classes, activation="softmax", name="output")(x)

    model = tf.keras.Model(inputs=inp, outputs=out, name="ds_cnn")
    return model


# ── Data loading ──────────────────────────────────────────────────────────────
def load_dataset(feat_dir: Path, classes: list):
    """Load precomputed .npz feature files, return (X, y) arrays."""
    X_all, y_all = [], []
    for cidx, label in enumerate(classes):
        npz_path = feat_dir / f"{label}.npz"
        if not npz_path.exists():
            print(f"  [warn] {npz_path} not found — class '{label}' will be empty")
            continue
        data = np.load(str(npz_path))
        X_all.append(data["X"])
        y_all.append(data["y"])
        print(f"  {label}: {data['X'].shape[0]} samples")

    X = np.concatenate(X_all, axis=0)    # [N, 49, 40]
    y = np.concatenate(y_all, axis=0)    # [N]
    return X, y


def split_dataset(X, y, val_split: float, test_split: float, seed: int = 42):
    rng = np.random.default_rng(seed)
    idx = rng.permutation(len(X))
    n = len(X)
    n_test = int(n * test_split)
    n_val = int(n * val_split)
    test_idx = idx[:n_test]
    val_idx = idx[n_test:n_test + n_val]
    train_idx = idx[n_test + n_val:]
    return (X[train_idx], y[train_idx],
            X[val_idx], y[val_idx],
            X[test_idx], y[test_idx])


# ── Training ──────────────────────────────────────────────────────────────────
def train(config_path: str, use_small: bool = False):
    import tensorflow as tf

    cfg = load_config(config_path)
    base_dir = Path(config_path).parent
    feat_dir = base_dir / "data" / "features"
    model_dir = base_dir / cfg["train"]["model_dir"]
    model_dir.mkdir(parents=True, exist_ok=True)

    classes = cfg["classes"]
    num_classes = len(classes)
    num_frames = cfg["num_frames"]
    num_mel = cfg["num_mel_bins"]

    n_filters = 32 if use_small else cfg["train"]["ds_cnn_filters"]
    print(f"DS-CNN: {n_filters} filters, {num_classes} classes")

    # Load data
    print("\nLoading features...")
    X, y = load_dataset(feat_dir, classes)
    print(f"Total: {len(X)} samples, shape: {X.shape}")

    # Add channel dim and normalize features to [0, 1]
    X_max = X.max()
    if X_max > 0:
        X = X / X_max
    X = X[..., np.newaxis].astype(np.float32)  # [N, 49, 40, 1]
    y = y.astype(np.int32)

    # Save normalization constant for quantization step
    np.save(str(model_dir / "feat_max.npy"), np.float32(X_max))

    # Split
    t_cfg = cfg["train"]
    X_tr, y_tr, X_va, y_va, X_te, y_te = split_dataset(
        X, y, t_cfg["val_split"], t_cfg["test_split"]
    )
    print(f"Train: {len(X_tr)}, Val: {len(X_va)}, Test: {len(X_te)}")

    # Build model
    model = build_dscnn(num_classes, num_frames, num_mel, n_filters)
    model.summary()

    # Class weights to handle imbalance (silence/unknown often over-represented)
    counts = np.bincount(y_tr, minlength=num_classes)
    total = counts.sum()
    class_weights = {i: total / (num_classes * max(c, 1))
                     for i, c in enumerate(counts)}
    print(f"Class weights: {class_weights}")

    # Learning rate schedule
    lr_schedule = tf.keras.optimizers.schedules.ExponentialDecay(
        initial_learning_rate=t_cfg["learning_rate"],
        decay_steps=t_cfg["lr_decay_steps"],
        decay_rate=t_cfg["lr_decay_rate"],
        staircase=True,
    )
    model.compile(
        optimizer=tf.keras.optimizers.Adam(lr_schedule),
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )

    ckpt_path = model_dir / "best_model.keras"
    callbacks = [
        tf.keras.callbacks.ModelCheckpoint(
            str(ckpt_path), save_best_only=True, monitor="val_accuracy",
            verbose=1,
        ),
        tf.keras.callbacks.EarlyStopping(
            patience=10, monitor="val_accuracy", restore_best_weights=True,
        ),
        tf.keras.callbacks.ReduceLROnPlateau(
            monitor="val_loss", factor=0.5, patience=5, min_lr=1e-6,
        ),
    ]

    history = model.fit(
        X_tr, y_tr,
        epochs=t_cfg["epochs"],
        batch_size=t_cfg["batch_size"],
        validation_data=(X_va, y_va),
        class_weight=class_weights,
        callbacks=callbacks,
    )

    # Evaluate on test set
    loss, acc = model.evaluate(X_te, y_te, verbose=0)
    print(f"\nTest accuracy: {acc*100:.1f}%  loss: {loss:.4f}")

    if acc < 0.90:
        print("[warn] Test accuracy < 90% — consider more data or larger model")

    # Save final model (float32 SavedModel for quantization)
    saved_path = model_dir / "saved_model"
    model.save(str(saved_path))
    print(f"Saved: {saved_path}")

    # Per-class accuracy report
    y_pred = np.argmax(model.predict(X_te, verbose=0), axis=1)
    print("\nPer-class accuracy:")
    for cidx, label in enumerate(classes):
        mask = y_te == cidx
        if mask.sum() == 0:
            continue
        cls_acc = (y_pred[mask] == cidx).mean()
        print(f"  {label:20s}: {cls_acc*100:.1f}%  (n={mask.sum()})")

    print("\nDone. Run quantize.py next.")
    return model


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="config.yaml")
    parser.add_argument("--small", action="store_true",
                        help="Use n_filters=32 (< 10KB weights) instead of 64")
    args = parser.parse_args()
    train(args.config, args.small)
