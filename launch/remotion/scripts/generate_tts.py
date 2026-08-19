#!/usr/bin/env python3
"""Shepherd launch narration via xAI TTS (not macOS say / Chatterbox)."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import requests

OUT = Path(__file__).resolve().parents[1] / "public" / "voice" / "narration.wav"
AUTH = Path.home() / ".grok" / "auth.json"

# One continuous read. [pause] / [long-pause] are xAI speech tags.
# Speed 1.08: a tad under the last take. Pauses carry the 32s, not filler.
SCRIPT = """Stop hunting twenty-seven terminals. [pause] You run a herd of AI coding agents. herdr keeps every session alive. [pause] Two of them are stuck. And you still have to find them.

Shepherd sits in the menu bar, and answers one question. [pause] Does anything need you?

Open the bar. The blocked ones are already on top. [pause] Peek the last lines. Approve it. Then get back to the work that matters.

See what the herd cost today. [pause] An estimate. Not a bill.

[pause] Open source. Built on herdr. That's Shepherd."""


def _token() -> str:
    import os

    env = os.environ.get("XAI_API_KEY")
    if env:
        return env
    data = json.loads(AUTH.read_text())
    return next(iter(data.values()))["key"]


def main() -> int:
    token = _token()
    raw = OUT.with_name("narration-raw.wav")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    print("xAI TTS ara…", flush=True)
    response = requests.post(
        "https://api.x.ai/v1/tts",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        json={
            "text": SCRIPT,
            "voice_id": "ara",
            "language": "en",
            "speed": 1.08,
            "text_normalization": True,
            "output_format": {"codec": "wav", "sample_rate": 48000},
            "replace": {
                "herdr": "/ˈhɝdər/",
            },
        },
        timeout=120,
    )
    if response.status_code != 200:
        print(
            f"TTS failed {response.status_code}: {response.text[:500]}",
            file=sys.stderr,
        )
        return 1
    raw.write_bytes(response.content)
    subprocess.check_call(
        [
            "ffmpeg",
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(raw),
            "-af",
            "loudnorm=I=-16:TP=-1.5:LRA=11",
            "-ar",
            "48000",
            "-ac",
            "1",
            "-c:a",
            "pcm_s16le",
            str(OUT),
        ]
    )
    raw.unlink(missing_ok=True)
    probe = subprocess.check_output(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=nw=1:nk=1",
            str(OUT),
        ],
        text=True,
    ).strip()
    print(f"wrote {OUT} duration={probe}s", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
