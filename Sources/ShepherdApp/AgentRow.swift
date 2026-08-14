import SwiftUI
import AppKit
import HerdrManagerCore

/// What (if anything) is expanded under the currently-selected row. Owned by
/// `PanelView` (only one row is ever selected/expanded at a time) and passed
/// down so `AgentRow` stays a presentation layer plus action wiring.
enum RowExpansion: Equatable {
    case none
    case peekLoading
    case peek(String)
    case peekFailed(String)
    case nudge
    case closeConfirm
}

/// Bounds for the free-text nudge field. A terminal pane is not a text area:
/// an unbounded paste would flood the agent's input with megabytes of junk.
/// The cap is generous for real prompts, tight enough to stop accidents.
enum NudgeLimits {
    static let maxLength = 2000
}

/// How long an agent that wants something has been waiting, quantised to the
/// three levels the row actually draws differently.
///
/// This is deliberately a coarse bucket rather than an elapsed time, because
/// it has to survive `AgentRow`'s `Equatable` conformance. Rows are wrapped in
/// `.equatable()` so a thirty-agent herd doesn't re-render wholesale on every
/// herdr event, which means a row only redraws when some *value* it was
/// constructed with changes. A raw elapsed time can't be that value — it
/// changes on every tick — and a property computed inside `==` can't either,
/// since both sides would evaluate it at comparison time and always agree.
/// Quantising, and capturing the result when the row is built, gives a value
/// that is stable across an agent's whole wait apart from the two crossings.
///
/// That is a property of this type alone, not of the row: `AgentRow.==` also
/// compares the rendered dwell *string*, so a waiting row still redraws each
/// time its printed figure ticks over. The bucket's job is to make sure the
/// crossings themselves are never the thing that gets missed.
enum DwellBucket: Equatable {
    case calm     // not waiting, or not waiting long
    case notice   // past the first threshold
    case alarm    // waiting long enough to lead the eye

    /// Thresholds sit either side of the silence thresholds the user can
    /// already configure, so the hardening is a cue they've had time to build
    /// an intuition for rather than a fourth independent notion of "late".
    private static let noticeSeconds: TimeInterval = 5 * 60
    private static let alarmSeconds: TimeInterval = 15 * 60

    /// Bucket an agent by how long it has been blocked.
    ///
    /// Blocked is the only state that qualifies, and the restriction is the
    /// whole design rather than an omission. This emphasis decorates the row's
    /// dwell figure, which is `now - enteredAt`: time in the current herdr
    /// status. Weight and colour applied to a number must be derived from
    /// *that* number, or the row is shouting for a reason it isn't showing.
    /// Only for a blocked pane are the two the same quantity — it entered the
    /// blocked status at the moment it started waiting.
    ///
    /// The two states this rejects are both cases where they come apart:
    ///
    /// - **Silent** panes are still `working` as far as herdr is concerned
    ///   (`Diagnoser.checkSilent` gates on it), so the dwell column shows time
    ///   spent working — typically hours. Timing the emphasis from the
    ///   silence's own `since` would print a bold red "3h0m" to mean "quiet
    ///   for twenty minutes".
    /// - **Process-gone** panes carry no timestamp of death at all, so
    ///   `enteredAt` is time spent working before dying. A pane that died one
    ///   second ago after three hours of work would render at full alarm while
    ///   one that died after two minutes stayed calm — emphasis in inverse
    ///   proportion to how fresh the news is.
    ///
    /// Neither loses anything: both already carry a coloured reason line
    /// printing their own honest duration, on top of a rail, glyph, and pill.
    static func current(for agent: Agent, now: Date = Date()) -> DwellBucket {
        // Process-gone is checked as well as the status, not instead of it:
        // `Diagnoser.checkProcessGone` runs on blocked panes too, so a pane
        // that died at its prompt keeps `status == .blocked` while every other
        // encoding in the row has already switched to "gone". Without this the
        // row would escalate a dead pane's dwell figure as an unanswered wait.
        guard agent.status == .blocked, !agent.verdict.isProcessGone else { return .calm }
        let waited = now.timeIntervalSince(agent.enteredAt)
        if waited >= alarmSeconds { return .alarm }
        if waited >= noticeSeconds { return .notice }
        return .calm
    }
}

/// What one tile's cost chip prints. Four states, none of them a
/// fabricated `$0.00`. Kept next to `DwellBucket` because it is the same
/// kind of value: a presentation reading captured from data the row
/// already holds, not a new stored input `AgentRow.==` would have to see.
private struct CostFace {
    let text: String
    let symbol: String?
    let color: Color
    let help: String
    let spoken: String
}

struct AgentRow: View, Equatable {
    @Environment(AppModel.self) private var appModel
    let agent: Agent
    let dailyCost: TokenMeterSummary
    let isSelected: Bool
    let expansion: RowExpansion
    let writeInFlight: Bool
    /// The rendered dwell figure and its urgency, both captured by `PanelView`
    /// from the panel's clock when the row is built — see `DwellBucket` for
    /// why they cannot be derived here.
    let dwellText: String
    let dwellBucket: DwellBucket
    /// The nudge draft as a value, captured when the row is built.
    ///
    /// A `@Binding` cannot do this job: `==` would read both sides'
    /// `wrappedValue` out of the same storage, so they would always agree and
    /// the row would never redraw while you type — precisely the trap
    /// `DwellBucket` documents. The binding still drives the text field, which
    /// writes through it; this captured copy drives everything *derived* from
    /// the draft, including the equality that lets any of it update at all.
    let nudgeDraft: String
    @Binding var nudgeText: String

    let onSelect: () -> Void
    let onJump: () -> Void
    let onPeekToggle: () -> Void
    let onNudgeOpen: () -> Void
    let onNudgeSubmit: () -> Void
    let onCloseRequest: () -> Void
    let onCloseConfirm: () -> Void
    let onCancelExpansion: () -> Void

    @State private var isHovering = false

    nonisolated static func == (lhs: AgentRow, rhs: AgentRow) -> Bool {
        lhs.agent == rhs.agent
            && lhs.dailyCost == rhs.dailyCost
            && lhs.isSelected == rhs.isSelected
            && lhs.writeInFlight == rhs.writeInFlight
            && lhs.dwellText == rhs.dwellText
            && lhs.dwellBucket == rhs.dwellBucket
            // The nudge draft is compared only for the selected row, alongside
            // its expansion and for the same reason: every row is handed the
            // same draft, so comparing it unconditionally would re-render the
            // whole herd on every keystroke. Comparing it *somewhere* is not
            // optional though — the character counter and the Send button's
            // enabled state are derived from it, and a row that never redraws
            // while you type leaves both showing the state before the first
            // character.
            && (lhs.isSelected
                ? lhs.expansion == rhs.expansion && lhs.nudgeDraft == rhs.nudgeDraft
                : true)
    }

    private var kindLabel: String { agent.kind.label }

    /// The agent's own name when herdr gives it one; the row falls back to the
    /// kind so a nameless pane never renders a blank title.
    private var titleText: String {
        let name = agent.displayName.isEmpty ? agent.name : agent.displayName
        return name.isEmpty ? kindLabel : name
    }

    private var cwdBase: String {
        let c = agent.cwd
        guard !c.isEmpty else { return "" }
        return c.split(separator: "/").last.map(String.init) ?? c
    }

    private var locationLine: String {
        var parts: [String] = []
        // Keep the kind visible when the title is a terminal title rather than
        // the agent kind itself — the title line can't be the only place it lives.
        if titleText.lowercased() != kindLabel { parts.append(kindLabel) }
        if !agent.workspaceName.isEmpty { parts.append(agent.workspaceName) }
        if !agent.tabName.isEmpty { parts.append(agent.tabName) }
        if !cwdBase.isEmpty { parts.append("~\(cwdBase)") }
        return parts.joined(separator: " · ")
    }

    /// A waiting agent's dwell figure earns emphasis as the wait grows: a
    /// prompt left unanswered for 40 minutes should not read like one left for
    /// 20 seconds. The escalation is weight *and* colour, never colour alone —
    /// the hardening from grey to bold state-colour is legible in greyscale,
    /// so this reinforces the attention hierarchy instead of adding another
    /// hue-only channel to it.
    private func dwellEmphasis(face: Brand.StateFace) -> (color: Color, weight: Font.Weight) {
        switch dwellBucket {
        case .calm: return (Brand.secondaryText, .medium)
        case .notice: return (face.color, .semibold)
        case .alarm: return (face.color, .bold)
        }
    }

    private var reasonColor: Color {
        switch agent.verdict.reasonTone {
        case .danger: return Brand.blocked
        case .warn: return Brand.silent
        case .info: return Brand.done
        case .neutral: return Brand.secondaryText
        }
    }

    /// Takes the state and dwell figure the row is actually rendering rather
    /// than re-deriving them, so the sighted and spoken versions of a row
    /// always quote the same state and the same number. Cost is always
    /// spoken, including the two unknown cases: fabricating silence here
    /// would make VoiceOver less honest than the chip.
    private func accessibilityDescription(face: Brand.StateFace, dwell: String) -> String {
        let reason = agent.verdict.reasonText ?? "no issues"
        return "\(titleText), \(kindLabel), \(face.word), \(dwell), \(costFace.spoken), \(reason)"
    }

    /// The four honest readings of today's cost. Unknown is unknown: a
    /// missing price is never printed as `$0.00`, and an agent with no local
    /// log is told apart from one that spent nothing. Each case carries a
    /// word, a colour, and (where it is a warning) a glyph, so none of them
    /// is hue-only. Derived from `dailyCost`, which `==` already compares —
    /// this is not a stored property, and must not become one, or it would
    /// have to be listed in `==` for a value the row already sees change.
    private var costFace: CostFace {
        let estimateHelp = "API list-price estimate, not a bill. Shepherd prices local CLI session logs at configured rates."
        if !dailyCost.hasUsage {
            return CostFace(
                text: "no local log",
                symbol: nil,
                color: Brand.secondaryText,
                help: "No local log. Shepherd only reads local CLI session logs, and cannot see this agent's tokens.",
                spoken: "no local log"
            )
        }
        if dailyCost.costUSD == nil {
            return CostFace(
                text: "price missing",
                symbol: "exclamationmark.triangle.fill",
                color: Brand.warn,
                help: estimateHelp,
                spoken: "price missing"
            )
        }
        // `UsageFormatter.cost` already appends "partial" when some models
        // are unpriced; that is the same plain-word incomplete marker the
        // usage dashboard uses, so the chip does not invent a second one.
        let figure = UsageFormatter.cost(dailyCost)
        if dailyCost.hasUnpricedUsage {
            return CostFace(
                text: "\(figure) today incomplete",
                symbol: "exclamationmark.triangle.fill",
                color: Brand.warn,
                help: estimateHelp,
                spoken: "today \(figure) API equivalent, incomplete"
            )
        }
        return CostFace(
            text: "\(figure) today",
            symbol: "chart.line.uptrend.xyaxis",
            color: Brand.amber,
            help: estimateHelp,
            spoken: "today \(figure) API equivalent"
        )
    }

    /// The state as a tinted chip rather than plain grey text — at a glance the
    /// state reads from the same colour as the row's rail and status glyph, and
    /// spells the word out for anyone the colour doesn't reach. Text uses the
    /// strong variant so it holds ≥4.5:1 on the tinted fill.
    private func statePill(face: Brand.StateFace) -> some View {
        Text(face.word)
            .font(.system(size: 10.5, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.4)
            .foregroundStyle(face.strong)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(face.color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(face.color.opacity(0.28), lineWidth: 0.5))
            .fixedSize()
    }

    var body: some View {
        // One resolution of the state for the whole row: rail, glyph, pill,
        // dwell emphasis, and spoken label all read from it, so none of them
        // can describe a different state than its neighbour.
        let face = Brand.face(for: agent)
        let accent = face.color
        let active = (agent.status == .working || agent.status == .blocked)
        let alarmed = (agent.status == .blocked || agent.verdict.isProcessGone)
        let dwell = dwellEmphasis(face: face)

        HStack(alignment: .top, spacing: 0) {
            // Left status rail — the colour IS the state, glowing when active.
            Capsule()
                .fill(accent)
                .frame(width: 3.5)
                .padding(.vertical, 8)
                .shadow(color: accent.opacity(alarmed || active ? 0.75 : 0.25),
                        radius: alarmed ? 5 : (active ? 3 : 1.5))
                .padding(.trailing, 11)

            VStack(alignment: .leading, spacing: 4) {
                // Line 1: name/kind (left) + state pill and dwell (right).
                HStack(spacing: 7) {
                    StatusGlyph(face: face, active: active)
                    Text(titleText)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(titleText)
                        // The row container already speaks title, state, dwell
                        // and cost as one summary; repeating each fragment as
                        // its own VoiceOver stop would make thirty tiles
                        // unnavigable. Buttons stay exposed — see `.contain`.
                        .accessibilityHidden(true)
                    Spacer(minLength: 8)
                    statePill(face: face)
                        .accessibilityHidden(true)
                    Text(dwellText)
                        .font(.system(size: 11.5, weight: dwell.weight, design: .monospaced))
                        .foregroundStyle(dwell.color)
                        .accessibilityHidden(true)
                        // Says what the figure measures without naming a state
                        // that would contradict the rest of the row. This is
                        // time in herdr's *status*, which for a silent or gone
                        // pane is still `working` — so spelling that status out
                        // would print "In working" beside a pill reading GONE,
                        // an xmark glyph, and a reason line about a dead
                        // process. The duration those encodings refer to is the
                        // one the reason line already prints.
                        //
                        // Joined with a separator rather than "for", because
                        // the formatter's word for a brand-new agent is "now",
                        // and "…for now" is not the sentence it looks like.
                        .help("Time in herdr's current status · \(dwellText)")
                }

                // Line 2: what it's waiting on — the triage payload leads, so
                // the eye lands on *why* before *where*.
                if let reason = agent.verdict.reasonText {
                    Text(reason)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(reasonColor)
                        .lineLimit(2)
                        .help(reason)
                        .accessibilityHidden(true)
                }

                // Line 3: workspace · tab · ~cwd-basename.
                if !locationLine.isEmpty {
                    Text(locationLine)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Brand.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(locationLine)
                        .accessibilityHidden(true)
                }

                // Line 4: cost chip (every tile, so the figures form a
                // column) and the always-visible Peek / Jump / Nudge cluster.
                // One cluster only — selected rows do not redraw these three.
                HStack(alignment: .center, spacing: 8) {
                    costChip
                    Spacer(minLength: 8)
                    primaryActionCluster
                }

                if isSelected {
                    selectedActionRow
                    expansionView
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.trailing, 12)
        }
        .padding(.leading, 8)
        .background(cardBackground(accent: accent, active: active || alarmed))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? Brand.amber.opacity(0.85)
                        : accent.opacity(isHovering ? 0.4 : 0.14),
                    lineWidth: isSelected ? 1.25 : 1
                )
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering in isHovering = hovering }
        .background(ClickCatcher(onSelect: onSelect, onDoubleClick: onJump))
        // `.contain` (not `.combine`): Peek / Jump / Nudge now live on every
        // tile, and flattening the row into one element would swallow them.
        // The container still speaks the summary; each button stays its own
        // reachable, labelled control. `.isButton` is deliberately omitted —
        // a group that is also a button is a VoiceOver trap that hides
        // children. Select remains an explicit `accessibilityAction`.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription(face: face, dwell: dwellText))
        .accessibilityHint("Double-click to jump to this agent")
        .accessibilityAction { onSelect() }
        .contextMenu {
            Button("Override: 5 min") { appModel.setThresholdOverride(for: agent, minutes: 5) }
            Button("Override: 10 min") { appModel.setThresholdOverride(for: agent, minutes: 10) }
            Button("Override: 15 min") { appModel.setThresholdOverride(for: agent, minutes: 15) }
            Button("Override: 30 min") { appModel.setThresholdOverride(for: agent, minutes: 30) }
            Divider()
            Button("Reset to Default") { appModel.resetThresholdOverride(for: agent) }
        }
    }

    // MARK: - Cost chip (every tile)

    private var costChip: some View {
        let face = costFace
        return HStack(spacing: 4) {
            if let symbol = face.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(face.text)
                .lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(face.color)
        .help(face.help)
        .accessibilityHidden(true)
    }

    // MARK: - Primary actions (every tile)

    /// Peek / Jump / Nudge, always. Resting emphasis is quiet so thirty
    /// copies do not drown the status signal; hover and selection lift the
    /// labels to primary without dropping the resting state below AA —
    /// `Brand.secondaryText` is already the AA-safe grey, and opacity is
    /// not reduced on top of it. These sit in the content tree above
    /// `ClickCatcher`, so their mouse-downs should hit the buttons, not
    /// the row: a Peek click must not also select-via-catcher, and a
    /// double-click on Peek must not jump.
    private var primaryActionCluster: some View {
        let live = isHovering || isSelected
        let rest = live ? Color.primary : Brand.secondaryText
        return HStack(spacing: 5) {
            Button { onPeekToggle() } label: {
                Label("Peek", systemImage: "eye")
                    .foregroundStyle(rest)
            }
            .help("Show the last 20 lines of this pane")

            Button { onJump() } label: {
                Label("Jump", systemImage: "arrow.right.to.line")
                    // Dimmed by hand while a write is in flight: an explicit
                    // `foregroundStyle` wins over the button style's own
                    // disabled treatment, so without this Jump would look
                    // live while refusing every click. Same trap as Deny.
                    .foregroundStyle(writeInFlight ? Brand.secondaryText.opacity(0.4) : rest)
            }
            .disabled(writeInFlight)
            .help("Focus this agent's workspace and pane")

            Button { onNudgeOpen() } label: {
                Label("Nudge", systemImage: "bubble.left")
                    .foregroundStyle(writeInFlight ? Brand.secondaryText.opacity(0.4) : rest)
            }
            .disabled(writeInFlight)
            .help("Send a message to this agent")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.system(size: 11, weight: live ? .semibold : .medium))
        .fixedSize()
    }

    // MARK: - Selected-only actions (Approve / Deny / overflow)

    @ViewBuilder
    private var selectedActionRow: some View {
        HStack(spacing: 7) {
            if agent.verdict.isAwaitingInput {
                // Approve and Deny used to be two filled buttons that differed
                // only in hue — green beside red, the exact pair the most
                // common colour deficiency collapses, and the pair that decides
                // whether the user is accepting or rejecting an agent's
                // request. They now differ three ways at once: a checkmark
                // against a cross, a filled button against an outlined one, and
                // only then the colour. Weight also encodes intent, the way
                // macOS alerts do — the affirmative action is the prominent
                // one, so nothing else has to be read to find the default.
                Button { appModel.approve(agent) } label: {
                    Label("Approve", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.approveFill)
                .disabled(writeInFlight)
                .help("Sends Enter to accept the highlighted option")

                Button { appModel.deny(agent) } label: {
                    // `pillBlocked`, not `blocked`: this red is label text on a
                    // filled control rather than on the panel material, and the
                    // body variant lands under 4.5:1 against a dark-mode bezel.
                    // That is the case the strong pill variants exist for.
                    //
                    // Dimmed by hand while a write is in flight: an explicit
                    // `foregroundStyle` wins over the button style's own
                    // disabled treatment, so without this the button would look
                    // live while refusing every click.
                    Label("Deny", systemImage: "xmark")
                        .foregroundStyle(Brand.pillBlocked.opacity(writeInFlight ? 0.4 : 1))
                }
                .buttonStyle(.bordered)
                .disabled(writeInFlight)
                .help("Sends Esc to dismiss the prompt")
            }
            Spacer(minLength: 0)
            Menu {
                Button("Close agent", role: .destructive) { onCloseRequest() }
                    .disabled(writeInFlight)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityLabel("More actions")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .controlSize(.regular)
        .font(.system(size: 12))
        .padding(.top, 6)
    }

    // MARK: - Expansion (peek / nudge / close-confirm), selected row only

    @ViewBuilder
    private var expansionView: some View {
        switch expansion {
        case .none:
            EmptyView()
        case .peekLoading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading…").font(.system(size: 11.5)).foregroundStyle(Brand.secondaryText)
            }
            .padding(.top, 4)
        case .peek(let content):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(content, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Copy the peeked output")
                }
                ScrollView {
                    Text(content)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                // Body cap is the single source of truth for the peek-height
                // budget (`PanelLayout.peekHeight`); keep the two in sync via
                // `PanelLayout.peekBodyHeight`.
                .frame(maxHeight: PanelLayout.peekBodyHeight)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(.top, 4)
        case .peekFailed(let error):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.warn)
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Brand.warn)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button("Retry") { onPeekToggle() }
                    .controlSize(.regular)
                    .help("Retry the peek")
            }
            .padding(.top, 4)
        case .nudge:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TextField("Send a message…", text: $nudgeText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onChange(of: nudgeText) { _, newValue in
                            if newValue.count > NudgeLimits.maxLength {
                                nudgeText = String(newValue.prefix(NudgeLimits.maxLength))
                            }
                        }
                        .onSubmit { onNudgeSubmit() }
                        .onExitCommand { onCancelExpansion() }
                    // Both of these read the captured draft, not the binding:
                    // they are what the row *derives* from the text, and the
                    // captured copy is the one the row's equality can see
                    // change. Reading the binding here would render correctly
                    // only on the passes something else already forced.
                    Button("Send") { onNudgeSubmit() }
                        .controlSize(.regular)
                        .disabled(nudgeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !nudgeDraft.isEmpty {
                    Text("\(nudgeDraft.count)/\(NudgeLimits.maxLength)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Brand.secondaryText)
                        .monospacedDigit()
                }
            }
            .padding(.top, 4)
        case .closeConfirm:
            HStack(spacing: 8) {
                Text("Close agent?")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.blocked)
                Spacer(minLength: 0)
                Button("Cancel") { onCancelExpansion() }
                    .controlSize(.regular)
                Button("Close", role: .destructive) { onCloseConfirm() }
                    .controlSize(.regular)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Card background

    private func cardBackground(accent: Color, active: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0.025))
            if active {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.08))
            }
        }
    }
}

/// A status light that says what it means. This was a plain coloured dot,
/// which made the row's state readable only to someone who can separate the
/// six status hues — the one accessibility debt `PRODUCT.md` calls out by
/// name. Carrying the state's glyph inside the light costs the same 16 pt and
/// removes the dependency on colour entirely: the herd reads correctly in
/// greyscale, in a screenshot, and to a colour-blind user.
///
/// Active agents (working/blocked) get a firmer ring and a brighter glow
/// instead of a repeating animation — continuous animations inside a
/// `MenuBarExtra` window are a known cause of the panel flickering open and
/// closed, so emphasis here is purely static.
private struct StatusGlyph: View {
    /// The resolved state. `face.color` fills and rings the chip; the glyph
    /// itself draws in `face.strong`, because it sits on a tint of its own hue
    /// and that pulls the background toward it — the same problem the state
    /// pill has, with the same answer. This is the row's primary colour-free
    /// signal; it cannot be the lowest-contrast thing in the row.
    let face: Brand.StateFace
    let active: Bool

    /// Sized to the 13.5 pt title it sits beside, so the row's first line has
    /// one optical baseline rather than a small dot floating in a tall slot.
    private let side: CGFloat = 16

    var body: some View {
        ZStack {
            // 0.14 — the same tint the state pill fills with, deliberately.
            // `face.strong` was calibrated to hold ≥4.5:1 against exactly this
            // fill, so a denser one here would put the row's primary
            // colour-free signal below the contrast the rest of the palette is
            // validated at.
            Circle()
                .fill(face.color.opacity(0.14))
            Circle()
                .strokeBorder(face.color.opacity(active ? 0.9 : 0.55), lineWidth: 1)
            Image(systemName: face.symbol)
                // Heavy at this size on purpose: a hairline glyph inside a
                // 16 pt chip disappears against the tinted fill.
                .font(.system(size: 7.5, weight: .black))
                .foregroundStyle(face.strong)
        }
        .frame(width: side, height: side)
        .shadow(color: face.color.opacity(active ? 0.45 : 0), radius: active ? 2.5 : 0)
        // The row's combined accessibility label already names the state; the
        // chip repeating it would make VoiceOver say it twice.
        .accessibilityHidden(true)
    }
}

/// Native click handling for a row. SwiftUI's paired `onTapGesture` +
/// `onTapGesture(count: 2)` disambiguates the two by withholding the single
/// tap until the double-click window closes — selection then *feels* laggy
/// even though it is only ~0.3s late. Routing clicks through an `NSView`
/// reproduces the platform behavior exactly: click selects immediately,
/// double-click jumps. The transparent view sits behind the row content, so
/// buttons, text fields, and scroll views above it still receive their own
/// events; right-clicks fall through to the SwiftUI context menu untouched.
private struct ClickCatcher: NSViewRepresentable {
    let onSelect: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onSelect = onSelect
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onSelect = onSelect
        nsView.onDoubleClick = onDoubleClick
    }

    final class CatcherView: NSView {
        var onSelect: () -> Void = {}
        var onDoubleClick: () -> Void = {}

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                onDoubleClick()
            } else {
                onSelect()
            }
        }
    }
}
