#!/usr/bin/env python3
"""
Data augmentation: mix background noise, time-stretch, pitch-shift.

Reads WAV files from data/synth/ and data/recorded/, writes augmented
copies back into data/synth/<label>/aug_*.wav.

Usage:
    python3 augment.py [--config config.yaml]
"""

import argparse
import random
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
import yaml
from scipy.signal import resample_poly
from tqdm import tqdm


def load_config(path: str) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


# ── Pink noise generation ──────────────────────────────────────────────────────
def pink_noise(n: int) -> np.ndarray:
    """Generate pink (1/f) noise via Voss-McCartney algorithm."""
    max_key = 0x1f
    n_rows = 5
    rows = np.random.randn(n_rows)
    key = 0
    output = np.zeros(n, dtype=np.float32)
    for i in range(n):
        last_key = key
        key = (key + 1) & max_key
        diff = last_key ^ key
        for j in range(n_rows):
            if (diff >> j) & 1:
                rows[j] = np.random.randn()
        output[i] = rows.sum()
    output /= (np.abs(output).max() + 1e-9)
    return output


def load_noise_pool(noise_dir: Path, sr: int, min_duration_s: float = 3.0) -> list:
    """Load all noise WAVs from noise_dir; generate pink noise if empty."""
    wavs = list(noise_dir.glob("*.wav")) if noise_dir.exists() else []
    pool = []
    for w in wavs:
        try:
            audio, file_sr = sf.read(str(w), dtype="float32")
            if file_sr != sr:
                # Simple resample: scipy resample_poly
                gcd = np.gcd(sr, file_sr)
                audio = resample_poly(audio, sr // gcd, file_sr // gcd)
            if audio.ndim > 1:
                audio = audio.mean(axis=1)
            pool.append(audio)
        except Exception:
            pass

    if not pool:
        # Generate synthetic pink + white noise segments
        print("  [augment] No noise files found — generating synthetic noise pool")
        for _ in range(5):
            pool.append(pink_noise(int(sr * 10)))
        for _ in range(5):
            pool.append(np.random.randn(int(sr * 10)).astype(np.float32) * 0.3)

    return pool


def add_noise(audio: np.ndarray, noise_pool: list, snr_db: float,
              sr: int) -> np.ndarray:
    """Mix a random segment of noise into audio at the given SNR."""
    noise_track = random.choice(noise_pool)
    n = len(audio)
    if len(noise_track) < n:
        noise_track = np.tile(noise_track, n // len(noise_track) + 1)
    start = random.randint(0, len(noise_track) - n)
    noise_seg = noise_track[start:start + n].copy()

    sig_power = (audio ** 2).mean() + 1e-9
    noise_power = (noise_seg ** 2).mean() + 1e-9
    target_noise_power = sig_power / (10 ** (snr_db / 10))
    noise_seg *= np.sqrt(target_noise_power / noise_power)

    mixed = audio + noise_seg
    peak = np.abs(mixed).max()
    if peak > 1.0:
        mixed /= peak
    return mixed.astype(np.float32)


def time_stretch(audio: np.ndarray, factor: float, sr: int) -> np.ndarray:
    """Time-stretch by resampling (no pitch change)."""
    orig_len = len(audio)
    new_len = int(orig_len / factor)
    stretched = resample_poly(audio, orig_len, new_len)
    # Pad or trim to original length
    if len(stretched) < orig_len:
        stretched = np.pad(stretched, (0, orig_len - len(stretched)))
    else:
        stretched = stretched[:orig_len]
    return stretched.astype(np.float32)


def augment_file(src_path: Path, dst_path: Path, cfg: dict,
                 noise_pool: list, sr: int):
    """Apply random augmentation to one WAV file."""
    audio, file_sr = sf.read(str(src_path), dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if file_sr != sr:
        gcd = np.gcd(sr, file_sr)
        audio = resample_poly(audio, sr // gcd, file_sr // gcd)

    aug_cfg = cfg["augment"]

    # Random time-stretch
    if aug_cfg["speed_factors"]:
        factor = random.choice(aug_cfg["speed_factors"])
        audio = time_stretch(audio, factor, sr)

    # Random noise mixing
    if noise_pool and aug_cfg["noise_snr_db"]:
        snr = random.choice(aug_cfg["noise_snr_db"])
        audio = add_noise(audio, noise_pool, snr, sr)

    sf.write(str(dst_path), audio, sr)


def find_source_files(synth_dir: Path, recorded_dir: Path,
                      classes: list) -> dict:
    """Return {label: [path, ...]} for all source WAV files."""
    result = {}
    for label in classes:
        files = []
        if label == "silence":
            d = synth_dir / "silence"
        elif label == "unknown":
            d = synth_dir / "unknown"
            if d.exists():
                for sub in d.iterdir():
                    if sub.is_dir():
                        files += list(sub.glob("*.wav"))
                    elif sub.suffix == ".wav":
                        files.append(sub)
        else:
            d = synth_dir / label
            if d.exists():
                files += [f for f in d.glob("*.wav") if "aug_" not in f.name]
            rec_d = recorded_dir / label
            if rec_d.exists():
                files += list(rec_d.glob("*.wav"))

        if label not in ("unknown",):
            d2 = synth_dir / label if label != "silence" else synth_dir / "silence"
            if d2.exists():
                files += [f for f in d2.glob("*.wav") if "aug_" not in f.name]

        # Deduplicate
        seen = set()
        deduped = []
        for f in files:
            if str(f) not in seen:
                seen.add(str(f))
                deduped.append(f)
        result[label] = deduped

    return result


def main(config_path: str):
    cfg = load_config(config_path)
    base_dir = Path(config_path).parent
    synth_dir = base_dir / cfg["synth"]["output_dir"]
    recorded_dir = base_dir / cfg["record"]["output_dir"]
    noise_dir = base_dir / cfg["augment"]["noise_dir"]
    sr = cfg["sample_rate"]
    augment_factor = cfg["augment"]["augment_factor"]

    print("Loading noise pool...")
    noise_pool = load_noise_pool(noise_dir, sr)
    print(f"  {len(noise_pool)} noise tracks loaded")

    classes = cfg["classes"]
    source_files = find_source_files(synth_dir, recorded_dir, classes)

    for label, files in source_files.items():
        if not files:
            print(f"  [{label}] No source files — skip")
            continue

        if label == "silence":
            aug_dir = synth_dir / "silence"
        elif label == "unknown":
            aug_dir = synth_dir / "unknown"
        else:
            aug_dir = synth_dir / label
        aug_dir.mkdir(parents=True, exist_ok=True)

        # Count existing augmented files
        existing_aug = len(list(aug_dir.glob("aug_*.wav")))
        need = len(files) * augment_factor - existing_aug
        if need <= 0:
            print(f"  [{label}] {existing_aug} aug files — skip")
            continue

        print(f"  [{label}] {len(files)} sources × {augment_factor}"
              f" = {len(files)*augment_factor} target (have {existing_aug})")

        aug_idx = existing_aug
        for src in tqdm(files, desc=f"  augment {label}"):
            for _ in range(augment_factor):
                dst = aug_dir / f"aug_{aug_idx:06d}.wav"
                if not dst.exists():
                    try:
                        augment_file(src, dst, cfg, noise_pool, sr)
                    except Exception as e:
                        print(f"\n  [warn] {src.name}: {e}", file=sys.stderr)
                aug_idx += 1

    print("\nDone. Run prepare_features.py next.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="config.yaml")
    args = parser.parse_args()
    main(args.config)
