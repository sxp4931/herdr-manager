"""Incremental terminal screen for probe output. Raw bytes are not the parse source."""

from __future__ import annotations

import codecs

import pyte


class Terminal:
    def __init__(self, columns: int = 160, rows: int = 50) -> None:
        if columns < 1 or rows < 1:
            raise ValueError("screen size must be positive")
        self.columns = columns
        self.rows = rows
        self.bytes_seen = 0
        self._screen = pyte.Screen(columns, rows)
        self._stream = pyte.Stream(self._screen)
        self._decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")

    def feed(self, data: bytes | str) -> None:
        if isinstance(data, str):
            self.bytes_seen += len(data.encode("utf-8"))
            if data:
                self._stream.feed(data)
            return
        self.bytes_seen += len(data)
        text = self._decoder.decode(data)
        if text:
            self._stream.feed(text)

    def display(self) -> list[str]:
        return [line.rstrip() for line in self._screen.display]
