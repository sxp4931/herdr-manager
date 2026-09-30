#!/usr/bin/env python3
"""Synthetic Claude TTY. This is not the Claude CLI."""

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
    if mode == "login":
        emit("\x1b[H\x1b[2JSign in to continue\r\n")
        hold()
        return 0
    emit(prompt("Claude Code fixture-1"))
    run_script([(b"/usage", screen(SCREENS / "claude-usage.txt"))])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
