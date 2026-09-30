import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from probes.probe import DEFAULT_DEADLINE_MS, MAX_OUTPUT_BYTES, ProbeArgs, _cli_env, bounded_deadline, bounded_output, execute

FAKE = ROOT / "tests" / "helpers" / "fake-cli.py"
SENTINEL = "SYNTHETIC_SECRET_SENTINEL"
ALLOWED_ENV = {
    "PATH",
    "HOME",
    "TERM",
    "LANG",
    "LC_ALL",
    "PYTHONNOUSERSITE",
    "PYTHONSAFEPATH",
    "PYTHONDONTWRITEBYTECODE",
}


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class ProbeTransportTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dirs: list[Path] = []
        self.procs: list[subprocess.Popen[bytes]] = []
        self.siblings: list[subprocess.Popen[bytes]] = []

    def tearDown(self) -> None:
        for proc in self.procs:
            if proc.poll() is None:
                try:
                    os.kill(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait(timeout=2)
        for sibling in self.siblings:
            if sibling.poll() is None:
                sibling.kill()
                sibling.wait(timeout=2)
        for directory in self.dirs:
            for name in ("pid", "sleep.pid"):
                file = directory / name
                if not file.exists():
                    continue
                try:
                    pid = int(file.read_text(encoding="utf-8").strip())
                except ValueError:
                    continue
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            shutil.rmtree(directory, ignore_errors=True)

    def make(self, mode: str | None) -> Path:
        directory = Path(tempfile.mkdtemp(prefix="herdr-probe-"))
        self.dirs.append(directory)
        if mode is not None:
            (directory / "mode").write_text(mode, encoding="utf-8")
        return directory

    def child_env(self, extra: dict[str, str] | None = None) -> dict[str, str]:
        env = os.environ.copy()
        env["ANTHROPIC_API_KEY"] = SENTINEL
        env["OPENAI_API_KEY"] = SENTINEL
        env["XAI_API_KEY"] = SENTINEL
        env["OPENAI_BASE_URL"] = "https://example.invalid/v1"
        env["NODE_OPTIONS"] = "--inspect"
        env.pop("HERDR_PROBE_LOCK", None)
        env.pop("LD_PRELOAD", None)
        if extra:
            env.update(extra)
        return env

    def command(
        self,
        cwd: Path,
        deadline: int,
        profile: str = "fixture-v1",
        executable: str | None = None,
    ) -> list[str]:
        return [
            sys.executable,
            str(ROOT / "probes" / "probe.py"),
            "--executable",
            executable or str(FAKE),
            "--profile",
            profile,
            "--cwd",
            str(cwd),
            "--deadline-ms",
            str(deadline),
        ]

    def launch(
        self,
        cwd: Path,
        deadline: int,
        profile: str = "fixture-v1",
        executable: str | None = None,
        env: dict[str, str] | None = None,
    ) -> dict[str, object]:
        proc = subprocess.Popen(
            self.command(cwd, deadline, profile, executable),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env or self.child_env(),
        )
        self.procs.append(proc)
        try:
            stdout, stderr = proc.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            os.kill(proc.pid, signal.SIGKILL)
            proc.communicate()
            self.fail("probe timed out in the test harness")
        self.assert_clean(stdout, stderr)
        payload = json.loads(stdout.decode("utf-8"))
        self.assertIsInstance(payload, dict)
        self.assertEqual(stderr.decode("utf-8").strip(), payload["reason"])
        return payload

    def assert_clean(self, stdout: bytes, stderr: bytes) -> None:
        self.assertNotIn(SENTINEL.encode(), stdout)
        self.assertNotIn(SENTINEL.encode(), stderr)
        self.assertNotIn(b"\x1b", stdout)
        self.assertNotIn(b"Session", stdout)
        self.assertNotIn(b"10% used", stdout)
        self.assertEqual(stdout.count(b"\n"), 1)
        self.assertNotIn(b"\n", stderr.strip())

    def test_cli_environment_strips_secrets_and_preload(self) -> None:
        previous_key = os.environ.get("ANTHROPIC_API_KEY")
        previous_preload = os.environ.get("LD_PRELOAD")
        os.environ["ANTHROPIC_API_KEY"] = SENTINEL
        os.environ["LD_PRELOAD"] = "/tmp/not-used.so"
        try:
            env = _cli_env("/tmp/herdr-probe-private")
        finally:
            if previous_key is None:
                os.environ.pop("ANTHROPIC_API_KEY", None)
            else:
                os.environ["ANTHROPIC_API_KEY"] = previous_key
            if previous_preload is None:
                os.environ.pop("LD_PRELOAD", None)
            else:
                os.environ["LD_PRELOAD"] = previous_preload
        self.assertEqual(set(env), ALLOWED_ENV)
        self.assertNotIn(SENTINEL, " ".join(env.values()))
        self.assertEqual(env["HOME"], "/tmp/herdr-probe-private")

    def test_deadline_and_output_bounds_do_not_sleep(self) -> None:
        self.assertEqual(DEFAULT_DEADLINE_MS, 20_000)
        self.assertEqual(MAX_OUTPUT_BYTES, 512 * 1024)
        self.assertEqual(bounded_deadline(None), 20_000)
        self.assertEqual(bounded_deadline(60_000), 20_000)
        self.assertEqual(bounded_deadline(50), 100)
        self.assertEqual(bounded_deadline(2_000), 2_000)
        self.assertEqual(bounded_output(9_999_999), MAX_OUTPUT_BYTES)

    def test_usage_pty_is_a_tty_and_drops_the_screen(self) -> None:
        cwd = self.make("usage")
        payload = self.launch(cwd, 60_000)
        self.assertTrue(payload["ok"])
        self.assertTrue(payload["isatty"])
        self.assertTrue(payload["recognized"])
        self.assertEqual(payload["sent"], ["/usage"])
        self.assertEqual(payload["state"], "parsed")
        self.assertEqual(payload["version"], "fixture-1.0.0")
        self.assertEqual(payload["reason"], "ok")
        self.assertEqual(payload["deadlineMs"], 20_000)
        self.assertTrue(payload["childReaped"])
        self.assertNotIn("screen", payload)
        self.assertEqual((cwd / "tty-check").read_text(encoding="utf-8"), "1")
        self.assertEqual((cwd / "keystrokes").read_bytes(), b"/usage\n")
        self.assertEqual(set((cwd / "env-audit").read_text(encoding="utf-8").splitlines()), ALLOWED_ENV)
        self.assertNotIn(SENTINEL, (cwd / "env-audit").read_text(encoding="utf-8"))
        self.assertFalse(alive(int((cwd / "pid").read_text(encoding="utf-8"))))

    def test_fragmented_redraw_still_recognizes_without_echoing_the_screen(self) -> None:
        cwd = self.make("fragment")
        payload = self.launch(cwd, 8_000)
        self.assertTrue(payload["recognized"])
        self.assertEqual(payload["sent"], ["/usage"])
        self.assertEqual((cwd / "keystrokes").read_bytes(), b"/usage\n")
        self.assertNotIn("screen", payload)

    def test_traps_receive_no_accepting_input(self) -> None:
        cases = (
            ("trust", "trust_prompt"),
            ("redeem", "redemption_prompt"),
            ("redeem-prompt", "redemption_prompt"),
            ("login", "login_required"),
            ("model", "model_prompt"),
        )
        for mode, reason in cases:
            with self.subTest(mode=mode):
                cwd = self.make(mode)
                payload = self.launch(cwd, 5_000)
                self.assertFalse(payload["ok"])
                self.assertEqual(payload["reason"], reason)
                self.assertEqual(payload["sent"], [])
                self.assertEqual((cwd / "keystrokes").read_bytes(), b"")
                self.assertFalse(alive(int((cwd / "pid").read_text(encoding="utf-8"))))

    def test_partial_line_without_a_prompt_times_out_before_typing(self) -> None:
        cwd = self.make("nonewline")
        started = time.monotonic()
        payload = self.launch(cwd, 2_000)
        elapsed = time.monotonic() - started
        self.assertEqual(payload["reason"], "timeout")
        self.assertEqual(payload["sent"], [])
        self.assertEqual((cwd / "keystrokes").read_bytes(), b"")
        self.assertLess(elapsed, 8)
        self.assertLessEqual(elapsed, 22)
        self.assertFalse(alive(int((cwd / "pid").read_text(encoding="utf-8"))))

    def test_exit_mid_screen_reaps_without_a_command(self) -> None:
        cwd = self.make("exit")
        payload = self.launch(cwd, 5_000)
        self.assertEqual(payload["reason"], "unrecognized_screen")
        self.assertEqual(payload["sent"], [])
        self.assertTrue(payload["childReaped"])
        self.assertFalse(alive(int((cwd / "pid").read_text(encoding="utf-8"))))

    def test_immediate_exit_is_closed_early(self) -> None:
        cwd = self.make("die")
        payload = self.launch(cwd, 5_000)
        self.assertEqual(payload["reason"], "closed_early")
        self.assertEqual(payload["sent"], [])
        self.assertTrue(payload["childReaped"])

    def test_unknown_version_sends_nothing(self) -> None:
        cwd = self.make("unknown-version")
        started = time.monotonic()
        payload = self.launch(cwd, 5_000)
        self.assertEqual(payload["reason"], "unknown_version")
        self.assertEqual(payload["version"], "99.0.0")
        self.assertEqual(payload["sent"], [])
        self.assertEqual((cwd / "keystrokes").read_bytes(), b"")
        self.assertLess(time.monotonic() - started, 5)

    def test_cancellation_kills_only_the_probe_group(self) -> None:
        cwd = self.make("slow")
        sibling = subprocess.Popen(["sleep", "60"], start_new_session=True)
        self.siblings.append(sibling)
        proc = subprocess.Popen(
            self.command(cwd, 20_000),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=self.child_env(),
        )
        self.procs.append(proc)
        pid = self.wait_pid(cwd / "pid")
        sleep_pid = self.wait_pid(cwd / "sleep.pid")
        os.kill(proc.pid, signal.SIGTERM)
        stdout, stderr = proc.communicate(timeout=8)
        self.assert_clean(stdout, stderr)
        payload = json.loads(stdout.decode("utf-8"))
        self.assertEqual(payload["reason"], "cancelled")
        self.assertEqual(payload["sent"], [])
        self.assertTrue(payload["childReaped"])
        self.assertFalse(self.wait_dead(pid))
        self.assertFalse(self.wait_dead(sleep_pid))
        self.assertTrue(alive(sibling.pid))

    def test_held_lock_does_not_spawn(self) -> None:
        cwd = self.make("usage")
        lock = cwd / "held.lock"
        fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            import fcntl

            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            payload = self.launch(cwd, 2_000, env=self.child_env({"HERDR_PROBE_LOCK": str(lock)}))
        finally:
            os.close(fd)
        self.assertEqual(payload["reason"], "probe_busy")
        self.assertFalse((cwd / "pid").exists())

    def test_relative_executable_is_not_launched(self) -> None:
        cwd = self.make("usage")
        payload = self.launch(cwd, 2_000, executable="fake-cli.py")
        self.assertEqual(payload["reason"], "not_absolute")
        self.assertFalse((cwd / "pid").exists())

    def test_unsafe_profile_does_not_spawn(self) -> None:
        cwd = self.make("usage")
        args = ProbeArgs(executable=str(FAKE), profile="claude", cwd=str(cwd), deadline_ms=2_000)
        with mock.patch("probes.probe.subprocess.Popen", side_effect=AssertionError("launched")):
            payload = execute(args)
        self.assertEqual(payload["reason"], "profile_unsafe")
        self.assertEqual(payload["sent"], [])
        self.assertFalse((cwd / "pid").exists())
        cli = self.launch(cwd, 2_000, profile="claude")
        self.assertEqual(cli["reason"], "profile_unsafe")
        self.assertFalse((cwd / "pid").exists())

    def test_output_limit_stops_a_flood_without_typing(self) -> None:
        cwd = self.make("flood")
        started = time.monotonic()
        payload = self.launch(cwd, 20_000)
        self.assertEqual(payload["reason"], "output_limit")
        self.assertEqual(payload["sent"], [])
        self.assertTrue(payload["childReaped"])
        self.assertLess(time.monotonic() - started, 15)
        self.assertFalse(self.wait_dead(int((cwd / "pid").read_text(encoding="utf-8"))))

    def test_fake_cli_rejects_a_pipe(self) -> None:
        cwd = self.make(None)
        proc = subprocess.run([str(FAKE)], cwd=cwd, capture_output=True, check=False)
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(proc.stderr, b"not_a_tty\n")
        self.assertEqual((cwd / "tty-check").read_text(encoding="utf-8"), "0")

    def wait_pid(self, file: Path) -> int:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if file.exists() and file.stat().st_size > 0:
                return int(file.read_text(encoding="utf-8").strip())
            time.sleep(0.02)
        self.fail(f"missing {file.name}")
        return 0

    def wait_dead(self, pid: int) -> bool:
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and alive(pid):
            time.sleep(0.02)
        return alive(pid)


if __name__ == "__main__":
    unittest.main()
