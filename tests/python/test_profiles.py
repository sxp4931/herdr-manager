import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from probes.profiles import (
    ProfileError,
    classify_screen,
    extract_version,
    get_profile,
    validate_args,
    validate_command,
    validate_key,
    validate_startup,
    version_supported,
)


class ProfileValidationTest(unittest.TestCase):
    def test_exact_fixture_version_does_not_cover_the_rest_of_the_major(self) -> None:
        profile = get_profile("fixture-v1")
        self.assertEqual(profile.supported_versions, ("fixture-1.0.0",))
        self.assertEqual(extract_version(["fixture-cli fixture-1.0.0", ">"]), "fixture-1.0.0")
        self.assertEqual(extract_version(["fixture-cli 99.0.0", ">"]), "99.0.0")
        self.assertTrue(version_supported(profile, "fixture-1.0.0"))
        self.assertFalse(version_supported(profile, "fixture-1.9.0"))
        self.assertFalse(version_supported(profile, "99.0.0"))
        self.assertTrue(profile.launch_allowed)
        self.assertFalse(profile.menu_enter_allowed)

    def test_live_profiles_are_unsafe_to_launch(self) -> None:
        for name in ("claude", "codex", "grok"):
            with self.subTest(name=name):
                profile = get_profile(name)
                self.assertFalse(profile.launch_allowed)
                with self.assertRaises(ProfileError) as caught:
                    validate_startup(profile)
                self.assertEqual(caught.exception.reason, "profile_unsafe")

    def test_prose_resume_print_and_extra_arguments_are_rejected(self) -> None:
        profile = get_profile("fixture-v1")
        with self.assertRaises(ProfileError) as prose:
            validate_command("please show /usage", profile)
        self.assertEqual(prose.exception.reason, "prose_rejected")
        validate_command("/usage", profile)
        validate_command("/status")
        with self.assertRaises(ProfileError) as wrong:
            validate_command("/status", profile)
        self.assertEqual(wrong.exception.reason, "command_rejected")
        for args, reason in (
            (["--resume"], "resume_rejected"),
            (["--continue"], "resume_rejected"),
            (["-p"], "print_rejected"),
            (["--print"], "print_rejected"),
            (["--model", "opus"], "extra_args_rejected"),
        ):
            with self.subTest(args=args):
                with self.assertRaises(ProfileError) as caught:
                    validate_args(args)
                self.assertEqual(caught.exception.reason, reason)

    def test_action_keys_menu_enter_and_unscoped_escape_are_rejected(self) -> None:
        with self.assertRaises(ProfileError) as action:
            validate_key("y")
        self.assertEqual(action.exception.reason, "action_key_rejected")
        with self.assertRaises(ProfileError) as enter:
            validate_key("\r", on_menu=True, screen="known_usage_screen")
        self.assertEqual(enter.exception.reason, "menu_enter_rejected")
        with self.assertRaises(ProfileError) as escape:
            validate_key("\x1b", screen="unrecognized")
        self.assertEqual(escape.exception.reason, "escape_rejected")
        validate_key("\x1b", screen="known_usage_screen")
        validate_key("/usage")

    def test_startup_hooks_plugins_and_mcp_are_rejected(self) -> None:
        profile = get_profile("fixture-v1")
        validate_startup(profile)
        for extra in (["--plugin", "net"], ["--mcp-config", "x"], ["--hook", "before"]):
            with self.subTest(extra=extra):
                with self.assertRaises(ProfileError) as caught:
                    validate_startup(profile, extra)
                self.assertEqual(caught.exception.reason, "startup_rejected")

    def test_screen_classification_prefers_traps_over_a_prompt(self) -> None:
        self.assertEqual(classify_screen(["hello there"]), "unrecognized")
        self.assertEqual(classify_screen(["catalog"]), "unrecognized")
        self.assertEqual(classify_screen(["Redeem reset", ">"]), "redeem")
        self.assertEqual(classify_screen(["Do you trust this folder?"]), "trust")
        self.assertEqual(classify_screen(["Sign in to continue"]), "login")
        self.assertEqual(classify_screen(["Select a model"]), "model")
        self.assertEqual(classify_screen(["Session  10% used", "Weekly  20% used"]), "usage")
        self.assertEqual(classify_screen(["fixture-cli fixture-1.0.0", ">"]), "empty_prompt")


if __name__ == "__main__":
    unittest.main()
