#!/usr/bin/env python3
"""
KWS listener v2 — CA7 side
Receives binary RPMsg messages from M4 KWS firmware.

Protocol v2 (kws.h):
  MSG_WAKE(1):     [ 0x01 | 0x04 | 0x00 | class_id:u8 | confidence:u8 | reserved:u16_le ]
  MSG_PCM(2):      [ 0x02 | len_lo | len_hi | int16_le samples... ]
  MSG_ASR_DONE(3): sent CA7->M4 to stop PCM forwarding

Usage:
    python3 kws_listener.py [device]
    python3 kws_listener.py /dev/ttyRPMSG0
"""

import sys
import struct
import wave
import time
import json

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
DEVICE          = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyRPMSG0"
LABELS_FILE     = "/etc/kws/labels.json"
RECORD_SECONDS  = 5.0
SAMPLE_RATE     = 16000

MSG_WAKE         = 1
MSG_PCM          = 2
MSG_ASR_DONE     = 3
MSG_WAKE_PAYLOAD = 4   # payload bytes after the 3-byte header in v2 MSG_WAKE

# ---------------------------------------------------------------------------
# Label table — loaded from /etc/kws/labels.json (deployed by rootfs-overlay)
# ---------------------------------------------------------------------------
try:
    with open(LABELS_FILE) as _f:
        _raw = json.load(_f)
    LABELS = {int(k): v for k, v in _raw.items()}
except Exception as _e:
    print(f"[kws_listener] warning: cannot load {LABELS_FILE}: {_e}")
    LABELS = {}

def get_label(class_id: int) -> str:
    return LABELS.get(class_id, f"class_{class_id}")

# ---------------------------------------------------------------------------
# Wake-word handlers  — add a function and register it in HANDLERS to act on
# a specific keyword without touching the main loop.
# ---------------------------------------------------------------------------
def handle_xiao_wang(label: str, confidence: int, class_id: int) -> None:
    print(f"\n*** WAKE '{label}' conf={confidence}% — starting recording ***")

def default_handler(label: str, confidence: int, class_id: int) -> None:
    print(f"\n*** WAKE '{label}' (class={class_id}, conf={confidence}%) ***")

HANDLERS = {
    "xiao_wang": handle_xiao_wang,
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
print(f"[kws_listener] opening {DEVICE} ...")

with open(DEVICE, "r+b", buffering=0) as f:
    # Send one byte to establish the RPMsg endpoint on the M4 side.
    f.write(b".")
    print("[kws_listener] connected, waiting for wake word ...\n")

    buf        = b""
    recording  = False
    pcm_frames = []
    wake_time  = 0.0
    wake_label = ""

    while True:
        chunk = f.read(256)
        if not chunk:
            continue
        buf += chunk

        # Parse all complete messages from the buffer.
        while True:
            if not buf:
                break
            msg_type = buf[0]

            if msg_type == MSG_WAKE:
                needed = 3 + MSG_WAKE_PAYLOAD
                if len(buf) < needed:
                    break
                class_id   = buf[3]
                confidence = buf[4]
                buf = buf[needed:]

                label   = get_label(class_id)
                handler = HANDLERS.get(label, default_handler)
                handler(label, confidence, class_id)

                recording  = True
                pcm_frames = []
                wake_time  = time.time()
                wake_label = label

            elif msg_type == MSG_PCM:
                if len(buf) < 3:
                    break
                payload_len = struct.unpack_from("<H", buf, 1)[0]
                if len(buf) < 3 + payload_len:
                    break
                payload = buf[3:3 + payload_len]
                buf = buf[3 + payload_len:]
                if recording:
                    pcm_frames.append(payload)
                    elapsed = time.time() - wake_time
                    samples = sum(len(p) for p in pcm_frames) // 2
                    print(f"\r    recording {elapsed:.1f}s  {samples} samples",
                          end="", flush=True)

            else:
                buf = buf[1:]

        # After RECORD_SECONDS, stop recording and save WAV.
        if recording and (time.time() - wake_time) >= RECORD_SECONDS:
            recording = False
            print()

            f.write(bytes([MSG_ASR_DONE]))
            print("[kws_listener] sent ASR_DONE to M4")

            if pcm_frames:
                ts       = int(wake_time)
                filename = f"kws_{wake_label}_{ts}.wav"
                raw_pcm  = b"".join(pcm_frames)
                with wave.open(filename, "wb") as wf:
                    wf.setnchannels(1)
                    wf.setsampwidth(2)
                    wf.setframerate(SAMPLE_RATE)
                    wf.writeframes(raw_pcm)
                total_s = len(raw_pcm) / (SAMPLE_RATE * 2)
                print(f"[kws_listener] saved {filename} ({total_s:.2f}s)")

            print("\n[kws_listener] waiting for next wake word ...\n")
