# Repository Guidelines

## Project Structure & Module Organization

This is a Swift 6 package targeting macOS 14+. Shared domain, adapter, diagnosis, policy, persistence, and redaction code lives in `Sources/HerdrManagerCore/`. Keep reusable behavior there so all three front ends stay consistent:

- `Sources/ShepherdApp/`: SwiftUI menu-bar application (product name "Shepherd").
- `Sources/herdmgr/`: command-line status client.
- `Sources/herdr-manager-mcp/`: stdio JSON-RPC/MCP server.
- `Tests/HerdrManagerCoreTests/`: core unit tests.
- `Resources/`: app icons; `Tools/GenerateIcon/` contains icon-generation support.

`PLAN.md` documents protocol assumptions and architecture. Treat the herdr socket adapter as the boundary for upstream API changes.

## Build, Test, and Development Commands

- `swift build`: compile all package targets in debug mode.
- `swift test`: run the Swift Testing suite.
- `swift run herdmgr --show-all`: display live agents from the local herdr socket.
- `swift run ShepherdApp`: launch the development menu-bar executable.
- `swift run herdr-manager-mcp`: start the MCP server over stdin/stdout.
- `./build-app.sh`: create a release-mode `Shepherd.app` bundle with its icon.

Live commands require herdr to be running and its socket to be available under the configured XDG directory.

## Coding Style & Naming Conventions

Use four-space indentation and follow standard Swift API naming: `UpperCamelCase` for types, `lowerCamelCase` for properties and functions, and descriptive enum cases. Keep files focused on one primary responsibility. Preserve Swift 6 concurrency guarantees with `Sendable`, actors, and explicit isolation; do not bypass them casually. No formatter or linter is configured, so match the surrounding source and keep imports minimal.

## Testing Guidelines

Tests use Apple’s Swift Testing framework (`import Testing`), with behavior-focused `@Suite` and `@Test` descriptions and `#expect` assertions. Name files `*Tests.swift` and place them under `Tests/HerdrManagerCoreTests/`. Add regression coverage for adapter decoding, policy decisions, persistence, redaction, and state classification. Run `swift test` before submitting; no numeric coverage threshold is currently enforced.

## Commit & Pull Request Guidelines

The history favors a concise, descriptive subject such as `Herdr Manager: add MCP confirmation flow`, followed by a body for significant targets or behavior. Keep commits scoped and avoid mixing generated bundles with unrelated source changes. Pull requests should explain user-visible impact, protocol or security implications, and validation performed. Link relevant issues or plan sections, and include screenshots for menu-bar UI changes. Never commit credentials, socket data, journals, or unredacted agent output.
