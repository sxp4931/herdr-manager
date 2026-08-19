#!/usr/bin/env python3
"""Premix narration + bed into one 32s stereo wav.

Remotion's live mixer was dropping samples (voice cut out, then
sounded fine if you replayed the same frame). One file avoids that.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VO = ROOT / "public" / "voice" / "narration.wav"
MUS = ROOT / "public" / "music" / "warm-horizon.wav"
OUT = ROOT / "public" / "voice" / "soundtrack.wav"

# Match SceneVoice: VO starts at frame 10, music fades 0–24 then 900–960.
DELAY_MS = int(round(10 / 30 * 1000))  # 333
FADE_IN = 24 / 30  # 0.8s
FADE_OUT_START = 900 / 30  # 30s
FADE_OUT_DUR = 60 / 30  # 2s
DURATION = 32


def main() -> int:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    filt = (
        f"[0:a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,"
        f"adelay={DELAY_MS}|{DELAY_MS},apad=whole_dur={DURATION}[vo];"
        f"[1:a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,"
        f"volume=0.05,afade=t=in:st=0:d={FADE_IN},"
        f"afade=t=out:st={FADE_OUT_START}:d={FADE_OUT_DUR},"
        f"atrim=0:{DURATION},apad=whole_dur={DURATION}[mus];"
        f"[vo][mus]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[a]"
    )
    subprocess.check_call(
        [
            "ffmpeg",
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(VO),
            "-i",
            str(MUS),
            "-filter_complex",
            filt,
            "-map",
            "[a]",
            "-t",
            str(DURATION),
            "-ar",
            "48000",
            "-ac",
            "2",
            "-c:a",
            "pcm_s16le",
            str(OUT),
        ]
    )
    print(f"wrote {OUT}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
