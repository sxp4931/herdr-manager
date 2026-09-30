import unittest

import pyte
import wcwidth


class TerminalSmokeTest(unittest.TestCase):
    def test_cursor_redraw_replaces_the_visible_line(self) -> None:
        screen = pyte.Screen(20, 3)
        stream = pyte.Stream(screen)
        stream.feed("hello")
        stream.feed("\x1b[H\x1b[2KHELLO")
        self.assertEqual(screen.display[0].rstrip(), "HELLO")
        self.assertGreaterEqual(wcwidth.wcswidth("HELLO"), 5)


if __name__ == "__main__":
    unittest.main()
