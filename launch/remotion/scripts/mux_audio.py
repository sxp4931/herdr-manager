#!/usr/bin/env python3
"""Replace Remotion audio with the premixed wav via Apple AAC."""
from __future__ import annotations

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIDEO = ROOT.parent / "out" / "shepherd-launch.mp4"
AUDIO = ROOT / "public" / "voice" / "soundtrack.wav"
TMP = VIDEO.with_name("shepherd-launch.mux.mp4")


def main() -> int:
    subprocess.check_call(
        [
            "ffmpeg",
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(VIDEO),
            "-i",
            str(AUDIO),
            "-map",
            "0:v:0",
            "-map",
            "1:a:0",
            "-c:v",
            "copy",
            "-c:a",
            "aac_at",
            "-b:a",
            "320k",
            "-ar",
            "48000",
            "-ac",
            "2",
            "-movflags",
            "+faststart",
            "-shortest",
            str(TMP),
        ]
    )
    TMP.replace(VIDEO)
    print(f"muxed {VIDEO}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
