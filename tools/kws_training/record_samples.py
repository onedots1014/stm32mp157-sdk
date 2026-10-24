#!/usr/bin/env python3
"""
Record real microphone samples for fine-tuning and validation.

On development machine: uses sounddevice (pip install sounddevice)
On STM32MP157 board:    uses arecord (ALSA)

Usage:
    # Development machine (interactive)
    python3 record_samples.py --keyword xiao_wang --device 0

    # Board (batch recording via SSH)
    python3 record_samples.py --keyword xiao_wang --board
"""

import argparse
import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf
import yaml


def load_config(path: str) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def record_sounddevice(out_path: Path, duration_s: float, sr: int, device: int):
    """Record one clip using sounddevice (dev machine)."""
    import sounddevice as sd
    print(f"  Recording {duration_s:.1f}s... ", end="", flush=True)
    audio = sd.rec(int(sr * duration_s), samplerate=sr, channels=1,
                   dtype="int16", device=device)
    sd.wait()
    audio = audio.flatten().astype(np.float32) / 32768.0
    sf.write(str(out_path), audio, sr)
    print("saved.")


def record_arecord(out_path: Path, duration_s: float, sr: int):
    """Record one clip using arecord (on-board)."""
    import subprocess
    tmp = out_path.with_suffix(".tmp.wav")
    subprocess.run([
        "arecord", "-D", "default",
        "-f", "S16_LE", "-r", str(sr), "-c", "1",
        "-d", str(int(duration_s)),
        str(tmp),
    ], check=True, capture_output=True)
    # Normalize and save
    import soundfile as sf
    audio, _ = sf.read(str(tmp), dtype="float32")
    sf.write(str(out_path), audio, sr)
    tmp.unlink(missing_ok=True)


def interactive_record(keyword: str, cfg: dict, config_path: str,
                       device: int, board: bool):
    base_dir = Path(config_path).parent
    out_dir = base_dir / cfg["record"]["output_dir"] / keyword
    out_dir.mkdir(parents=True, exist_ok=True)
    target = cfg["record"]["target_count"]
    duration = cfg["record"]["duration_s"]
    sr = cfg["sample_rate"]
    text = cfg["text_map"].get(keyword, keyword)

    existing = sorted(out_dir.glob("*.wav"))
    idx = len(existing)
    print(f"\nRecording '{keyword}' ({text}) — target: {target} clips")
    print(f"Output: {out_dir}")
    print("Press ENTER to record, 'q' + ENTER to quit, 'r' + ENTER to replay last.\n")

    last_path = None
    while idx < target:
        remaining = target - idx
        cmd = input(f"[{idx}/{target}] ({remaining} left) > ").strip().lower()

        if cmd == "q":
            break
        elif cmd == "r" and last_path and last_path.exists():
            audio, _ = sf.read(str(last_path), dtype="float32")
            print(f"  Replaying {last_path.name}...")
            try:
                import sounddevice as sd
                sd.play(audio, sr)
                sd.wait()
            except Exception as e:
                print(f"  Replay failed: {e}")
            continue

        out_path = out_dir / f"real_{keyword}_{idx:05d}.wav"
        try:
            if board:
                record_arecord(out_path, duration, sr)
            else:
                record_sounddevice(out_path, duration, sr, device)
            last_path = out_path
            idx += 1
        except KeyboardInterrupt:
            print("\nInterrupted.")
            break
        except Exception as e:
            print(f"  Error: {e}")

    print(f"\nRecorded {idx} clips → {out_dir}")


def main():
    parser = argparse.ArgumentParser(description="Record KWS training samples")
    parser.add_argument("--config", default="config.yaml")
    parser.add_argument("--keyword", required=True,
                        help="Keyword label to record (e.g. xiao_wang)")
    parser.add_argument("--device", type=int, default=None,
                        help="sounddevice device index (run --list-devices to see)")
    parser.add_argument("--board", action="store_true",
                        help="Use arecord instead of sounddevice (on-board recording)")
    parser.add_argument("--list-devices", action="store_true",
                        help="List available audio devices and exit")
    args = parser.parse_args()

    if args.list_devices:
        import sounddevice as sd
        print(sd.query_devices())
        return

    cfg = load_config(args.config)
    if args.keyword not in cfg["keywords"]:
        print(f"Error: '{args.keyword}' not in config keywords: {cfg['keywords']}")
        sys.exit(1)

    interactive_record(args.keyword, cfg, args.config, args.device, args.board)


if __name__ == "__main__":
    main()
