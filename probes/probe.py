"""Run one owned CLI in a PTY and emit a single JSON result. The screen is discarded."""

from __future__ import annotations

import errno
import fcntl
import json
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time
from dataclasses import dataclass
from pathlib import Path
from typing import TypedDict

if __name__ == "__main__" and __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from probes.profiles import (
    ProfileError,
    classify_screen,
    extract_version,
    get_profile,
    validate_command,
    validate_key,
    validate_startup,
    version_supported,
)
from probes.terminal import Terminal

DEFAULT_DEADLINE_MS = 20_000
MIN_DEADLINE_MS = 100
MAX_OUTPUT_BYTES = 512 * 1024
SCREEN_COLUMNS = 160
SCREEN_ROWS = 50
REASON_CODE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
TRAP_REASONS = {
    "redeem": "redemption_prompt",
    "trust": "trust_prompt",
    "login": "login_required",
    "model": "model_prompt",
}


class ProbePayload(TypedDict):
    ok: bool
    provider: str
    profile: str
    state: str
    reason: str
    version: str | None
    isatty: bool
    sent: list[str]
    childReaped: bool
    recognized: bool
    deadlineMs: int


@dataclass
class ProbeArgs:
    executable: str
    profile: str
    cwd: str
    deadline_ms: int | None = None
    max_bytes: int = MAX_OUTPUT_BYTES


def bounded_deadline(value: int | None) -> int:
    if value is None:
        return DEFAULT_DEADLINE_MS
    try:
        number = int(value)
    except (TypeError, ValueError):
        return DEFAULT_DEADLINE_MS
    if number < MIN_DEADLINE_MS:
        return MIN_DEADLINE_MS
    if number > DEFAULT_DEADLINE_MS:
        return DEFAULT_DEADLINE_MS
    return number


def bounded_output(value: int) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return MAX_OUTPUT_BYTES
    if number < 1 or number > MAX_OUTPUT_BYTES:
        return MAX_OUTPUT_BYTES
    return number


def empty_payload(profile: str, deadline_ms: int, reason: str) -> ProbePayload:
    return {
        "ok": False,
        "provider": "unknown",
        "profile": profile or "unknown",
        "state": "started",
        "reason": reason,
        "version": None,
        "isatty": False,
        "sent": [],
        "childReaped": True,
        "recognized": False,
        "deadlineMs": deadline_ms,
    }


def parse_args(argv: list[str]) -> ProbeArgs:
    values = {"executable": "", "profile": "", "cwd": "", "deadline_ms": None, "max_bytes": MAX_OUTPUT_BYTES}
    index = 0
    tokens = argv[1:] if argv and argv[0].endswith("probe.py") else argv
    while index < len(tokens):
        key = tokens[index]
        if key not in {"--executable", "--profile", "--cwd", "--deadline-ms", "--max-bytes"}:
            raise ValueError("invalid_arguments")
        if index + 1 >= len(tokens):
            raise ValueError("invalid_arguments")
        value = tokens[index + 1]
        index += 2
        if key == "--executable":
            values["executable"] = value
        elif key == "--profile":
            values["profile"] = value
        elif key == "--cwd":
            values["cwd"] = value
        elif key == "--deadline-ms":
            values["deadline_ms"] = int(value)
        else:
            values["max_bytes"] = int(value)
    if not values["executable"] or not values["profile"] or not values["cwd"]:
        raise ValueError("invalid_arguments")
    return ProbeArgs(
        executable=str(values["executable"]),
        profile=str(values["profile"]),
        cwd=str(values["cwd"]),
        deadline_ms=None if values["deadline_ms"] is None else int(values["deadline_ms"]),
        max_bytes=int(values["max_bytes"]),
    )


def emit(payload: ProbePayload) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=True) + "\n")
    sys.stdout.flush()
    reason = payload["reason"]
    if not isinstance(reason, str) or REASON_CODE.fullmatch(reason) is None:
        reason = "invalid_reason"
    sys.stderr.write(reason + "\n")
    sys.stderr.flush()


def _acquire_lock() -> int | None:
    lock_path = os.environ.get("HERDR_PROBE_LOCK")
    if not lock_path:
        return None
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return -1
    return fd


def _configure_slave(slave: int) -> None:
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", SCREEN_ROWS, SCREEN_COLUMNS, 0, 0))
    attrs = termios.tcgetattr(slave)
    attrs[1] = attrs[1] & ~termios.OPOST
    attrs[3] = attrs[3] & ~(termios.ECHO | termios.ECHONL | termios.ICANON | termios.ISIG | termios.IEXTEN)
    attrs[6][termios.VMIN] = 1
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(slave, termios.TCSANOW, attrs)


def _cli_env(cwd: str) -> dict[str, str]:
    return {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": cwd,
        "TERM": "xterm-256color",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "PYTHONNOUSERSITE": "1",
        "PYTHONSAFEPATH": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
    }


def _read_master(master: int) -> tuple[bytes, bool]:
    chunks: list[bytes] = []
    eof = False
    while True:
        try:
            chunk = os.read(master, 4096)
        except BlockingIOError:
            break
        except OSError as exc:
            if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                break
            eof = True
            break
        if not chunk:
            eof = True
            break
        chunks.append(chunk)
    return b"".join(chunks), eof


def _reap(proc: subprocess.Popen[bytes]) -> None:
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 0.5
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return
        time.sleep(0.02)
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=1)
    except subprocess.TimeoutExpired:
        pass


def _cwd_private(cwd: str) -> bool:
    if not os.path.isabs(cwd) or not os.path.isdir(cwd):
        return False
    return (os.stat(cwd).st_mode & 0o002) == 0


def execute(args: ProbeArgs) -> ProbePayload:
    deadline_ms = bounded_deadline(args.deadline_ms)
    payload = empty_payload(args.profile, deadline_ms, "invalid_result")
    try:
        profile = get_profile(args.profile)
    except ProfileError:
        payload["reason"] = "unknown_profile"
        return payload
    payload["provider"] = profile.provider
    payload["profile"] = profile.profile_id
    try:
        validate_startup(profile)
        if not profile.commands:
            payload["reason"] = "command_rejected"
            return payload
        for command_name in profile.commands:
            validate_command(command_name, profile)
    except ProfileError as exc:
        payload["reason"] = exc.reason
        return payload
    if not os.path.isabs(args.executable):
        payload["reason"] = "not_absolute"
        return payload
    if not os.path.isfile(args.executable) or not os.access(args.executable, os.X_OK):
        payload["reason"] = "not_executable"
        return payload
    if not _cwd_private(args.cwd):
        payload["reason"] = "cwd_denied"
        return payload

    lock_fd = _acquire_lock()
    if lock_fd == -1:
        payload["reason"] = "probe_busy"
        return payload

    master_fd = -1
    slave_fd = -1
    capture_fd = -1
    proc: subprocess.Popen[bytes] | None = None
    slave_is_tty = False
    final = "timeout"
    semantic = "started"
    version: str | None = None
    recognized = False
    sent: list[str] = []
    output = 0
    max_bytes = bounded_output(args.max_bytes)
    command = profile.commands[0]
    cancelled = False

    def on_signal(_signum: int, _frame: object) -> None:
        nonlocal cancelled
        cancelled = True

    previous_term = signal.getsignal(signal.SIGTERM)
    previous_int = signal.getsignal(signal.SIGINT)
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    if profile.capture_screens:
        try:
            duplicated = os.dup(3)
        except OSError:
            duplicated = -1
        if duplicated >= 0:
            os.set_inheritable(duplicated, False)
            try:
                os.close(3)
            except OSError:
                pass
            capture_fd = duplicated

    try:
        master_fd, slave_fd = pty.openpty()
        _configure_slave(slave_fd)
        slave_is_tty = os.isatty(slave_fd)
        proc = subprocess.Popen(
            [args.executable],
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            cwd=args.cwd,
            env=_cli_env(args.cwd),
            preexec_fn=os.setsid,
            close_fds=True,
        )
        os.close(slave_fd)
        slave_fd = -1
        flags = fcntl.fcntl(master_fd, fcntl.F_GETFL)
        fcntl.fcntl(master_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
        terminal = Terminal(SCREEN_COLUMNS, SCREEN_ROWS)
        deadline_at = time.monotonic() + (deadline_ms / 1000.0)
        child_gone = False
        version_re = re.compile(profile.version_pattern) if profile.version_pattern else None
        phase_table = profile.phases if profile.phases else tuple(("usage", profile.usage_markers) for _ in profile.commands)
        captured_phases = [False] * len(profile.commands)
        escape_pending = False

        def emit_capture(phase: str, rows: list[str]) -> None:
            if not profile.capture_screens:
                return
            kept: list[str] = []
            for row in rows:
                text = row.replace("SYNTHETIC_SECRET_SENTINEL", "[redacted-secret]").rstrip()
                if not text:
                    continue
                kept.append(text[:200])
                if len(kept) >= 80:
                    break
            if capture_fd < 0 or capture_fd in {master_fd, slave_fd}:
                return
            if not kept:
                return
            body = json.dumps({"phase": phase, "lines": kept}, ensure_ascii=True) + "\n"
            try:
                os.write(capture_fd, body.encode("ascii"))
            except OSError:
                return

        def send_command(command_text: str) -> str | None:
            nonlocal semantic
            try:
                validate_command(command_text, profile)
                validate_key(command_text, screen="empty_prompt")
            except ProfileError as exc:
                return exc.reason
            try:
                os.write(master_fd, (command_text + "\n").encode("ascii"))
            except OSError:
                return "closed_early"
            sent.append(command_text)
            semantic = "command_sent"
            return None

        def accept(chunk: bytes) -> str | None:
            nonlocal output, version, semantic, recognized, escape_pending
            if output + len(chunk) > max_bytes:
                return "output_limit"
            output += len(chunk)
            terminal.feed(chunk)
            lines = terminal.display()
            kind = classify_screen(lines)
            seen = extract_version(lines, version_re)
            if seen is not None:
                version = seen
            if kind in TRAP_REASONS:
                return TRAP_REASONS[kind]
            if not profile.capture_screens:
                if kind == "empty_prompt" and not sent:
                    if version is None:
                        return None
                    if not version_supported(profile, version):
                        semantic = "empty_prompt"
                        return "unknown_version"
                    validate_command(command, profile)
                    semantic = "empty_prompt"
                    try:
                        os.write(master_fd, (command + "\n").encode("ascii"))
                    except OSError:
                        return "closed_early"
                    sent.append(command)
                    semantic = "command_sent"
                    return None
                if kind == "usage" and sent:
                    semantic = "parsed"
                    recognized = True
                    return "ok"
                if sent:
                    semantic = "command_sent"
                return None
            if not sent:
                if kind != "empty_prompt":
                    return None
                if version is None:
                    return None
                if not version_supported(profile, version):
                    semantic = "empty_prompt"
                    return "unknown_version"
                semantic = "empty_prompt"
                return send_command(profile.commands[0])
            phase_index = len(sent) - 1
            if phase_index < len(phase_table):
                phase_name, markers = phase_table[phase_index]
            else:
                phase_name, markers = "usage", profile.usage_markers
            body = "\n".join(lines)
            matched = bool(markers) and all(marker in body for marker in markers)
            if matched and phase_index < len(captured_phases) and not captured_phases[phase_index]:
                emit_capture(phase_name, lines)
                captured_phases[phase_index] = True
                semantic = "known_usage_screen"
                if len(sent) < len(profile.commands):
                    try:
                        validate_key("\x1b", screen="known_usage_screen")
                    except ProfileError as exc:
                        return exc.reason
                    try:
                        os.write(master_fd, b"\x1b")
                    except OSError:
                        return "closed_early"
                    escape_pending = True
                    return None
                recognized = True
                semantic = "parsed"
                return "ok"
            if escape_pending and kind == "empty_prompt" and len(sent) < len(profile.commands):
                escape_pending = False
                return send_command(profile.commands[len(sent)])
            return None

        while True:
            if cancelled:
                final = "cancelled"
                semantic = "shutdown"
                break
            remaining = deadline_at - time.monotonic()
            if remaining <= 0:
                final = "timeout"
                break
            if child_gone:
                kind = classify_screen(terminal.display())
                if recognized:
                    final = "ok"
                elif kind in TRAP_REASONS:
                    final = TRAP_REASONS[kind]
                elif terminal.bytes_seen == 0:
                    final = "closed_early"
                elif kind == "unrecognized":
                    final = "unrecognized_screen"
                else:
                    final = "closed_early"
                break
            try:
                readable, _, _ = select.select([master_fd], [], [], min(0.05, remaining))
            except InterruptedError:
                continue
            if not readable:
                if proc.poll() is not None:
                    drained, _eof = _read_master(master_fd)
                    if drained:
                        decision = accept(drained)
                        if decision is not None:
                            final = decision
                            break
                    child_gone = True
                continue
            data, eof = _read_master(master_fd)
            if data:
                decision = accept(data)
                if decision is not None:
                    final = decision
                    break
            if eof or proc.poll() is not None:
                child_gone = True
                if eof and not data:
                    continue
        payload["ok"] = final == "ok"
        payload["reason"] = final
        payload["state"] = semantic
        payload["version"] = version
        payload["sent"] = sent
        payload["recognized"] = recognized
        payload["isatty"] = slave_is_tty
        return payload
    except OSError:
        payload["reason"] = "not_executable"
        payload["isatty"] = slave_is_tty
        return payload
    finally:
        signal.signal(signal.SIGTERM, previous_term)
        signal.signal(signal.SIGINT, previous_int)
        if slave_fd >= 0:
            os.close(slave_fd)
        if master_fd >= 0:
            os.close(master_fd)
        if proc is not None:
            _reap(proc)
            payload["childReaped"] = proc.poll() is not None
        if lock_fd is not None and lock_fd >= 0:
            os.close(lock_fd)
        if capture_fd >= 0:
            os.close(capture_fd)


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(sys.argv if argv is None else argv)
    except (ValueError, TypeError):
        emit(empty_payload("unknown", DEFAULT_DEADLINE_MS, "invalid_arguments"))
        return 0
    emit(execute(args))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
