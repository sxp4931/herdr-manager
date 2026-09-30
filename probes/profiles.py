"""Version-exact probe profiles. Live CLIs stay unsafe until startup is proven inert."""

from __future__ import annotations

import re
from dataclasses import dataclass

SLASH_COMMAND = re.compile(r"^/(usage|status)$")
VERSION_LINE = re.compile(r"fixture-cli\s+((?:fixture-)?[0-9]+\.[0-9]+\.[0-9]+)")
KNOWN_ESCAPE_SCREENS = frozenset({"empty_prompt", "command_sent", "known_usage_screen"})


class ProfileError(Exception):
    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


@dataclass(frozen=True)
class Profile:
    profile_id: str
    provider: str
    supported_versions: tuple[str, ...]
    commands: tuple[str, ...]
    empty_prompt: str
    usage_markers: tuple[str, ...]
    launch_allowed: bool
    unsafe_reason: str
    menu_enter_allowed: bool = False
    startup_args: tuple[str, ...] = ()


def _live(provider: str, command: str) -> Profile:
    return Profile(
        profile_id=f"{provider}-unverified",
        provider=provider,
        supported_versions=(),
        commands=(command,),
        empty_prompt=">",
        usage_markers=(),
        launch_allowed=False,
        unsafe_reason="startup hooks and MCP are not proven inert",
    )


FIXTURE_PROFILE = Profile(
    profile_id="fixture-v1",
    provider="fixture",
    supported_versions=("fixture-1.0.0",),
    commands=("/usage",),
    empty_prompt=">",
    usage_markers=("Session", "% used", "Weekly"),
    launch_allowed=True,
    unsafe_reason="",
)

PROFILES: dict[str, Profile] = {
    "fixture-v1": FIXTURE_PROFILE,
    "claude": _live("claude", "/usage"),
    "codex": _live("codex", "/status"),
    "grok": _live("grok", "/usage"),
}


def get_profile(name: str) -> Profile:
    try:
        return PROFILES[name]
    except KeyError as exc:
        raise ProfileError("unknown_profile") from exc


def version_supported(profile: Profile, version: str | None) -> bool:
    return version is not None and version in profile.supported_versions


def extract_version(lines: list[str]) -> str | None:
    match = VERSION_LINE.search("\n".join(lines))
    if match is None:
        return None
    return match.group(1)


def validate_command(command: str, profile: Profile | None = None) -> None:
    if not isinstance(command, str) or SLASH_COMMAND.fullmatch(command) is None:
        raise ProfileError("prose_rejected")
    if profile is not None and command not in profile.commands:
        raise ProfileError("command_rejected")


def validate_args(args: list[str]) -> None:
    for arg in args:
        if arg in {"--resume", "--continue", "resume", "continue"} or arg.startswith("--resume") or arg.startswith("--continue"):
            raise ProfileError("resume_rejected")
        if arg in {"-p", "--print"}:
            raise ProfileError("print_rejected")
        raise ProfileError("extra_args_rejected")


def validate_key(key: str, *, on_menu: bool = False, screen: str = "unrecognized") -> None:
    if key in {"y", "Y"}:
        raise ProfileError("action_key_rejected")
    if on_menu and key in {"\r", "\n"}:
        raise ProfileError("menu_enter_rejected")
    if key == "\x1b":
        if screen not in KNOWN_ESCAPE_SCREENS:
            raise ProfileError("escape_rejected")
        return
    stripped = key.strip("\r\n")
    if SLASH_COMMAND.fullmatch(stripped):
        return
    raise ProfileError("key_rejected")


def validate_startup(profile: Profile, extra: list[str] | None = None) -> None:
    if not profile.launch_allowed:
        raise ProfileError("profile_unsafe")
    args = [*profile.startup_args, *(extra or [])]
    for arg in args:
        lowered = arg.lower()
        if (
            lowered.startswith("--plugin")
            or lowered.startswith("--mcp")
            or lowered.startswith("--hook")
            or lowered.startswith("--dangerously")
            or "plugin" in lowered
            or "mcp" in lowered
        ):
            raise ProfileError("startup_rejected")
    validate_args(args)


def classify_screen(lines: list[str]) -> str:
    cleaned = [line.rstrip() for line in lines]
    lowered = "\n".join(cleaned).lower()
    if "redeem reset" in lowered:
        return "redeem"
    if "trust this folder" in lowered or "trust this workspace" in lowered:
        return "trust"
    if "sign in" in lowered or "log in" in lowered:
        return "login"
    if "select a model" in lowered:
        return "model"
    body = "\n".join(cleaned)
    if "Session" in body and "% used" in body and "Weekly" in body:
        return "usage"
    if any(line == ">" for line in cleaned):
        return "empty_prompt"
    return "unrecognized"
