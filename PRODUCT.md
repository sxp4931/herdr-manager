# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

Native Apple app: macOS 14+ menu-bar utility (SwiftUI). Apple-native platform guidance applies.

## Users

Primary user: the owner — a developer orchestrating a herd of ~22–34 concurrent AI coding agents (Claude Code, Codex, OpenCode) through herdr on a single Mac, in long parallel sessions where agents run while attention is elsewhere.

Job: know instantly whether anything across the whole herd needs attention, unblock it in one or two actions, and keep awareness of what the herd is costing.

Confirmed: the tool **might be shared someday** with other herdr users. Design must not hard-code this machine's specifics (session layout, workspace count, socket paths, agent mix) where keeping them general is cheap.

## Product Purpose

Shepherd exists to answer "does anything need me?" across the whole herd without a click, and "what's stopping this agent, and how do I get it moving?" in one view. Three durable pillars (all confirmed core):

1. **Attention triage** — worst-state-wins menu-bar signal; attention-first panel (not a census); dwell time, which herdr itself cannot show.
2. **Stuck diagnosis & unblock** — classify (awaiting input / silent / process gone / unclassifiable), surface *what* it waits on, and act safely — from the UI and via MCP tools so an orchestrating agent drives the same live state.
3. **Usage/cost awareness** — model-aware token/cost tracking with official per-model pricing, framed honestly as an estimate, not a bill.

Success means: the menu bar is trusted at a glance; unblocking takes seconds; no state is ever fabricated.

## Positioning

herdr shows state; Shepherd shows **attention**. The mechanisms a neighboring product could not truthfully copy: Manager-owned time (dwell and silence durations that herdr never timestamps), diagnosis over the exact bytes herdr itself classified on, and one shared live state that a human and their orchestrating agent both act on under one policy.

## Operating Context

- Always-running macOS menu-bar app (`Shepherd.app`; dev via `swift run ShepherdApp`), plus `herdmgr` CLI and `herdr-manager-mcp` stdio bridge spawned by agent hosts (Claude Code / Codex / OpenCode).
- Talks to herdr's local per-session JSON socket API (`~/.config/herdr/…`, XDG-aware). Verified baseline: herdr 0.7.5, protocol 17. Compatibility is capability-based: unknown protocols disable writes with a visible reason while reads continue.
- Daily rituals: the morning sweep ("what needs me?"), answering permission prompts, killing idle panes, checking what today's work cost.
- Durable state in `~/Library/Application Support/HerdrManager/` (mode 0700/0600, advisory locking, 30-day journal retention): action store, journal, dwell episodes.
- Keyboard-first panel: ⌥H toggles; type to filter; Space peeks without consuming `done`; ⏎ focuses the pane in herdr.

## Capabilities and Constraints

Capabilities: subscription-driven live status; attention-only default view with per-space summaries; inline peek (tail + parsed prompt + choice buttons); bounded answers to blocked agents; interrupt/stop with confirmation; `session.spawn` with repo allowlist; notifications (blocked, silent-past-threshold) with coalescing and post-reconnect suppression; secret redaction on all outbound pane text; usage/cost dashboard.

Durable constraints:

- **Never auto-focus** — focusing consumes herdr's `done` state; focus happens only on explicit user action.
- **Never fabricate state** — stale data shown as stale ("as of HH:MM"); herdr down shows greyed last snapshot, never invented figures.
- **Never send input to a pane whose process is gone; never auto-retry input.**
- **Bounded tools only** — no free-form shell passthrough, no god-tool; writes policy-gated in the app (read free, reply gated, kill confirmed); the MCP bridge is dumb by design.
- **All durations are Manager-owned** — herdr timestamps nothing.
- All herdr knowledge isolated behind the adapter boundary; schema-hash pinning detects API drift at connect.
- Lightweight: every dependency and background process earns its place (one external dependency today: swift-argument-parser). Swift 6 strict concurrency; macOS 14+.

Open product questions live in `PLAN.md` §10; where the build resolved them, the shipped code is the authority.

## Brand Commitments

- Name: **Shepherd** ("Herdr Manager" is the internal repo/project name). Confirmed binding.
- The **herd/flock metaphor is identity**: "the herd", the flock mark (SF Symbol `point.3.connected.trianglepath.dotted` with runtime fallbacks), and one status-light vocabulary running menu bar → rail → pill → dot.
- A clean native macOS utility with a **single warm amber accent**; two-layer color system: adaptive body palette (per-appearance, AA-tuned) and fixed system colors for the menu-bar badge.
- WCAG AA (≥4.5:1) contrast intent for text in light and dark.
- App icon: `Resources/AppIcon*` (redesigned 2026-08).
- Voice: domain-native, calm, honest — "Needs you", exact dwell figures, "estimate, not a bill".

## Evidence on Hand

- `PLAN.md` — source-verified design & build plan (herdr findings, capability matrix, MCP surface, UI spec, safety model, phases).
- Live herdr environment on this Mac (`~/.config/herdr/herdr.sock`) — a real herd to test against.
- Prior impeccable critique: `.impeccable/critique/2026-08-06T22-49-07Z__sources-shepherdapp.md` (28/40; four P1s; persona red flags).
- Working app and icon assets in-repo; `Sources/ShepherdApp/Brand.swift` encodes the palette and mark.
- Absences future work must not fabricate: no testimonials, customers, press, or marketing claims; cost figures are estimates, never bills.

## Product Principles

1. **Attention over information** — show what needs the user, not a census; counts are attention items only.
2. **Honesty over completeness** — never fabricate state or durations; degraded is shown as degraded, with a reason.
3. **One state, two hands** — the UI and the orchestrating agent act on the same live store under the same policy.
4. **Safety by shape** — bounded choices, revalidate-before-send, confirmation for irreversible acts; no god-tool.
5. **Earn the glance** — the menu bar answers "does anything need me?" without a click; everything else is one or two actions away.

## Accessibility & Inclusion

Keyboard-first panel (fully operable without a mouse), with its arrow/space/return bindings named in the footer rather than left to documentation. WCAG AA contrast target in both appearances, encoded in `Brand.swift`.

The two open items from the 2026-08-06 critique are closed, and the shape of the fix is now a standing rule: **no state may be encoded by colour alone.** Every status colour is paired with a glyph (`Brand.symbolName(for:)`, drawn in the row's status light), a menu-bar silhouette (`Brand.worstShape(blocked:silent:)` — triangle → diamond → circle, worst-first), and a word (`Brand.stateWord(for:)`, in the row's state pill), all derived from the same decision so they cannot drift apart. Approve and Deny differ by glyph and by fill weight before they differ by hue. Dwell time escalates in weight as well as colour. Work that adds a status signal is expected to carry all three encodings.
