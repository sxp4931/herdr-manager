# Explore Brief — ShepherdApp UI Enhancement Pass

> Baseline for the UI enhancement. Derived from the 2026-08-06 dual-agent design
> critique (28/40 heuristics; persisted at
> `.impeccable/critique/2026-08-06T22-49-07Z__sources-shepherdapp.md`).

## Goal

Greatly improve the Shepherd menu-bar app UI (target: `Sources/ShepherdApp/`,
SwiftUI, macOS 14+). Direction chosen by the user: **neutral system polish** —
drop the deep-teal/amber "field" metaphor into the background, make the app read
as a clean native macOS utility with system colors and minimal brand, AND fix
every P1/P2/P3 issue the critique found (user selected "Everything incl. P3").

## Scope (in)

1. **Fix light-mode contrast collapse (P1, evidence-backed).** Light mode:
   amber cost ≈1.2:1, WORKING pill ≈1.2:1, IDLE pill ≈1.7–2.7:1, orange
   warnings ≈1.6–1.8:1, tertiary text ≈1.5–2.2:1. Dark mode: pills 2.3–3.8,
   header subtitle 4.1–4.5. Target: WCAG AA 4.5:1 for body text in BOTH
   appearances; non-text (dots, rails, glow) ≥3:1.
2. **Weight the action moments (P1).** Approve/Deny in `PendingActionsView`
   must become real bordered buttons with consequence framing
   ("Approve Spawn", "Deny"), adequate hit targets, and — for destructive
   tools (`pane.close`, `agent.stop`, close) — a confirmation step like the
   row's close-confirm. No undo scope creep; confirmation is the fix.
3. **Row hierarchy (P1).** The reason line (triage payload) must outrank the
   location line: reason ~12.5pt medium, location ~10.5pt secondary. Title
   stays the top weight.
4. **"Needs you" semantics (P1).** "Needs you" scope must exclude `done`
   agents (a finished agent does not need you). Done agents surface in
   "All" scope; header subtitle splits counts: "N need you · D done · M running".
   Menu-bar worst-state logic keeps `done` → blue (serene signal, unchanged).
5. **Vocabulary consistency (P2).** One typeface system (`.system`); keep
   `.monospaced` strictly for data (dwell, cost, params, peek, prices). Stop
   using orange for three meanings: silent-state uses the silent amber,
   warnings/banners use a distinct system-orange, pending-actions use
   system-orange. Unify text-input treatments (roundedBorder everywhere).
6. **Usage dashboard (P2).** One-line caveat ("Estimate — not a bill") under
   the headline cost number; inline validation message on failed Save instead
   of silent no-op.
7. **Error recovery (P2).** Error banner gets a Retry button; peek failure
   shows orange text + a Retry affordance; pricing save shows a visible error.
8. **Neutral chrome (direction).** Remove/reduce the teal field washes and
   amber radial glow from `panelBackground`; keep the flock mark but make it
   quieter (system-consistent tone, restrained glow). Menu-bar icon logic
   unchanged (template calm / fixed-color attention) but attention colors
   follow the fixed palette.
9. **P3 batch:** promote "Nudge" out of the "⋯" menu (visible button; keep
   Close behind the menu); allow the peek to copy its content (Copy button);
   make the first-run "No agents yet" CTA a prominent bordered button;
   fix the lossy cwd truncation in the location line ("~T…" → full basename);
   replace the fullwidth "＋" with an SF Symbol; make group headers match the
   panel material (drop `ultraThinMaterial` mismatch); unify the two "back"
   conventions; bump ≥9.5pt font floor; single source of truth for header
   counts.

## Non-goals

- No changes to `HerdrManagerCore` behavior, adapter, policy, persistence,
  or the herdr protocol.
- No new features, no model changes, no package dependencies.
- No layout restructuring (keep 500pt panel, header/filter/content/footer
  structure, keyboard nav, Esc cascade, shortcuts).
- No icon redraws beyond color/weight adjustments; no animation system
  changes (static glow is deliberate — MenuBarExtra flicker).
- No removal of existing copy/behavior; buttons keep their current actions.

## Key decisions

- **Palette — TWO layers (gate SF-1):**
  - *Body/panel layer:* adaptive system-aligned colors (dynamic `Color(nsColor)`
    with light/dark variants, both AA). Status vocabulary: blocked=red,
    silent=amber, done=blue, working=green, idle/unknown=gray.
  - *Menu-bar layer (FIXED, gate SF-1):* `MenuBarIcon` renders an `NSImage`
    baked at paint time — adaptive colors would resolve against the wrong
    appearance (panel vs bar). The attention badge (`composite(tint:)` +
    `Brand.worstColor`) MUST use fixed system colors:
    `NSColor.systemRed` / `NSColor.systemYellow` / `NSColor.systemBlue`.
    Keep the `Brand` API shape; add a fixed `Brand.menuBar*` palette rather
    than converting call sites.
- **Amber cost text (gate SF-2):** the "Today $X API equivalent" line in
  `AgentRow` is body text and must be ≥4.5:1 in light mode. Use an adaptive
  **darkened amber** variant (light≈#8a5a00-class, dark=bright amber), not
  `Brand.amber.opacity(0.9)`. Same treatment for the dashboard headline cost.
- **Peek failure gets a structural case (gate SF-3):** extend `RowExpansion`
  with `.peekFailed(String)` (view-layer only) carrying the error; render
  orange text + Retry (re-runs the peek). Fold the new case into the
  `rowHeight` inline-expansion branch so the panel budget doesn't grow.
- **Search focus ring (gate SF-4):** keep the custom search field but make the
  focus ring an adaptive accent meeting ≥3:1 in both modes (light = darkened
  amber, dark = bright amber). Do NOT mix: pick custom-with-adaptive-ring.
- **Error-banner Retry (gate SF-5):** the Retry button calls `appModel.resync()`
  with help text "Re-connect / Retry sync". Accept that `lastError` may clear
  on the 3s poll; the banner already explains the source.
- **Header subtitle counts (gate SF-6):** derive N need-you / D done / M
  running ALL from the same search-filtered sets used by the list and scope
  picker (single source of truth; internally consistent under search).
  Needs-you count = filtered needsYouAgents; done = filtered done; running =
  filtered running.
- **Inputs:** standard `.roundedBorder` text fields everywhere (search keeps
  its custom focused look with the adaptive ring per gate SF-4).
- **Buttons:** `.bordered`/`.borderedProminent` for all action buttons in
  pending-actions and the row action row; destructive actions get confirm
  inline (pattern already exists in `AgentRow` close-confirm).
- **Implementation target:** pure SwiftUI view-layer changes in
  `Sources/ShepherdApp/` only. `Brand.swift` is the token home; keep the
  `Brand` enum API shape so `MenuBarIcon`/callers don't churn unnecessarily.

## Constraints

- Swift 6, macOS 14+, SwiftUI, AppKit interop where already used.
- No formatter/linter configured; match surrounding style (4-space indent).
- Must `swift build` clean and pass `swift test` (Swift Testing).
- Live herdr is running on this machine (22 agents) — the app renders live
  data; screenshots can capture real content in both light and dark mode.

## Acceptance criteria

- `swift build` exits 0 with no new warnings; `swift test` passes.
- Light-mode screenshots show: pills/cost/reason text ≥4.5:1 (measured with a
  contrast checker against the sampled background), "Needs you" excludes done,
  Approve/Deny are bordered buttons with consequence labels + confirm on
  destructive tools, reason line visually outranks location, error banner has
  Retry, dashboard headline has the estimate caveat, no teal/amber washes in
  the panel background.
- Dark-mode screenshots show the same fixes at ≥4.5:1 where applicable.
- Menu-bar attention badge renders in fixed system colors on BOTH bar
  appearances (no light-variant badge on a dark bar).
- Re-run `/impeccable critique`-style heuristics: total ≥34/40 with zero P0/P1.