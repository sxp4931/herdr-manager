#!/usr/bin/env python3
"""Append Cursor `stop` hook token usage for Shepherd's local meter.

Cursor CLI fires `stop` (not `afterAgentResponse`) with model and token
fields. This hook still works if invoked as afterAgentResponse: both
report the same values for a given `generation_id`. Shepherd de-duplicates
those lines.

Writes one JSONL line to ~/.cursor/herdr-usage.jsonl so Shepherd can
price those tokens at the configured list rates.

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


def _first_str(*values) -> str | None:
    for value in values:
        if isinstance(value, str) and value.strip():
            return value
    return None


def _pick_int(sources: tuple[object, ...], *keys: str) -> int:
    for source in sources:
        if not isinstance(source, dict):
            continue
        for key in keys:
            if key in source:
                return _int(source.get(key))
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

    usage = payload.get("usage") if isinstance(payload.get("usage"), dict) else {}
    sources = (payload, usage)

    conversation_id = _first_str(
        payload.get("conversation_id"),
        payload.get("conversationId"),
        payload.get("session_id"),
    )
    model = _first_str(
        payload.get("model"),
        payload.get("modelName"),
        payload.get("model_id"),
        payload.get("modelId"),
        usage.get("model"),
        usage.get("modelName"),
        usage.get("model_id"),
        usage.get("modelId"),
    )
    generation_id = _first_str(
        payload.get("generation_id"),
        payload.get("generationId"),
    )
    input_tokens = _pick_int(sources, "input_tokens", "inputTokens")
    output_tokens = _pick_int(sources, "output_tokens", "outputTokens")
    cache_read = _pick_int(
        sources, "cache_read_tokens", "cacheReadTokens", "cache_read_input_tokens"
    )
    cache_write = _pick_int(
        sources, "cache_write_tokens", "cacheWriteTokens", "cache_creation_input_tokens"
    )
    if input_tokens + output_tokens + cache_read + cache_write <= 0:
        print("{}")
        return

    home = Path.home()
    cwd = payload.get("cwd") or payload.get("workspace_dir")
    if not isinstance(cwd, str) or not cwd:
        cwd = _cwd_for_conversation(home, conversation_id)

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
    if generation_id:
        record["generation_id"] = generation_id
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
