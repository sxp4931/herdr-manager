#!/usr/bin/env python3
"""Synthetic TTY CLI. Modes are selected by a ./mode file in the working directory."""

from __future__ import annotations

import os
import subprocess
import sys
import time


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


def write_slowly(text: str, delay: float) -> None:
    for character in text:
        os.write(1, character.encode("utf-8"))
        time.sleep(delay)


def spawn_sleeper() -> None:
    child = subprocess.Popen(["sleep", "60"])
    with open("sleep.pid", "w", encoding="utf-8") as handle:
        handle.write(str(child.pid))


def read_forever(trigger: bytes | None = None, response: str | None = None, slow: bool = False) -> None:
    buffer = b""
    responded = False
    while True:
        try:
            data = os.read(0, 1024)
        except OSError:
            return
        if not data:
            return
        record(data)
        buffer += data
        if trigger is not None and not responded and trigger in buffer:
            responded = True
            if response:
                if slow:
                    write_slowly(response, 0.004)
                else:
                    emit(response)


def main() -> int:
    if not arm():
        return 2
    mode = read_mode()
    banner = "\x1b[H\x1b[2Jfixture-cli fixture-1.0.0\r\n>\r\n"
    usage = "\x1b[H\x1b[2JSession  10% used\r\nWeekly  20% used\r\n"
    if mode == "usage":
        emit(banner)
        read_forever(b"/usage", usage)
        return 0
    if mode == "fragment":
        write_slowly(banner, 0.004)
        read_forever(b"/usage", usage, slow=True)
        return 0
    if mode == "trust":
        emit("\x1b[H\x1b[2JDo you trust this folder?\r\n")
        read_forever()
        return 0
    if mode == "redeem":
        emit("\x1b[H\x1b[2JRedeem reset\r\n")
        read_forever()
        return 0
    if mode == "redeem-prompt":
        emit("\x1b[H\x1b[2JRedeem reset\r\n>\r\n")
        read_forever()
        return 0
    if mode == "login":
        emit("\x1b[H\x1b[2JSign in to continue\r\n")
        read_forever()
        return 0
    if mode == "model":
        emit("\x1b[H\x1b[2JSelect a model\r\n")
        read_forever()
        return 0
    if mode == "unknown-version":
        emit("\x1b[H\x1b[2Jfixture-cli 99.0.0\r\n>\r\n")
        read_forever()
        return 0
    if mode == "nonewline":
        os.write(1, b"10% used")
        time.sleep(30)
        return 0
    if mode == "exit":
        emit("fixture-cli fixture-1.0.0\r\n")
        return 0
    if mode == "die":
        return 0
    if mode == "slow":
        emit("\x1b[H\x1b[2Jfixture-cli fixture-1.0.0\r\n")
        spawn_sleeper()
        time.sleep(60)
        return 0
    if mode == "flood":
        blob = b"A" * 4096
        while True:
            try:
                os.write(1, blob)
            except OSError:
                return 0
    emit("\x1b[H\x1b[2Junrecognized screen\r\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
