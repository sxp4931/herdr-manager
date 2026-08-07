---
target: Shepherd menu-bar app UI (Sources/ShepherdApp)
total_score: 28
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 4
p2_count: 3
timestamp: 2026-08-06T22-49-07Z
slug: sources-shepherdapp
---
# Shepherd UI Critique — Sources/ShepherdApp (2026-08-06)

Method: dual-agent (A: tinker design review; B: general build+live-screenshot evidence). herdr LIVE (22 agents, 1 running); panel captured in dark + light mode.

## Design Health Score: 28/40 (Good)

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Live counts, lights, menu-bar attention count excellent; "connecting…"/peek "Reading…" text-only, no usage-refresh progress |
| 2 | Match System / Real World | 3 | Domain-native vocabulary (blocked/silent/dwell/nudge/peek/jump/"the herd"); "Needs you" scope includes done agents — overpromises |
| 3 | User Control and Freedom | 3 | Esc cascade, close-confirm are thoughtful; no undo for the most consequential actions (approve/deny) |
| 4 | Consistency and Standards | 2 | Weakest: 4 typefaces in casual use; orange = silent-state, warn-reason, pending-actions, health-banner simultaneously; 3 text-input treatments |
| 5 | Error Prevention | 3 | Close confirms; pending-actions pane.close/agent.stop are one-click no-confirm; pricing form silently no-ops on invalid input |
| 6 | Recognition Rather Than Recall | 3 | Search covers every visible field; "⋯" menu + hidden context-menu overrides force recall |
| 7 | Flexibility and Efficiency | 4 | Keyboard nav, ⌘U/⌘R, double-click jump, collapsible groups, threshold overrides — instrument-grade |
| 8 | Aesthetic and Minimalist Design | 3 | Calm and coherent; dense rows (5 stacked fragments) and 220pt mono peek push the limit |
| 9 | Error Recovery | 2 | Error banner has no Retry; peek failure is grey-on-grey; pricing saves fail silently |
| 10 | Help and Documentation | 2 | .help tooltips good; overrides undiscoverable, disconnected state doesn't teach, dense caveat buried |

## Design Specificity Verdict
Authored FOR this product, unusually well: worst-state-wins verdict mapping (process-gone folded into blocked), earned flock mark with runtime fallback, one status-light vocabulary running menu-bar → rail → pill → dot. The triage core is specific; the chrome is thin (amber-on-teal wash barely reads; usage dashboard would transplant to any cost tool).

## Priority Issues
1. **P1 — Light-mode contrast collapse (evidence, B).** Amber cost "Today $27.28" ≈1.2:1, WORKING pill ≈1.2:1, IDLE pill ≈1.7–2.7:1, orange warn ≈1.6–1.8:1, tertiary ≈1.5–2.2:1 in light mode; dark-mode pills 2.3–3.8, header subtitle 4.1–4.5. Fix: darken amber/status colors for light surfaces; target WCAG AA 4.5:1; verify both modes.
2. **P1 — Approve/Deny weightless and irreversible.** Two 11pt borderless text buttons, no consequence framing, no undo; high-stakes (spawn/stop/answer) at footnote weight. Fix: real bordered buttons w/ consequence labels, confirm for stop/close-type, consider undo toast.
3. **P1 — Reason line (triage payload) is visually weakest.** 11.5pt secondary, same size as location filler; eye lands on title/pill, hunts for why. Fix: reason 12.5pt medium, outrank location, reduce location to 10.5pt.
4. **P1/P2 — "Needs you" includes done agents.** Label and header count overpromise; primes wrong anxiety. Fix: separate done from "needs you" or rename scope; split subtitle counts.
5. **P2 — Typeface/color vocabulary overload.** 4 typefaces, orange triple-duty, 3 input treatments. Fix: one display face (rounded) for brand moments, mono strictly for data, distinct warning-orange.
6. **P2 — Usage dashboard buries the caveat + silent save failure.** Headline 22pt amber cost reads as a bill; "estimate, not a bill" is a dense paragraph at bottom; invalid pricing returns silently. Fix: inline one-line caveat under the number; visible save feedback.
7. **P2 — Error recovery reactive.** No retry on banner; peek failure grey; pricing silent. Fix: Retry button, orange peek-failure w/ retry, save error message.
8. **P3 — "⋯" hides Nudge/Close; fixed 500pt panel; tiny first-run CTA; lossy cwd truncation (~2 chars) (A+B).**

## Persona Red Flags
- **Alex (power user):** reason line below location in weight; Nudge behind "⋯"; threshold overrides invisible in context menu — scan pattern and action discoverability both miss.
- **Jordan (first-timer):** disconnected state shows raw socket path with no "start herdr" guidance; "Needs you" count inflates; OK/Deny text buttons with no consequence explanation at the most intimidating moment.
- **Sam (a11y):** attention hierarchy is color-only (red>amber>blue) with no redundant encoding; green OK / red Deny is the classic color-blind-failing pair; 9.5–10.5pt tertiary and amber-on-teal fail WCAG.

## Cognitive Load: 3/8 failures
Visual hierarchy (reason doesn't lead), minimal choices (pending-action OK/Deny lack separation), working memory ("⋯" menu + hidden context menu). Single biggest load issue: row hierarchy.

## Minor Observations
Reason/location same size; 9.5pt tertiary too small; two "back" conventions; group header ultraThinMaterial vs panel regularMaterial; fullwidth "＋" vs SF Symbols; scope picker .large with counts may crowd; header counts computed twice (drift risk); peek has no Copy button; 500×540 hand-tuned budget drifts with content; location cwd truncates to ~2 chars (B evidence).

## Questions
1. What if the most frequent + highest-stakes action (Approve/Deny) carried the most visual weight?
2. Is "Needs you" honest — or should done move out and the reason lead the row?
3. Should the closed-panel state get a quick-triage surface (approve/deny/nudge from notification/menu)?
4. Should the herd metaphor's warmth extend to the action moments (weighted, deliberate, reassuring)?
