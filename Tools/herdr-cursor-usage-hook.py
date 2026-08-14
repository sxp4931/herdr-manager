#!/usr/bin/env python3
"""Append Cursor afterAgentResponse token usage for Shepherd's local meter.

Cursor's chat store records Anthropic-shaped `usage` objects when the model
exposes them, but Grok-backed sessions often omit that payload. This hook
writes one JSONL line per agent response to ~/.cursor/herdr-usage.jsonl so
Shepherd can price those tokens at the configured list rates.

Fails open: never blocks the agent.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path


def _int(value) -> int:
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return 0


def _cwd_for_conversation(home: Path, conversation_id: str | None) -> str | None:
    if not conversation_id:
        return None
    chats = home / ".cursor" / "chats"
    if not chats.is_dir():
        return None
    for meta_path in chats.glob(f"*/{conversation_id}/meta.json"):
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        cwd = meta.get("cwd")
        if isinstance(cwd, str) and cwd:
            return cwd
    return None


def main() -> None:
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}

    conversation_id = (
        payload.get("conversation_id")
        or payload.get("conversationId")
        or payload.get("session_id")
    )
    model = payload.get("model") or payload.get("modelName")
    input_tokens = _int(payload.get("input_tokens") or payload.get("inputTokens"))
    output_tokens = _int(payload.get("output_tokens") or payload.get("outputTokens"))
    cache_read = _int(
        payload.get("cache_read_tokens")
        or payload.get("cacheReadTokens")
        or payload.get("cache_read_input_tokens")
    )
    cache_write = _int(
        payload.get("cache_write_tokens")
        or payload.get("cacheWriteTokens")
        or payload.get("cache_creation_input_tokens")
    )
    if input_tokens + output_tokens + cache_read + cache_write <= 0:
        print("{}")
        return

    home = Path.home()
    cwd = payload.get("cwd") or payload.get("workspace_dir")
    if not isinstance(cwd, str) or not cwd:
        cwd = _cwd_for_conversation(
            home, conversation_id if isinstance(conversation_id, str) else None
        )

    record = {
        "ts_ms": int(time.time() * 1000),
        "conversation_id": conversation_id,
        "cwd": cwd,
        "model": model,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "cache_read_tokens": cache_read,
        "cache_write_tokens": cache_write,
    }
    out = home / ".cursor" / "herdr-usage.jsonl"
    try:
        out.parent.mkdir(parents=True, exist_ok=True)
        with out.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, separators=(",", ":")) + "\n")
    except OSError:
        pass
    print("{}")


if __name__ == "__main__":
    main()
