"""Shared stdlib helpers for synthetic TTY programs."""

from __future__ import annotations

import os
from pathlib import Path


def emit(text: str) -> None:
    os.write(1, text.encode("utf-8"))


def record(data: bytes) -> None:
    with open("keystrokes", "ab") as handle:
        handle.write(data)


def read_mode() -> str:
    try:
        with open("mode", "r", encoding="utf-8") as handle:
            return handle.read().strip() or "usage"
    except FileNotFoundError:
        return "usage"


def arm() -> bool:
    tty = os.isatty(1)
    with open("tty-check", "w", encoding="utf-8") as handle:
        handle.write("1" if tty else "0")
    with open("pid", "w", encoding="utf-8") as handle:
        handle.write(str(os.getpid()))
    with open("keystrokes", "wb") as handle:
        handle.write(b"")
    with open("env-audit", "w", encoding="utf-8") as handle:
        handle.write("\n".join(sorted(os.environ)))
    if not tty:
        os.write(2, b"not_a_tty\n")
        return False
    return True


def prompt(banner: str) -> str:
    return "\x1b[H\x1b[2J" + banner + "\r\n>\r\n"


def screen(path: Path) -> str:
    text = path.read_text(encoding="utf-8").replace("\r\n", "\n").strip("\n")
    return "\x1b[H\x1b[2J" + text.replace("\n", "\r\n") + "\r\n"


def hold() -> None:
    while True:
        try:
            data = os.read(0, 1024)
        except OSError:
            return
        if not data:
            return
        record(data)


def run_script(steps: list[tuple[bytes, str]]) -> None:
    pending = b""
    index = 0
    while True:
        try:
            data = os.read(0, 1024)
        except OSError:
            return
        if not data:
            return
        record(data)
        pending += data
        while index < len(steps) and steps[index][0] in pending:
            trigger, response = steps[index]
            at = pending.find(trigger)
            pending = pending[at + len(trigger) :]
            emit(response)
            index += 1
