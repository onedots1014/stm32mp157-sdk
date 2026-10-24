#!/usr/bin/env python3
"""
Synthesize training audio using Edge-TTS.

Generates WAV files for each keyword and unknown word using multiple
Chinese neural voices with random speech rate variation.

Usage:
    python3 synth_dataset.py [--config config.yaml]
"""

import argparse
import asyncio
import random
import subprocess
import sys
import tempfile
from pathlib import Path

import edge_tts
import yaml
from tqdm import tqdm


def load_config(path: str) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def ffmpeg_to_wav(src: Path, dst: Path, sample_rate: int) -> bool:
    """Convert any audio file to 16kHz mono WAV using ffmpeg."""
    result = subprocess.run(
        ["ffmpeg", "-y", "-i", str(src),
         "-ar", str(sample_rate), "-ac", "1",
         "-f", "wav", str(dst)],
        capture_output=True,
    )
    return result.returncode == 0


async def synth_one(text: str, voice: str, rate_pct: int,
                    out_path: Path, sample_rate: int,
                    max_retries: int = 4) -> bool:
    """Synthesize one utterance and save as 16kHz mono WAV.
    Retries with exponential backoff on 503 / network errors."""
    rate_str = f"{rate_pct:+d}%"

    for attempt in range(max_retries):
        communicate = edge_tts.Communicate(text, voice, rate=rate_str)
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
            tmp_path = Path(tmp.name)
        try:
            await communicate.save(str(tmp_path))
            ok = ffmpeg_to_wav(tmp_path, out_path, sample_rate)
            return ok
        except Exception as e:
            tmp_path.unlink(missing_ok=True)
            if attempt < max_retries - 1:
                wait = 2 ** attempt + random.uniform(0, 1)
                await asyncio.sleep(wait)
            else:
                print(f"\n  [warn] {voice} rate={rate_str} (gave up after {max_retries} tries): {e}",
                      file=sys.stderr)
                return False
        finally:
            tmp_path.unlink(missing_ok=True)


async def synth_keyword(label: str, text: str, cfg: dict, out_dir: Path,
                        start_idx: int = 0) -> int:
    """Synthesize all utterances for one keyword, returning count written."""
    voices = cfg["synth"]["voices"]
    count_per_voice = cfg["synth"]["count_per_voice"]
    rate_lo, rate_hi = cfg["synth"]["rate_range"]
    sr = cfg["sample_rate"]

    out_dir.mkdir(parents=True, exist_ok=True)
    written = 0

    for voice in voices:
        short_voice = voice.split("-")[-1]  # e.g. "XiaoxiaoNeural"
        tasks = []
        indices = range(start_idx + written, start_idx + written + count_per_voice)
        for idx in indices:
            rate_pct = random.randint(rate_lo, rate_hi)
            filename = out_dir / f"{label}_{short_voice}_{idx:05d}.wav"
            if filename.exists():
                written += 1
                continue
            tasks.append((text, voice, rate_pct, filename, sr))

        # Small batches + inter-batch sleep to avoid 503 rate limiting
        batch_size = 3
        for i in range(0, len(tasks), batch_size):
            batch = tasks[i:i + batch_size]
            results = await asyncio.gather(*[
                synth_one(*t) for t in batch
            ])
            written += sum(results)
            if i + batch_size < len(tasks):
                await asyncio.sleep(0.5)

    return written


async def main(config_path: str):
    cfg = load_config(config_path)
    base_dir = Path(config_path).parent
    synth_dir = base_dir / cfg["synth"]["output_dir"]
    sr = cfg["sample_rate"]

    # ── Synthesize keywords ───────────────────────────────────────────────
    print("=== Synthesizing keywords ===")
    for label in cfg["keywords"]:
        text = cfg["text_map"][label]
        out_dir = synth_dir / label
        existing = len(list(out_dir.glob("*.wav"))) if out_dir.exists() else 0
        n_voices = len(cfg["synth"]["voices"])
        total = cfg["synth"]["count_per_voice"] * n_voices
        print(f"  {label} ({text}): {existing}/{total} existing", end=" ")
        if existing >= total:
            print("→ skip")
            continue
        print("→ generating...")
        count = await synth_keyword(label, text, cfg, out_dir, start_idx=0)
        print(f"    wrote {count} files to {out_dir}")

    # ── Synthesize unknown-class words ────────────────────────────────────
    print("\n=== Synthesizing unknown words ===")
    unknown_cfg = cfg["unknown"]
    voices = cfg["synth"]["voices"]
    rate_lo, rate_hi = cfg["synth"]["rate_range"]

    for word in tqdm(unknown_cfg["words"], desc="unknown words"):
        label = "unknown_" + "".join(
            c for c in word if c.isalpha() or c.isdigit()
        )[:8]
        out_dir = synth_dir / "unknown" / label
        out_dir.mkdir(parents=True, exist_ok=True)

        idx = 0
        for voice in voices:
            short_voice = voice.split("-")[-1]
            tasks = []
            per_word = unknown_cfg["count_per_word"] // len(voices)
            for j in range(per_word):
                rate_pct = random.randint(rate_lo, rate_hi)
                filename = out_dir / f"{label}_{short_voice}_{idx:05d}.wav"
                idx += 1
                if filename.exists():
                    continue
                tasks.append((word, voice, rate_pct, filename, sr))

            batch_size = 8
            for i in range(0, len(tasks), batch_size):
                batch = tasks[i:i + batch_size]
                await asyncio.gather(*[synth_one(*t) for t in batch])

    # ── Generate silence clips ────────────────────────────────────────────
    print("\n=== Generating silence clips ===")
    import numpy as np
    import soundfile as sf

    silence_dir = synth_dir / "silence"
    silence_dir.mkdir(parents=True, exist_ok=True)
    n_silence = 1000
    duration_s = 1.0
    n_samples = int(sr * duration_s)
    existing = len(list(silence_dir.glob("*.wav")))
    for i in range(existing, n_silence):
        # Mix very-low-level pink noise as "silence" (avoids pure zeros)
        noise = np.random.randn(n_samples).astype(np.float32) * 0.001
        sf.write(silence_dir / f"silence_{i:05d}.wav", noise, sr)
    print(f"  {silence_dir}: {n_silence} clips")

    print("\nDone. Run augment.py next.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="config.yaml")
    args = parser.parse_args()
    asyncio.run(main(args.config))
