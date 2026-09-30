#!/usr/bin/env python3
"""Synthetic Codex TTY. This is not the Codex CLI."""

from __future__ import annotations

import importlib.util
from pathlib import Path


def _helper():
    path = Path(__file__).resolve().parent / "tty_program.py"
    spec = importlib.util.spec_from_file_location("herdr_tty_program", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("missing tty helper")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_tty = _helper()
arm = _tty.arm
emit = _tty.emit
hold = _tty.hold
prompt = _tty.prompt
read_mode = _tty.read_mode
run_script = _tty.run_script
screen = _tty.screen

SCREENS = Path(__file__).resolve().parents[1] / "fixtures" / "usage" / "screens"


def main() -> int:
    if not arm():
        return 2
    mode = read_mode()
    banner = prompt("Codex fixture-1")
    if mode == "login":
        emit("\x1b[H\x1b[2JSign in to continue\r\n")
        hold()
        return 0
    inventory = screen(SCREENS / "codex-usage.txt")
    if mode == "none":
        inventory = screen(SCREENS / "codex-none.txt")
    elif mode == "redeem":
        inventory = "\x1b[H\x1b[2JRedeem reset\r\nApply\r\nConfirm\r\n"
    emit(banner)
    run_script(
        [
            (b"/status", screen(SCREENS / "codex-status.txt")),
            (b"\x1b", banner),
            (b"/usage", inventory),
        ]
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
