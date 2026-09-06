# Grok quality burn — Shepherd (herdr-manager)

## Hard stop
Stop by **2026-09-06 13:50 America/New_York** (soft). Hard 14:00 ET. Local commits only — no push/PR/merge/deploy/notarize.

## Anti-junk
- Real reliability, clarity, test coverage, or UX fixes only — no cosmetic churn.
- Stay on branch `grok/quality-burn-0906`. Never touch main.
- Prefer HerdrManagerCore + tests; keep Swift 6 concurrency.
- Run `swift test` (or targeted tests) after changes when the toolchain allows; if swift unavailable, still write tests and reason carefully.
- Do not commit secrets, sockets, journals, DMGs, or unredacted agent logs.
- Respect AGENTS.md / PLAN.md adapter boundary for herdr protocol.
