#!/usr/bin/env python3
"""
Feature extraction matching the M4 microfrontend (kws_frontend.c) exactly.

Strategy:
  1. Use tf.lite.experimental.microfrontend (TF op that calls the same C code)
     if available → exact match with M4.
  2. Fall back to a numpy approximation if the TF op is unavailable.

Outputs:
  data/features/{label}.npz  with keys 'X' (float32, shape [N,49,40])
                              and 'y' (int32, class index)

Usage:
    python3 prepare_features.py [--config config.yaml]
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
import yaml
from tqdm import tqdm

# ── Try to import the TF Micro microfrontend op ───────────────────────────────
_TF_FRONTEND_AVAILABLE = False
try:
    import tensorflow as tf
    from tensorflow.lite.experimental.microfrontend.python.ops import (
        audio_microfrontend_op as _mf_op,
    )
    _TF_FRONTEND_AVAILABLE = True
    print("[prepare_features] Using TF Micro microfrontend op (exact M4 match)")
except Exception:
    print("[prepare_features] TF microfrontend op unavailable — using numpy fallback")


def load_config(path: str) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


# ── TF-based microfrontend (exact C match) ────────────────────────────────────
def extract_tf_frontend(audio_int16: np.ndarray, cfg: dict) -> np.ndarray:
    """
    Extract features via tf.lite.experimental.microfrontend.
    Returns float32 array [num_frames, num_mel_bins] (uint16 values as float).
    """
    nr = cfg["noise_reduction"]
    pcan = cfg["pcan"]
    log = cfg["log_scale"]

    tensor = tf.constant(audio_int16, dtype=tf.int16)
    kwargs = dict(
        sample_rate=cfg["sample_rate"],
        window_size=cfg["window_ms"],
        window_step=cfg["stride_ms"],
        num_channels=cfg["num_mel_bins"],
        upper_band_limit=cfg["mel_high_hz"],
        lower_band_limit=cfg["mel_low_hz"],
        smoothing_bits=nr["smoothing_bits"],
        even_smoothing=nr["even_smoothing"],
        odd_smoothing=nr["odd_smoothing"],
        min_signal_remaining=nr["min_signal_remaining"],
        enable_pcan=pcan["enable"],
        pcan_strength=pcan["strength"],
        pcan_offset=pcan["offset"],
        gain_bits=pcan["gain_bits"],
        enable_log=log["enable"],
        scale_shift=log["scale_shift"],
    )
    output = _mf_op.audio_microfrontend(tensor, **kwargs)
    # output shape: [num_frames, num_mel_bins], dtype uint16
    return output.numpy().astype(np.float32)


# ── Numpy fallback microfrontend ───────────────────────────────────────────────
class _NumpyFrontend:
    """
    Streaming microfrontend approximating kws_frontend.c.
    Processes audio stride by stride, maintaining noise/PCAN state.
    """

    def __init__(self, cfg: dict):
        sr = cfg["sample_rate"]
        self.window_n = int(cfg["window_ms"] * sr / 1000)   # 480
        self.stride_n = int(cfg["stride_ms"] * sr / 1000)   # 320
        self.fft_size = cfg.get("fft_size", 512)
        n_mel = cfg["num_mel_bins"]

        # Periodic Hann window (matches C: w[n] = 0.5 - 0.5*cos(2π*n/N))
        ns = np.arange(self.window_n)
        self.hann = (0.5 - 0.5 * np.cos(2.0 * np.pi * ns / self.window_n)
                     ).astype(np.float64)

        # Build triangular Mel filterbank (HTK mel scale, matches filterbank.c)
        def hz_to_mel(hz):
            return 2595.0 * np.log10(1.0 + hz / 700.0)
        def mel_to_hz(m):
            return 700.0 * (10.0 ** (m / 2595.0) - 1.0)

        mel_pts = np.linspace(hz_to_mel(cfg["mel_low_hz"]),
                              hz_to_mel(cfg["mel_high_hz"]), n_mel + 2)
        hz_pts = mel_to_hz(mel_pts)
        n_fft_bins = self.fft_size // 2 + 1
        fft_freqs = np.fft.rfftfreq(self.fft_size, 1.0 / sr)

        self.mel_w = np.zeros((n_fft_bins, n_mel), dtype=np.float64)
        for i in range(n_mel):
            lo, ctr, hi = hz_pts[i], hz_pts[i + 1], hz_pts[i + 2]
            for j in range(n_fft_bins):
                f = fft_freqs[j]
                if lo < f <= ctr:
                    self.mel_w[j, i] = (f - lo) / (ctr - lo)
                elif ctr < f < hi:
                    self.mel_w[j, i] = (hi - f) / (hi - ctr)

        nr = cfg["noise_reduction"]
        self.nr_even = float(nr["even_smoothing"])
        self.nr_odd = float(nr["odd_smoothing"])
        self.nr_min = float(nr["min_signal_remaining"])

        p = cfg["pcan"]
        self.pcan_en = p["enable"]
        self.pcan_str = float(p["strength"])
        self.pcan_off = float(p["offset"])
        self.pcan_scale = float(2 ** p["gain_bits"])

        ls = cfg["log_scale"]
        self.log_en = ls["enable"]
        # log_scale_shift=6 → integer log output divided by 2^6 in C (Q15 log2)
        # Approximation: output = log2(max(1, pcan)) * (2^15 / 2^scale_shift)
        self.log_coeff = float(2 ** 15) / float(2 ** ls["scale_shift"])

        self.n_mel = n_mel
        self.noise_est = np.zeros(n_mel, dtype=np.float64)
        self.buf = np.zeros(self.window_n, dtype=np.float64)

    def reset(self):
        self.noise_est[:] = 0.0
        self.buf[:] = 0.0

    def _process_stride(self, samples_float64: np.ndarray) -> np.ndarray:
        """Process one stride, return uint16 feature vector."""
        # Slide buffer
        self.buf[:self.window_n - self.stride_n] = self.buf[self.stride_n:]
        n = min(len(samples_float64), self.stride_n)
        self.buf[self.window_n - self.stride_n:
                 self.window_n - self.stride_n + n] = samples_float64[:n]

        # Hann window + FFT → power
        fft_out = np.fft.rfft(self.buf * self.hann, n=self.fft_size)
        power = np.real(fft_out) ** 2 + np.imag(fft_out) ** 2

        # Mel filterbank
        mel = power @ self.mel_w

        # Noise reduction (exponential moving average per bin, even/odd rates)
        alpha = np.where(np.arange(self.n_mel) % 2 == 0,
                         self.nr_even, self.nr_odd)
        self.noise_est += alpha * (mel - self.noise_est)
        min_sig = self.noise_est * self.nr_min
        signal = np.maximum(mel - self.noise_est, min_sig)

        # PCAN gain control
        if self.pcan_en:
            gain_in = self.noise_est + self.pcan_off
            pcan_out = signal * self.pcan_scale / (gain_in ** self.pcan_str + 1e-9)
        else:
            pcan_out = signal

        # Log scale (approximates C's Q15 integer log2 >> scale_shift)
        if self.log_en:
            out = np.log2(np.maximum(1.0, pcan_out)) * self.log_coeff
        else:
            out = pcan_out

        return np.clip(np.round(out), 0, 65535).astype(np.uint16)

    def audio_to_frames(self, audio_float: np.ndarray, num_frames: int
                        ) -> np.ndarray:
        """
        Convert float32 audio [-1, 1] to [num_frames, n_mel] float32.
        """
        self.reset()
        audio_f64 = audio_float.astype(np.float64)

        # Warm up the noise estimator with leading silence
        silence = np.zeros(self.stride_n, dtype=np.float64)
        for _ in range(8):
            self._process_stride(silence)

        frames = []
        pos = 0
        while len(frames) < num_frames:
            chunk = (audio_f64[pos:pos + self.stride_n]
                     if pos + self.stride_n <= len(audio_f64)
                     else np.zeros(self.stride_n, dtype=np.float64))
            feat_u16 = self._process_stride(chunk)
            frames.append(feat_u16.astype(np.float32))
            pos += self.stride_n

        return np.stack(frames[:num_frames])  # [num_frames, n_mel]


_numpy_fe: "_NumpyFrontend | None" = None


def extract_numpy_frontend(audio_float: np.ndarray, cfg: dict) -> np.ndarray:
    global _numpy_fe
    if _numpy_fe is None:
        _numpy_fe = _NumpyFrontend(cfg)
    return _numpy_fe.audio_to_frames(audio_float, cfg["num_frames"])


# ── Public API ────────────────────────────────────────────────────────────────
def extract_features(wav_path: Path, cfg: dict) -> np.ndarray:
    """
    Extract [num_frames, num_mel_bins] float32 feature matrix from a WAV file.
    Uses TF microfrontend op when available, otherwise numpy approximation.
    """
    sr = cfg["sample_rate"]
    num_frames = cfg["num_frames"]

    audio, file_sr = sf.read(str(wav_path), dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)

    if file_sr != sr:
        from scipy.signal import resample_poly
        gcd = np.gcd(sr, file_sr)
        audio = resample_poly(audio, sr // gcd, file_sr // gcd).astype(np.float32)

    # Pad / trim to exactly num_frames * stride_samples + window_samples
    stride_n = int(cfg["stride_ms"] * sr / 1000)
    window_n = int(cfg["window_ms"] * sr / 1000)
    need = num_frames * stride_n + window_n
    if len(audio) < need:
        audio = np.pad(audio, (0, need - len(audio)))
    else:
        audio = audio[:need]

    if _TF_FRONTEND_AVAILABLE:
        audio_int16 = np.clip(audio * 32768.0, -32768, 32767).astype(np.int16)
        feats = extract_tf_frontend(audio_int16, cfg)
        # Crop or pad to num_frames
        if feats.shape[0] < num_frames:
            pad = np.zeros((num_frames - feats.shape[0], feats.shape[1]),
                           dtype=np.float32)
            feats = np.concatenate([feats, pad], axis=0)
        return feats[:num_frames]
    else:
        return extract_numpy_frontend(audio, cfg)


# ── Batch processing ──────────────────────────────────────────────────────────
def collect_files(synth_dir: Path, recorded_dir: Path,
                  classes: list) -> list:
    """
    Returns [(wav_path, class_idx), ...] for all available audio files.
    """
    entries = []
    for idx, label in enumerate(classes):
        if label == "silence":
            dirs = [synth_dir / "silence"]
        elif label == "unknown":
            dirs = []
            unknown_root = synth_dir / "unknown"
            if unknown_root.exists():
                for sub in unknown_root.iterdir():
                    dirs.append(sub if sub.is_dir() else unknown_root)
                    break
                dirs = [unknown_root]
        else:
            dirs = [synth_dir / label,
                    recorded_dir / label]

        for d in dirs:
            if not d.exists():
                continue
            for wav in d.rglob("*.wav"):
                entries.append((wav, idx))

    return entries


def main(config_path: str):
    cfg = load_config(config_path)
    base_dir = Path(config_path).parent
    synth_dir = base_dir / cfg["synth"]["output_dir"]
    recorded_dir = base_dir / cfg["record"]["output_dir"]
    feat_dir = base_dir / "data" / "features"
    feat_dir.mkdir(parents=True, exist_ok=True)

    classes = cfg["classes"]
    entries = collect_files(synth_dir, recorded_dir, classes)
    print(f"Found {len(entries)} audio files across {len(classes)} classes")

    # Group by class
    from collections import defaultdict
    by_class = defaultdict(list)
    for path, cidx in entries:
        by_class[cidx].append((path, cidx))

    for cidx, label in enumerate(classes):
        items = by_class[cidx]
        if not items:
            print(f"  [{label}] no files — skip")
            continue

        out_path = feat_dir / f"{label}.npz"
        if out_path.exists():
            existing = np.load(str(out_path))
            if existing["X"].shape[0] == len(items):
                print(f"  [{label}] {len(items)} files — cache hit, skip")
                continue

        X_list, y_list = [], []
        for wav_path, y in tqdm(items, desc=f"  {label}"):
            try:
                feat = extract_features(wav_path, cfg)
                X_list.append(feat)
                y_list.append(y)
            except Exception as e:
                print(f"\n  [warn] {wav_path.name}: {e}", file=sys.stderr)

        if X_list:
            X = np.stack(X_list).astype(np.float32)
            y = np.array(y_list, dtype=np.int32)
            np.savez_compressed(str(out_path), X=X, y=y)
            print(f"    saved {label}.npz — {X.shape}")

    print("\nDone. Run train_dscnn.py next.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="config.yaml")
    args = parser.parse_args()
    main(args.config)
