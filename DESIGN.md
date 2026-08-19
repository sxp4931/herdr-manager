---
name: Shepherd
description: A calm, navy macOS menu-bar utility for triaging a herd of AI coding agents
colors:
  amber: "#8A5A00"
  amber-deep: "#6B4500"
  blocked: "#B3261E"
  silent: "#8A5A00"
  done: "#1E4BD2"
  working: "#1A3A69"
  idle: "#586274"
  unknown: "#5F666B"
  warn: "#C2410C"
  approve-fill: "#1A3A69"
  pill-blocked: "#991A12"
  pill-silent: "#6B4500"
  pill-done: "#17389E"
  pill-working: "#142D54"
  pill-idle: "#3C4452"
  pill-unknown: "#43474C"
  secondary-text: "#5A5F64"
typography:
  display:
    fontFamily: "SF Pro Rounded"
    fontSize: "22px"
    fontWeight: 700
  title:
    fontFamily: "SF Pro"
    fontSize: "15px"
    fontWeight: 700
  body:
    fontFamily: "SF Pro"
    fontSize: "12.5px"
    fontWeight: 500
  label:
    fontFamily: "SF Pro"
    fontSize: "10.5px"
    fontWeight: 600
  mono:
    fontFamily: "SF Mono"
    fontSize: "10.5px"
    fontWeight: 500
rounded:
  card: "10px"
  field: "7px"
  peek: "6px"
  pill: "999px"
  circle: "50%"
spacing:
  gutter: "14px"
  xs: "4px"
  sm: "6px"
  md: "8px"
  lg: "10px"
  xl: "12px"
components:
  agent-row-card:
    backgroundColor: "{colors.primary-opacity-0025}"
    rounded: "{rounded.card}"
    padding: "12px"
  state-pill:
    backgroundColor: "{colors.blocked}@14%"
    textColor: "{colors.pill-blocked}"
    rounded: "{rounded.pill}"
    padding: "7px 2.5px"
  button-approve:
    backgroundColor: "{colors.approve-fill}"
    textColor: "#FFFFFF"
    rounded: "{rounded.field}"
  button-bordered:
    textColor: "{colors.secondary-text}"
    rounded: "{rounded.field}"
  search-field:
    backgroundColor: "{colors.primary}@5%"
    rounded: "{rounded.field}"
  usage-card:
    backgroundColor: "{colors.amber}@9%"
    rounded: "{rounded.card}"
---

# Design System: Shepherd

## Overview

**Creative North Star: "The Calm Herd"**

Shepherd is a shepherd's watch over a herd of AI coding agents: a single glance at the menu bar answers "does anything need me?", and the panel turns that glance into one or two decisive actions. The design language is a clean native macOS utility — quiet, warm, and honest — built on one amber accent and a herd of small status lights. Visual authority comes from the platform itself: system materials, SF Symbols, and adaptive colors that respect both appearances, with AA-tuned contrast as a hard floor rather than a hope.

The interface earns the glance. The menu bar is the attention signal (worst-state wins, rendered as a fixed system color so it reads on any bar); the panel is a dense but calm triage desk where the colour IS the state — a status rail, a status dot, and a state pill all speak the same one-color-per-state vocabulary. Nothing pulses, spins, or animates: inside a `MenuBarExtra` window, continuous motion is a known cause of the panel flickering open and closed, so emphasis is static and calm.

Density is deliberate. Rows are compact (64pt base), the panel is a fixed 500pt, and every line of type earns its place. The voice is domain-native and honest: exact dwell figures, "estimate, not a bill", "Needs you" instead of marketing. The system never fabricates state — degraded is shown as degraded, with a reason.

**Key Characteristics:**
- One warm amber accent; status colors are information, not decoration
- Calm static emphasis — no continuous animations anywhere
- WCAG AA (≥4.5:1) for every text color in both light and dark appearances
- Native macOS materials, controls, and SF Symbols throughout
- A single status-light vocabulary running menu bar → rail → pill → dot

## Colors

The palette is deliberately two-layered: an adaptive body layer that resolves per-appearance (light variants darkened, dark variants brightened so every text use holds ≥4.5:1), and a fixed menu-bar layer that uses system colors because the badge is baked into an NSImage at paint time.

### Primary
- **Warm Amber** (#8A5A00 light / #FFC94D dark): The single accent. Cost figures, the flock mark, selection strokes, and the usage-card fill. Body-text-safe in light mode; never used as a flat decorative pour.

### Tertiary
- **Amber Deep** (#6B4500 / #F5B24A): A quieter amber for accents that don't carry text.

### Neutral
- **Secondary Text** (#5A5F64 light / #B3B8BD dark): The one grey vocabulary — location lines, subtitles, dwell figures, search placeholder. Replaces system `.secondary`/`.tertiary`, which drop to ~3.5:1 / ~2.2:1 in light mode on small text.

### Status (the herd lights)
- **Blocked Red** (#B3261E / #FF6B6B): needs you NOW — blocked or process-gone.
- **Silent Amber** (#8A5A00 / #FFC94D): waiting quietly past its threshold.
- **Done Blue** (#1E4BD2 / #6CA6FF): finished work.
- **Working Navy** (#1A3A69 / #8BADDC): actively working.
- **Idle Grey** (#5B6B64 / #8FA8A0): alive and idle.
- **Unknown Grey** (#5F666B / #929A9F): state unclassifiable.

### Operational
- **Warning Orange** (#C2410C / #FFA726): operational warnings only — health banner, pending actions, unpriced usage. Distinct from silent-amber and blocked-red.
- **Approve Fill** (#1A3A69 / #102445): the affirmative button fill; dark navy so white label text holds ≥4.5:1 in both appearances.

### Named Rules
**The One Accent Rule.** Amber is the single accent, used sparingly (selection strokes, cost figures, the mark). Status colors carry information; they are not decoration. Two ambers on one row (silent pill + cost) is the documented exception, and they are distinguished by pill fill vs. text.

**The AA Floor Rule.** Every text color holds ≥4.5:1 in both appearances. Pill text uses the strong pill variants (darker light / brighter dark) because the tinted fill pulls the background toward the text colour. If a shade can't hold the floor, darken the light variant and brighten the dark variant — never ship a grey.

**The Fixed Badge Rule.** The menu-bar attention badge uses fixed `NSColor.system*` colors, never adaptive ones: adaptive colors resolve against the wrong appearance (panel vs bar). Red/amber/blue reads on every bar appearance.

## Typography

**Display Font:** SF Pro Rounded (system)
**Body Font:** SF Pro (system)
**Label/Mono Font:** SF Mono (system)

**Character:** Pure system type — no custom faces. The personality comes from weight and role: bold rounded for the big numbers, semibold for titles, medium for body, and monospaced for anything measured (dwell, cost, params, paths). Rounded design is reserved for display moments and section headers; it signals "this is the number" or "this is the section" without decoration.

### Hierarchy
- **Display** (700, 22pt, ~1.2): The one big number — overall cost in the usage card. Rounded design.
- **Title** (700, 15pt, ~1.2): Panel and dashboard titles ("Shepherd", "Usage & cost").
- **Body** (500, 12.5pt, ~1.35): Agent titles, reasons, action summaries. 13.5pt semibold for the agent name line.
- **Label** (600, 10.5pt, ~1.3): Data labels, section titles (with 0.4–0.7pt tracking), pills (uppercased, 0.4 tracking).
- **Mono** (500, 10.5–11.5pt, ~1.3): Dwell figures, cost lines, params, socket paths, terminal peek.

### Named Rules
**The Measured-Data Rule.** Anything measured is monospaced: dwell durations, token costs, params, paths. If a number could be read as a figure, it gets SF Mono. The one exception is the display cost figure, which is SF Pro Rounded bold and is a *statement*, not a measurement.

## Layout

The panel is a fixed 500pt-wide menu-bar window whose height is content-driven: the header, filter bar, optional pending-actions strip, and footer stack naturally, and the agent list is the only flexible piece — it carries an explicit height (measured content, capped at 540pt) so a short list shrinks the panel and a long one scrolls. The usage dashboard is 500pt wide and capped to the screen height (max 620pt); its inner ScrollView absorbs the difference.

Spacing rhythm: a 14pt gutter frames every section; rows use 10pt vertical padding with 4pt line spacing; section separation is 9–12pt; group headers sit 9pt above, 5pt below their content. Groups are separated more generously (33pt headers) than rows within a group (3pt). The filter bar groups scope + search tightly (9pt between them) inside a 10pt vertical padding.

## Elevation & Depth

This system is flat by design — no drop shadows, no card floats. Depth is conveyed through **tonal layering**: `Color.primary.opacity()` fills (0.025 resting cards, 0.05–0.06 hover, 0.08 active-tinted, 0.14 pill fills) sit on a `regularMaterial` background with a faint top-down gradient. The one sanctioned glow is reserved for the status rail and status dot: a soft colored halo (1.5–5pt blur, 0.25–0.9 opacity) that brightens when an agent is working or alarmed. The menu-bar badge gets no shadow — it is a flat painted image.

### Named Rules
**The Flat-By-Default Rule.** Surfaces are flat at rest. The only shadows in the system are the status glows, and they appear as a *response to state* (working/alarmed), not as ambient furniture.

## Shapes

Continuous rounded rectangles everywhere: 10pt cards (agent rows, usage cards), 7pt fields (search, buttons), 6pt peek boxes. Pills are capsules (999:1) with a 0.5pt hairline stroke at 28% accent opacity. The status rail is a 3.5pt-wide capsule; the status dot is an 8pt filled circle with a 11pt ring when active. Icon buttons are 30pt circles with a 6% primary fill. Everything is continuous — no sharp corners, no mixed radii.

## Components

### Buttons
- **Shape:** rounded rectangles (7pt radius), regular control size.
- **Approve / affirmative:** bordered-prominent with the Approve Fill navy (#1A3A69 / #102445); white label holds AA in both appearances.
- **Destructive / deny:** bordered-prominent tinted blocked red, or `role: .destructive` for the system treatment.
- **Secondary:** bordered style with default label color; used for Peek / Jump / Nudge / Retry / Cancel.
- **Icon buttons:** 30pt borderless circles (6% primary fill) with SF Symbols and `.help()` tooltips — the panel header (usage, resync) and dashboard header (back, refresh).
- **Hover / Focus:** standard system hover; keyboard shortcuts (⌘U, ⌘R) are on the two panel header icons.

### Pills (state chips)
- **Style:** uppercased 10.5pt semibold, 0.4pt tracking, 7pt horizontal / 2.5pt vertical padding, capsule fill at 14% status accent, 0.5pt hairline at 28%.
- **Text color:** the strong pill variant (pill-blocked / pill-silent / …) so it holds ≥4.5:1 on the tinted fill.
- **State:** one pill per agent, always visible; the pill, rail, and dot all share the same status color.

### Cards / Containers
- **Agent row:** 10pt continuous corner, 2.5% primary fill resting (6% hover), 1pt border at 14% accent (hover 40%, selected: amber at 85%, 1.25pt). 64pt base height; grows for reason lines, usage, and the selected action row.
- **Usage card:** 10pt corner, 9% amber fill, 1pt amber border at 25%.
- **Corner Style:** continuous; **Border:** accent-tinted hairline; **Internal Padding:** 12pt.

### Inputs / Fields
- **Search field:** 7pt continuous corner, 5% primary fill, 1pt border (10% primary resting, amber when focused). Custom AA-safe placeholder (the system placeholder drops to ~4.3:1 in dark mode).
- **Focus:** amber border + standard focus behavior; **Error:** red banner row with Retry.

### Navigation
The panel is a single window with three scope segments (Needs you / Running / All — segmented picker, large control size), workspace group headers that collapse/expand, and a three-level New Agent menu (kind → workspace → new tab / split). The usage dashboard is a pushed sub-surface with a back chevron. There is no custom navigation chrome — it is a menu-bar utility, and the keyboard is the navigation: Esc unwinds, arrows move selection, Space peeks, Return jumps, ⌘U/⌘R for usage/resync.

### Signature Component: The Status Rail
The left rail of every agent row is a 3.5pt capsule in the agent's status color, glowing softly when working/alarmed. The colour IS the state — the rail, the dot, and the pill all speak the same vocabulary, so a fluent user reads the herd's health as a field of coloured rails without reading a single word.

## Do's and Don'ts

### Do:
- **Do** use the `Brand.*` token layer for every color — never raw hex in views; the tokens encode the AA floor and both appearances.
- **Do** keep one status-light vocabulary: the same color means the same thing in the menu bar, rail, dot, and pill.
- **Do** use system materials, controls, and SF Symbols; this is a native macOS utility, not a web page.
- **Do** keep all measured data in SF Mono (dwell, cost, params, paths).
- **Do** use the amber accent sparingly — selection strokes, cost figures, the mark. Rarity is the point.

### Don't:
- **Don't** ship system `.green`, `.orange`, `.secondary`, or `.tertiary` for text — they fail AA in light mode; use `approveFill`, `warn`, `secondaryText` instead.
- **Don't** mix icon sets or use unicode glyphs (⋯) where an SF Symbol exists; one symbol family, one stroke.
- **Don't** add continuous animation inside the `MenuBarExtra` window — it is a known cause of the panel flickering open and closed; emphasis is static.
- **Don't** ever fabricate state: degraded is shown as degraded with a reason; the menu bar shows a steady indicator, never a flapping per-attempt counter.
- **Don't** invent new greys — one secondary-text token, one vocabulary.