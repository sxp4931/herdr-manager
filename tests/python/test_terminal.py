import sys
import unittest
from pathlib import Path

import pyte
import wcwidth

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from probes.profiles import classify_screen
from probes.terminal import Terminal


class TerminalSmokeTest(unittest.TestCase):
    def test_cursor_redraw_replaces_the_visible_line(self) -> None:
        screen = pyte.Screen(20, 3)
        stream = pyte.Stream(screen)
        stream.feed("hello")
        stream.feed("\x1b[H\x1b[2KHELLO")
        self.assertEqual(screen.display[0].rstrip(), "HELLO")
        self.assertGreaterEqual(wcwidth.wcswidth("HELLO"), 5)


class TerminalRenderTest(unittest.TestCase):
    def test_wide_characters_keep_their_display_width(self) -> None:
        terminal = Terminal(20, 3)
        terminal.feed("你好")
        self.assertEqual(terminal.display()[0], "你好")
        self.assertEqual(wcwidth.wcswidth("你好"), 4)

    def test_lines_wrap_at_the_configured_width(self) -> None:
        terminal = Terminal(20, 3)
        terminal.feed("A" * 25)
        self.assertEqual(terminal.display()[0], "A" * 20)
        self.assertEqual(terminal.display()[1], "A" * 5)

    def test_cursor_home_and_clear_replace_the_line(self) -> None:
        terminal = Terminal(20, 3)
        terminal.feed("hello")
        terminal.feed("\x1b[H\x1b[2KHELLO")
        self.assertEqual(terminal.display()[0], "HELLO")
        self.assertNotIn("hello", "\n".join(terminal.display()))

    def test_split_escape_and_utf8_bytes_compose(self) -> None:
        terminal = Terminal(20, 3)
        terminal.feed(b"hello")
        terminal.feed(b"\x1b")
        terminal.feed(b"[H\x1b[2J")
        encoded = "你".encode()
        self.assertGreater(len(encoded), 1)
        terminal.feed(encoded[:1])
        terminal.feed(encoded[1:])
        self.assertTrue(terminal.display()[0].startswith("你"))
        self.assertNotIn("hello", "\n".join(terminal.display()))

    def test_ansi_redraw_matches_the_fixture_usage_screen(self) -> None:
        terminal = Terminal(160, 50)
        terminal.feed("\x1b[H\x1b[2Jfixture-cli fixture-1.0.0\r\n>\r\n")
        self.assertEqual(classify_screen(terminal.display()), "empty_prompt")
        terminal.feed("\x1b[H\x1b[2JSession  10% used\r\nWeekly  20% used\r\n")
        self.assertEqual(terminal.display()[0], "Session  10% used")
        self.assertEqual(terminal.display()[1], "Weekly  20% used")
        self.assertNotIn("fixture-cli", "\n".join(terminal.display()))
        self.assertEqual(classify_screen(terminal.display()), "usage")


if __name__ == "__main__":
    unittest.main()
