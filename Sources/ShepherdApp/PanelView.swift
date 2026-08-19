import SwiftUI
import AppKit
import HerdrManagerCore

struct PanelView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    /// Whether the panel's window is the active one — the signal the dwell
    /// clock throttles against. See `idleClockInterval`.
    @Environment(\.controlActiveState) private var controlActiveState

    /// What the selected row is currently expanded to show (peek / nudge /
    /// close-confirm). Only one row is ever selected, so one flat piece of
    /// state here (rather than per-row @State) is enough and makes Esc/Space
    /// keyboard handling trivial.
    @State private var expansion: RowExpansion = .none
    @State private var nudgeText: String = ""

    /// Free-text filter over the visible list. With ~30 agents the panel is a
    /// haystack; typing narrows it without changing the triage scope.
    @State private var searchText: String = ""
    @FocusState private var searchFocused: Bool

    /// Workspace groups the user has folded away (All scope only).
    @State private var collapsedGroups: Set<String> = []
    @State private var showUsageDashboard = false
    /// On-demand setup checks (⌘⇧S). Disconnected already shows the checklist
    /// as the empty state; this flag opens it while connected too.
    @State private var showSetupChecks = false

    /// The clock the panel's durations are read against, advanced on a timer
    /// rather than read at render time.
    ///
    /// Every observable setter in `AppModel` is change-guarded — `AgentStore`
    /// only publishes when the snapshot actually differs — which is correct,
    /// and means a herd where nothing is happening produces no redraws at all.
    /// That is exactly the herd whose durations most need to keep moving: a
    /// pane blocked twenty minutes ago emits no events precisely *because* it
    /// is stuck. Without a tick of its own the panel would sit showing the
    /// figure it was opened with.
    @State private var now = Date()

    /// How often the clock advances while the panel is on screen. Small steps
    /// keep a young agent's seconds figure moving at something like the rate
    /// it is actually counting — "exact dwell figures" is a stated brand
    /// commitment, and a coarse tick leaves the panel's own numbers visibly
    /// behind. Cheap regardless: rows whose rendered figure hasn't changed
    /// compare equal and skip redrawing.
    private static let clockInterval: Duration = .seconds(5)

    /// How often it advances when the panel's window isn't active. A
    /// `MenuBarExtra` window's content view is not reliably torn down on
    /// dismissal, so without this the tick would keep re-rendering a herd
    /// nobody is looking at, giving up the "no events, no redraws" property
    /// the change-guarded store works to provide.
    ///
    /// It slows the clock rather than stopping it, deliberately. A gate that
    /// latched shut — on `onDisappear` without a matching `onAppear`, say —
    /// would freeze every duration in the panel for the rest of the app's
    /// life, which in a product whose second principle is honesty about state
    /// is a real bug and an invisible one. Slowing has no such failure mode:
    /// the worst case is a closed panel whose figures are a minute stale, and
    /// `onAppear` refreshes them the instant it is opened.
    private static let idleClockInterval: Duration = .seconds(60)

    /// Publish a new clock reading, but only if some row would print a
    /// different figure for it.
    ///
    /// `AgentStore` goes out of its way to change-guard its writes so an
    /// unchanged herd produces no redraws — the panel is a `MenuBarExtra`
    /// window, and needless re-rendering is what makes one flicker. A timer
    /// that assigned unconditionally would hand that property straight back:
    /// `now` is read by `visibleHerd`, so every tick would re-filter and
    /// re-sort the herd and re-measure every row, twelve times a minute, to
    /// arrive at the same pixels.
    ///
    /// So the tick asks first. `displayTick` is the integer identity of the
    /// text `DwellFormatter` would produce, so this is one pass of integer
    /// arithmetic that allocates nothing and stops at the first agent whose
    /// figure has moved. The dwell buckets need no separate check: both
    /// thresholds are whole minutes, so a crossing always coincides with that
    /// agent's printed figure changing.
    private func advanceClock() {
        let candidate = Date()
        let moved = appModel.store.agents.values.contains { agent in
            DwellFormatter.displayTick(interval: candidate.timeIntervalSince(agent.enteredAt))
                != DwellFormatter.displayTick(interval: now.timeIntervalSince(agent.enteredAt))
        }
        if moved { now = candidate }
    }

    var body: some View {
        Group {
            if showUsageDashboard {
                UsageDashboardView(onBack: { showUsageDashboard = false })
            } else {
                triagePanel
            }
        }
        // Width is fixed; height is whatever the content adds up to. A
        // `minHeight`/`maxHeight` pair here is actively harmful: the
        // `MenuBarExtra` window resolves such a frame to its *minimum* and then
        // clips the header — which is what kept the old panel at 220pt. The
        // list is the only flexible piece, and it carries an explicit height.
        .frame(width: PanelLayout.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(panelBackground)
        .onKeyPress(.escape) {
            if showUsageDashboard {
                showUsageDashboard = false
                return .handled
            }
            if showSetupChecks && appModel.connectionState == .connected {
                showSetupChecks = false
                return .handled
            }
            if searchFocused {
                searchFocused = false
                return .handled
            }
            if !searchText.isEmpty {
                searchText = ""
                return .handled
            }
            if expansion != .none {
                expansion = .none
                return .handled
            }
            dismiss()
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard triageKeysActive else { return .ignored }
            moveSelection(up: true)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard triageKeysActive else { return .ignored }
            moveSelection(up: false)
            return .handled
        }
        .onKeyPress(.return) {
            guard triageKeysActive else { return .ignored }
            jumpSelected()
            return .handled
        }
        .onKeyPress(" ") {
            guard triageKeysActive else { return .ignored }
            togglePeekSelected()
            return .handled
        }
        // Re-read the clock on open, so a panel reopened after an hour away
        // doesn't show the durations it was closed with — the moment they are
        // most wrong. If this never fires the figures are at worst one tick
        // stale, which the loop below corrects on its own.
        .onAppear { now = Date() }
        .onChange(of: controlActiveState) { _, newValue in
            if newValue == .inactive {
                appModel.dismissFirstSuccessBanner()
            }
        }
        // Keyed on the window's active state rather than on a view-lifecycle
        // callback: `controlActiveState` is driven by AppKit's own window
        // notifications, so it reports the panel closing without depending on
        // `onAppear`/`onDisappear` arriving in matched pairs. The key also
        // restarts the loop on each transition, which is what lets the body
        // below read a current cadence instead of the one captured when the
        // task was first created.
        .task(id: controlActiveState) {
            let interval = controlActiveState == .inactive
                ? Self.idleClockInterval
                : Self.clockInterval
            // Re-read before the first sleep. `onAppear` doesn't re-fire on a
            // panel whose content view was never torn down, so without this a
            // reopened panel would show the figures it was closed with for a
            // whole interval — and this task restarts on exactly the
            // transition that means "the panel just became active".
            now = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                advanceClock()
            }
        }
        .focusable()
        // Keyboard-first: the panel opens with the filter field focused so
        // "type to filter" works immediately; Esc drops to arrow-key triage
        // (the .onKeyPress handlers below already gate on searchFocused).
        .defaultFocus($searchFocused, !showingSetupChecklist)
        // Expansion is reset in `onSelect` and `moveSelection`, not here.
        // Peek / Nudge on an unselected tile select that tile as part of
        // the same explicit action that opens the expansion; an `onChange`
        // wipe would run after that action returns and cancel the peek.
    }

    /// What the current scope actually puts on screen, derived once.
    ///
    /// Filtering the herd — and, in All scope, grouping and sorting it — is
    /// not free, and most of the panel wants some slice of the answer: the
    /// list, the list's height budget, the scope picker's three tab counts,
    /// the header subtitle, the empty states, and the footer's keyboard hint.
    /// Each of those used to derive its own, so a single body pass filtered
    /// and sorted the herd half a dozen times. It now happens once: one pass
    /// to tally the scope counts, and one sort for the scope actually on
    /// screen. On a thirty-agent herd redrawing on every herdr event and every
    /// clock tick, that is the difference worth having.
    private struct VisibleHerd {
        /// Workspace groups, populated in All scope only.
        let groups: [WorkspaceGroup]
        /// The rows on screen, in render order: what the arrow keys walk and
        /// what the height budget sums. Excludes agents inside a collapsed
        /// group, which are not on screen to walk or to measure.
        let rows: [Agent]
        /// Scope tallies for the picker's tab labels and the header subtitle.
        /// Counted, not collected: those two only ever ask "how many", and
        /// building and sorting three lists to call `.count` on them was most
        /// of the panel's per-pass work.
        let needsYou: Int
        let running: Int
        let done: Int
        /// Herd size for the All tab — filtered, like its two siblings. It
        /// used to be the raw store count, which put "All 30" above a
        /// two-row filtered list while the tabs either side of it counted
        /// only matches. A tab count that disagrees with the list under it is
        /// worse than no count.
        let matching: Int
    }

    private var visibleHerd: VisibleHerd {
        var needsYou = 0
        var running = 0
        var done = 0
        var matching = 0
        let query = searchQuery
        for agent in appModel.store.agents.values where matchesSearch(agent, query: query) {
            matching += 1
            if Self.needsYou(agent) { needsYou += 1 }
            if agent.status == .working { running += 1 }
            if agent.status == .done { done += 1 }
        }

        let groups: [WorkspaceGroup]
        let rows: [Agent]
        switch appModel.scope {
        case .needsYou:
            groups = []
            rows = needsYouAgents
        case .running:
            groups = []
            rows = runningAgents
        case .all:
            groups = allGroups
            rows = Self.rows(in: groups, collapsed: collapsedGroups)
        }

        return VisibleHerd(
            groups: groups,
            rows: rows,
            needsYou: needsYou,
            running: running,
            done: done,
            matching: matching
        )
    }

    /// Setup checks replace the herd list when disconnected (or connecting)
    /// and when the user opens them on demand.
    private var showingSetupChecklist: Bool {
        showSetupChecks || appModel.connectionState != .connected
    }

    private var showingMCPCard: Bool {
        appModel.connectionState == .connected
            && appModel.hasEverConnected
            && !appModel.dismissedMCPCard
            && !showSetupChecks
    }

    private var showingFirstSuccess: Bool {
        appModel.showFirstSuccessBanner
            && appModel.connectionState == .connected
            && !showSetupChecks
    }

    /// The triage surface, factored out of `body` so `visibleHerd` can be
    /// computed once and handed to each part that needs it.
    private var triagePanel: some View {
        let herd = visibleHerd
        return VStack(alignment: .leading, spacing: 0) {
            header(herd: herd)
            Divider()
            if !showingSetupChecklist {
                filterBar(herd: herd)
                Divider()
            }
            if !appModel.pendingActions.isEmpty {
                PendingActionsView()
                Divider()
            }
            content(herd: herd)
            Divider()
            if let errorText = appModel.lastError {
                errorBanner(errorText)
            }
            if let health = appModel.adapterHealth, !health.compatible || !health.writesEnabled {
                healthBanner(health)
            }
            footer(herd: herd)
        }
    }

    /// One place to tune the panel's overall geometry. The panel used to be a
    /// 400×560 box with a 400pt scroll area, which put ~2.5 rows on screen at
    /// once; these are the roomier numbers everything else is sized against.
    /// Tokens shared with other surfaces (panel width, peek expansion) live in
    /// `PanelLayout` so the window geometry has exactly one definition.
    private enum Layout {
        static let gutter: CGFloat = 14

        /// List sizing. These are estimates, not measurements: they only decide
        /// how tall the scroll area is, so being a few points off costs at worst
        /// a slightly early scrollbar.
        static let listCeilingHeight: CGFloat = 540
        static let emptyStateHeight: CGFloat = 260
        static let rowBaseHeight: CGFloat = 64
        /// Cost chip on its own row (10.5 pt caption plus the 4 pt stack gap).
        static let rowCostHeight: CGFloat = 18
        /// Peek / Jump / Nudge on a dedicated full-width row. Custom-drawn
        /// chrome is taller than the old cramped `.small` cluster; this
        /// budget is what keeps a short list from clipping them.
        static let rowPrimaryActionsHeight: CGFloat = 40
        static let rowActionsHeight: CGFloat = 40
        static let rowInlineHeight: CGFloat = 36
        static let groupHeaderHeight: CGFloat = 33

        /// Fixed chrome above and below the list: header, filter bar, footer,
        /// the dividers between them, and the list's own vertical padding.
        /// These are estimates; overestimating costs at worst a slightly early
        /// scrollbar, underestimating would clip the footer off-screen.
        static let fixedChromeHeight: CGFloat = 220
        /// One banner row (error / health).
        static let bannerHeight: CGFloat = 28
        /// Pending-actions section header plus one action row.
        static let pendingHeaderHeight: CGFloat = 28
        static let pendingRowHeight: CGFloat = 48
        /// Floor: even on a tiny display the list keeps a few rows visible.
        static let listMinHeight: CGFloat = 180
        /// Margin under the panel so its shadow never collides with the dock.
        static let screenMargin: CGFloat = 20

        /// Text width a reason line can actually use before wrapping: panel
        /// width minus outer padding, leading padding, the status rail, and
        /// the trailing padding the text column carries.
        static let reasonMaxWidth: CGFloat = 440
    }

    /// Memoized wrapped heights for reason lines. The panel measures every
    /// visible agent's reason on every body recompute (each herdr event while
    /// the panel is open), and the text column width is a fixed constant — so
    /// the measurement is a pure function of the string and never needs to run
    /// twice. Bounded: dropped wholesale when it outgrows its cap; a busy herd
    /// generates long-lived reason strings, so the common case is a cache hit.
    private enum ReasonLayout {
        @MainActor
        private static var heights: [String: CGFloat] = [:]

        @MainActor
        static func height(for text: String) -> CGFloat {
            if let cached = heights[text] { return cached }
            let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
            let lineHeight = font.ascender - font.descender + font.leading
            let bounds = (text as NSString).boundingRect(
                with: .init(width: Layout.reasonMaxWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            )
            let lines = min(max(ceil(bounds.height / lineHeight), 1), 2) // matches .lineLimit(2)
            let height = lines * lineHeight
            if heights.count >= 256 {
                heights.removeAll(keepingCapacity: true)
            }
            heights[text] = height
            return height
        }
    }

    // MARK: - Header

    private func header(herd: VisibleHerd) -> some View {
        HStack(spacing: 10) {
            FlockMark(size: 20, glow: appModel.connectionState == .connected)
            VStack(alignment: .leading, spacing: 1) {
                Text("Shepherd")
                    .font(.system(size: 15, weight: .bold))
                Text(headerSubtitle(herd: herd))
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            iconButton(system: "chart.line.uptrend.xyaxis", help: "Usage & cost (⌘U)", label: "Usage & cost", shortcut: "u") {
                showUsageDashboard = true
            }
            iconButton(system: "arrow.clockwise", help: "Resync (⌘R)", label: "Resync", shortcut: "r") {
                appModel.resync()
            }
            iconButton(
                system: "stethoscope",
                help: "Setup checks (⌘⇧S)",
                label: "Setup checks",
                shortcut: "s",
                modifiers: [.command, .shift]
            ) {
                showSetupChecks.toggle()
            }
            Menu {
                Text("keep the herd moving")
                Divider()
                Button("Quit Shepherd") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
        }
        .padding(.horizontal, Layout.gutter)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }

    private func iconButton(
        system: String,
        help: String,
        label: String,
        shortcut: Character,
        modifiers: EventModifiers = .command,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(label)
        .keyboardShortcut(KeyEquivalent(shortcut), modifiers: modifiers)
    }

    // MARK: - Filter bar (scope + search)

    private func filterBar(herd: VisibleHerd) -> some View {
        VStack(spacing: 9) {
            scopePicker(herd: herd)
            searchField
        }
        .padding(.horizontal, Layout.gutter)
        .padding(.vertical, 10)
    }

    private func scopePicker(herd: VisibleHerd) -> some View {
        @Bindable var appModel = appModel
        return Picker("", selection: $appModel.scope) {
            ForEach(TriageScope.allCases, id: \.self) { scope in
                Text("\(scope.label) \(count(for: scope, herd: herd))").tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .labelsHidden()
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Brand.secondaryText)
            // Custom placeholder: the system placeholder colour drops to ~4.3:1
            // in dark mode, so render our own at an adaptive ≥4.5:1 grey.
            ZStack(alignment: .leading) {
                if searchText.isEmpty {
                    Text("Filter by name, kind, workspace…")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.searchPlaceholder)
                        .allowsHitTesting(false)
                }
                TextField("", text: $searchText, prompt: Text(""))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .onSubmit { searchFocused = false }
            }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.secondaryText)
                }
                .buttonStyle(.borderless)
                .help("Clear filter")
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    searchFocused ? Brand.amber : Color.primary.opacity(0.10),
                    lineWidth: 1
                )
        )
    }

    private func count(for scope: TriageScope, herd: VisibleHerd) -> Int {
        switch scope {
        case .needsYou: return herd.needsYou
        case .running: return herd.running
        case .all: return herd.matching
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(herd: VisibleHerd) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3, pinnedViews: [.sectionHeaders]) {
                if showingFirstSuccess {
                    FirstSuccessRow(
                        agentCount: appModel.store.agents.count,
                        onDismiss: { appModel.dismissFirstSuccessBanner() }
                    )
                }
                if showingSetupChecklist {
                    SetupChecklistView(
                        report: appModel.preflightReport,
                        onRecheck: { appModel.resync() }
                    )
                } else if appModel.scope == .all {
                    if herd.groups.isEmpty {
                        emptyStateBody(herd: herd)
                    } else {
                        groupedList(herd.groups)
                    }
                } else if herd.rows.isEmpty {
                    emptyStateBody(herd: herd)
                } else {
                    flatList(herd.rows)
                }
                if showingMCPCard {
                    MCPHookupCard(
                        resolution: MCPBridgePath.resolve(),
                        onDismiss: { appModel.dismissMCPCard() }
                    )
                }
            }
            .padding(.vertical, 6)
        }
        // A ScrollView has no ideal height of its own, so inside the
        // `MenuBarExtra` window it collapses to almost nothing unless it is
        // told how tall to be. `listHeight` measures the content and clamps it,
        // so a short list shrinks the panel and a long one fills it and scrolls.
        .frame(height: listHeight(herd: herd))
        .scrollIndicators(.automatic)
    }

    /// Estimated height of the visible list, capped at the panel's budget.
    /// Collapsed groups still contribute their header, so folding a group
    /// shrinks the panel to fit rather than leaving dead space behind.
    private func listHeight(herd: VisibleHerd) -> CGFloat {
        var extras: CGFloat = 0
        if showingFirstSuccess { extras += FirstSuccessRow.estimatedHeight }
        if showingMCPCard { extras += MCPHookupCard.estimatedHeight }

        if showingSetupChecklist {
            let checks = SetupChecklistView.estimatedHeight(report: appModel.preflightReport)
            return min(checks + extras, listMaxHeight)
        }

        let headers = CGFloat(herd.groups.count) * Layout.groupHeaderHeight
        guard !herd.rows.isEmpty || headers > 0 else {
            return min(Layout.emptyStateHeight + extras, listMaxHeight)
        }

        var height: CGFloat = 12 + headers + extras // list's own vertical padding
        for agent in herd.rows {
            height += rowHeight(agent)
        }
        return min(height, listMaxHeight)
    }

    /// Screen-aware cap on the list. The panel's chrome (header, filter bar,
    /// footer, banners, pending actions) doesn't shrink, so on a small or
    /// scaled display the list gives up height instead of pushing the footer
    /// off-screen. Roomier screens keep the 540pt ceiling, and the list never
    /// collapses below a few visible rows. Mirrors the dashboard's
    /// screen-aware `panelHeight` (a `MenuBarExtra` window can appear on any
    /// screen, so the screen under the mouse at open time is used, falling
    /// back to `NSScreen.main`).
    private var listMaxHeight: CGFloat {
        let screen = PanelLayout.panelScreen?.visibleFrame.height ?? 900
        var chrome = Layout.fixedChromeHeight
        if !appModel.pendingActions.isEmpty {
            chrome += Layout.pendingHeaderHeight
                + CGFloat(appModel.pendingActions.count) * Layout.pendingRowHeight
        }
        if appModel.lastError != nil { chrome += Layout.bannerHeight }
        if let health = appModel.adapterHealth, !health.compatible || !health.writesEnabled {
            chrome += Layout.bannerHeight
        }
        return min(
            Layout.listCeilingHeight,
            max(Layout.listMinHeight, screen - chrome - Layout.screenMargin)
        )
    }

    /// Height of one row: two text lines plus padding, and whatever the row
    /// grows by while it is the selected/expanded one. Every tile draws the
    /// cost chip and a full-width Peek/Jump/Nudge row, so that height is no
    /// longer gated on `hasUsage`.
    private func rowHeight(_ agent: Agent) -> CGFloat {
        var height = Layout.rowBaseHeight
        if let reason = agent.verdict.reasonText {
            height += reasonHeight(reason)
        }
        height += Layout.rowCostHeight
        height += Layout.rowPrimaryActionsHeight
        guard appModel.selectedAgentId == agent.id else { return height }

        height += Layout.rowActionsHeight
        switch expansion {
        case .none: break
        case .peek: height += PanelLayout.peekHeight
        case .peekLoading, .peekFailed, .nudge, .closeConfirm: height += Layout.rowInlineHeight
        }
        return height
    }

    /// Measured rendered height of a reason line. The row renders it at
    /// 12.5 pt with a two-line limit and fixed wrapping width; measuring the
    /// actual wrapped height (instead of the old flat 17 pt single-line
    /// budget) keeps the scroll-area estimate honest when a reason wraps.
    private func reasonHeight(_ text: String) -> CGFloat {
        ReasonLayout.height(for: text)
    }

    @ViewBuilder
    private func flatList(_ agents: [Agent]) -> some View {
        ForEach(agents) { agent in
            row(for: agent)
        }
    }

    @ViewBuilder
    private func groupedList(_ groups: [WorkspaceGroup]) -> some View {
        ForEach(groups, id: \.name) { group in
            Section {
                if !collapsedGroups.contains(group.name) {
                    ForEach(group.agents) { agent in
                        row(for: agent)
                    }
                }
            } header: {
                groupHeader(group)
            }
        }
    }

    private func groupHeader(_ group: WorkspaceGroup) -> some View {
        let collapsed = collapsedGroups.contains(group.name)
        return Button {
            if collapsed {
                collapsedGroups.remove(group.name)
            } else {
                collapsedGroups.insert(group.name)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Brand.secondaryText)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(group.name.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(group.name)
                Text("\(group.agents.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Brand.secondaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, Layout.gutter)
            .padding(.top, 9)
            .padding(.bottom, 5)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.03))
        .help(collapsed ? "Expand \(group.name)" : "Collapse \(group.name)")
    }

    private func row(for agent: Agent) -> some View {
        let isSelected = appModel.selectedAgentId == agent.id
        return AgentRow(
            agent: agent,
            dailyCost: appModel.usageSnapshot.agentSummary(for: agent.id, window: .day),
            isSelected: isSelected,
            expansion: isSelected ? expansion : .none,
            writeInFlight: appModel.inFlightAgentWrites.contains(agent.id),
            // Both read from the panel's own clock, at row-construction time,
            // so `AgentRow`'s `Equatable` conformance can see them change: a
            // row redraws when its figure ticks over or its wait crosses a
            // threshold, and stays put otherwise.
            dwellText: DwellFormatter.format(interval: now.timeIntervalSince(agent.enteredAt)),
            dwellBucket: DwellBucket.current(for: agent, now: now),
            nudgeDraft: nudgeText,
            nudgeText: $nudgeText,
            onSelect: {
                // Clicking a different row must close the previous expansion.
                // This used to live on `selectedAgentId` `onChange`; it cannot,
                // because Peek/Nudge select as part of opening an expansion
                // and that wipe would cancel them. Same-row clicks leave the
                // expansion alone — matching the old onChange (no-op on equal).
                if appModel.selectedAgentId != agent.id { resetExpansion() }
                appModel.selectedAgentId = agent.id
            },
            onJump: { jump(agent) },
            onPeekToggle: { togglePeek(agent) },
            onNudgeOpen: { openNudge(for: agent) },
            onNudgeSubmit: { submitNudge(agent) },
            onCloseRequest: { expansion = .closeConfirm },
            onCloseConfirm: { confirmClose(agent) },
            onCancelExpansion: { expansion = .none }
        )
        .equatable()
    }

    // MARK: - Data

    private static func needsYou(_ agent: Agent) -> Bool {
        agent.status == .blocked || agent.verdict.isSilent || agent.verdict.isProcessGone
    }

    /// Worst-first priority for the "Needs you" ranking. Process-gone is
    /// grouped with blocked (both map to `Brand.blocked` in `Brand.face(for:)`
    /// — the same "this needs you NOW" urgency), then silent. `done` agents are
    /// excluded from "Needs you" entirely (a finished agent does not need you).
    private static func needsYouPriority(_ agent: Agent) -> Int {
        if agent.status == .blocked || agent.verdict.isProcessGone { return 0 }
        if agent.verdict.isSilent { return 1 }
        return 3
    }

    /// The filter text, trimmed and case-folded. Callers hoist this out of
    /// their loop and pass it in: normalising the raw field inside the
    /// predicate re-trimmed and re-lowercased the query once per agent, per
    /// pass, which was most of what filtering actually cost.
    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Case-insensitive substring match across every field the row shows, so
    /// the filter matches whatever the user can actually read on screen.
    /// `query` must already be normalised — see `searchQuery`.
    private func matchesSearch(_ agent: Agent, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let haystack = [
            agent.displayName,
            agent.name,
            agent.kind.label,
            agent.workspaceName,
            agent.tabName,
            agent.cwd,
            // Both the state as the row prints it and herdr's raw status.
            // They differ where the verdict outranks the status — a pane
            // showing a GONE or SILENT pill is still `working` to herdr — and
            // a filter should match either: typing what the pill says has to
            // find the row, and typing "working" shouldn't hide a pane that
            // is working just because it has also gone quiet.
            Brand.face(for: agent).word,
            agent.status.rawValue,
        ]
        return haystack.contains { $0.lowercased().contains(query) }
    }

    private var needsYouAgents: [Agent] {
        let query = searchQuery
        return appModel.store.agents.values
            .filter { Self.needsYou($0) && matchesSearch($0, query: query) }
            .sorted { a, b in
                let pa = Self.needsYouPriority(a)
                let pb = Self.needsYouPriority(b)
                if pa != pb { return pa < pb }
                return a.enteredAt < b.enteredAt // longest-waiting first
            }
    }

    private var runningAgents: [Agent] {
        let query = searchQuery
        return appModel.store.agents.values
            .filter { $0.status == .working && matchesSearch($0, query: query) }
            .sorted { $0.enteredAt < $1.enteredAt }
    }

    private var allGroups: [WorkspaceGroup] {
        let query = searchQuery
        let agents = appModel.store.agents.values.filter { matchesSearch($0, query: query) }
        let grouped = Dictionary(grouping: agents, by: { $0.workspaceName })
        var groups: [WorkspaceGroup] = grouped.map { name, agents in
            let sorted = agents.sorted { a, b in
                let nameA = a.displayName.isEmpty ? a.name : a.displayName
                let nameB = b.displayName.isEmpty ? b.name : b.displayName
                if nameA != nameB { return nameA < nameB }
                return a.id.raw < b.id.raw
            }
            return WorkspaceGroup(name: name.isEmpty ? "(default)" : name, agents: sorted)
        }
        groups.sort { $0.name < $1.name }
        return groups
    }

    /// The rows the arrow keys walk. Key handling runs outside a body pass, so
    /// it re-derives rather than reading a cached copy that could be a
    /// keystroke out of date — but it derives only the rows. Going through
    /// `visibleHerd` would also tally the three scope counts on every
    /// keypress, and a keypress has no use for them.
    private var flatAgentsForKeyboardNav: [Agent] {
        switch appModel.scope {
        case .needsYou: return needsYouAgents
        case .running: return runningAgents
        case .all: return Self.rows(in: allGroups, collapsed: collapsedGroups)
        }
    }

    /// Flatten workspace groups to the agents actually on screen. Collapsed
    /// groups are folded away, so arrow keys skip them and the height budget
    /// doesn't reserve room for them.
    private static func rows(in groups: [WorkspaceGroup], collapsed: Set<String>) -> [Agent] {
        groups.filter { !collapsed.contains($0.name) }.flatMap { $0.agents }
    }

    // MARK: - Footer

    private func footer(herd: VisibleHerd) -> some View {
        HStack(spacing: 10) {
            newAgentMenu(label: "New agent")
            if case .starting(let kind) = appModel.newAgentState {
                Text("Starting \(kind)…")
                    .font(.system(size: 10))
                    .foregroundStyle(Brand.secondaryText)
            }
            Spacer(minLength: 6)
            keyboardHints(hasRows: !herd.rows.isEmpty)
            notificationToggle
            connectionIndicator
        }
        .padding(.horizontal, Layout.gutter)
        .padding(.vertical, 10)
    }

    /// Plain computed property, not an inline `if case` inside the builder —
    /// a result-builder context rewrites bare `if` statements even when they
    /// are deciding a `Bool` rather than producing views.
    private var isStartingAgent: Bool {
        if case .starting = appModel.newAgentState { return true }
        return false
    }

    /// Arrow / Space / Return triage. Stands down whenever a field or
    /// confirm dialog is using those keys. The filter field already did;
    /// nudge did not, so Space-to-peek closed the field on the first space
    /// of a typed sentence.
    private var triageKeysActive: Bool {
        !searchFocused
            && !showingSetupChecklist
            && expansion != .nudge
            && expansion != .closeConfirm
    }

    /// The panel is keyboard-first and, until now, silent about it: arrow keys,
    /// Space-to-peek, and Return-to-jump were documented in `PRODUCT.md` and
    /// nowhere on screen. This is the quietest place to say so — one 10 pt line
    /// in the footer, occupying space the footer already had.
    ///
    /// It stands down whenever it would compete for that space: with no rows
    /// there is nothing to navigate, and while an agent is starting the footer
    /// is already carrying a status line that matters more.
    ///
    /// It also has to tell the truth about *right now*. The panel opens with
    /// the filter field focused, and every one of the triage key handlers
    /// returns `.ignored` while it is — so advertising "↑↓ move" in the state
    /// the panel opens in would be advertising a key that does nothing. While
    /// the field holds focus the hint names the one key that does work, which
    /// is also the key that unlocks the others. Nudge and close-confirm do
    /// the same so the line never names a key the panel would swallow.
    @ViewBuilder
    private func keyboardHints(hasRows: Bool) -> some View {
        if hasRows && !isStartingAgent {
            Text(keyboardHintText)
                .font(.system(size: 10))
                .foregroundStyle(Brand.secondaryText)
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel(keyboardHintSpoken)
        }
    }

    private var keyboardHintText: String {
        if searchFocused { return "esc to browse" }
        if expansion == .nudge { return "⏎ send · esc cancel" }
        if expansion == .closeConfirm { return "esc cancel" }
        return "↑↓ move · space peek · ⏎ jump"
    }

    private var keyboardHintSpoken: String {
        if searchFocused {
            return "Keyboard: press escape to leave the filter field and browse agents"
        }
        if expansion == .nudge {
            return "Keyboard: return sends the nudge, escape cancels"
        }
        if expansion == .closeConfirm {
            return "Keyboard: press escape to cancel closing the agent"
        }
        return "Keyboard: up and down arrows move, space peeks, return jumps to the agent"
    }

    private var notificationToggle: some View {
        @Bindable var appModel = appModel
        return Toggle(isOn: $appModel.notificationsEnabled) {
            Image(systemName: appModel.notificationsEnabled ? "bell.fill" : "bell.slash.fill")
                .font(.system(size: 11))
        }
        .toggleStyle(.button)
        .controlSize(.regular)
        .help(appModel.notificationsEnabled ? "Notifications on" : "Notifications off — click to opt in")
        .accessibilityLabel("Notifications")
    }

    @ViewBuilder
    private var connectionIndicator: some View {
        switch appModel.connectionState {
        case .connected:
            HStack(spacing: 4) {
                // Brand.working, not system .green: it is the navy herd-light
                // vocabulary and resolves correctly in both appearances.
                Circle().fill(Brand.working).frame(width: 7, height: 7)
                Text("connected").font(.system(size: 11)).foregroundStyle(Brand.secondaryText)
            }
        case .connecting:
            HStack(spacing: 4) {
                Circle().fill(Brand.warn).frame(width: 7, height: 7)
                Text("connecting…").font(.system(size: 11)).foregroundStyle(Brand.secondaryText)
            }
        case .reconnecting, .disconnected:
            // Calm, steady indicator while the background poll keeps retrying
            // silently. No per-attempt number and no alarming colour — the UI
            // flips to "connected" exactly once on the next successful poll.
            HStack(spacing: 4) {
                Circle().fill(Brand.idle).frame(width: 7, height: 7)
                Text("disconnected").font(.system(size: 11)).foregroundStyle(Brand.secondaryText)
            }
        }
    }

    // MARK: - New agent menu

    private let pinnedKinds = ["claude", "codex", "opencode"]

    @ViewBuilder
    private func newAgentMenu(label: String, prominent: Bool = false) -> some View {
        let content = Menu {
            ForEach(pinnedKinds, id: \.self) { kind in
                kindSubmenu(kind)
            }
            let otherKinds = appModel.availableAgentKinds
                .map { $0.lowercased() }
                .filter { !pinnedKinds.contains($0) }
            if !otherKinds.isEmpty {
                Divider()
                ForEach(otherKinds, id: \.self) { kind in
                    kindSubmenu(kind)
                }
            }
        } label: {
            Label(label, systemImage: "plus")
                .font(.system(size: 12.5, weight: .medium))
        }
        .onAppear { appModel.loadAgentKindsIfNeeded() }

        if prominent {
            // Empty-state CTA: a real primary button, not a borderless label.
            content
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        } else {
            content
                .menuStyle(.borderlessButton)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func kindSubmenu(_ kind: String) -> some View {
        if appModel.workspaceOptions.isEmpty {
            Text(kind.capitalized)
        } else {
            Menu(kind.capitalized) {
                ForEach(appModel.workspaceOptions) { ws in
                    Menu(ws.name) {
                        Button("New tab") {
                            appModel.startNewAgent(kind: kind, workspaceId: ws.id)
                        }
                        let placements = appModel.placementOptions(forWorkspace: ws.id)
                        if !placements.isEmpty {
                            Divider()
                            Text("Split in existing tab")
                            ForEach(placements) { placement in
                                Button(placement.label) {
                                    appModel.startNewAgent(
                                        kind: kind,
                                        workspaceId: ws.id,
                                        targetPaneId: placement.id
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Banners

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Brand.blocked)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Brand.blocked)
                .lineLimit(2)
                .help(text)
            Spacer()
            Button("Retry") { appModel.resync() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Re-connect / Retry sync")
        }
        .padding(.horizontal, Layout.gutter)
        .padding(.vertical, 6)
        .background(Brand.blocked.opacity(0.06))
    }

    private func healthBanner(_ health: AdapterHealth) -> some View {
        let reason = health.reason ?? (health.compatible ? "writes disabled" : "incompatible protocol")
        let detail = "v\(health.protocolVersion): \(reason)"
        return HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Brand.warn)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Brand.warn)
                .lineLimit(1)
                .help(detail)
            Spacer()
        }
        .padding(.horizontal, Layout.gutter)
        .padding(.vertical, 6)
        .background(Brand.warn.opacity(0.06))
    }

    // MARK: - Empty states

    @ViewBuilder
    private func emptyStateBody(herd: VisibleHerd) -> some View {
        if appModel.store.agents.isEmpty {
            noAgentsEmptyState
        } else if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            emptyState(
                title: "No matches",
                subtitle: "Nothing here matches “\(searchText)”."
            )
        } else if appModel.scope == .running {
            emptyState(title: "Nothing running", subtitle: nothingRunningSubtitle(herd: herd))
        } else {
            emptyState(title: "All quiet", subtitle: allQuietSubtitle(herd: herd))
        }
    }

    /// Says how big the herd is that isn't working, so "nothing running" can
    /// be told apart from "nothing here". Written as two whole sentences
    /// rather than one with a count spliced in: "None of your 1 agent are
    /// working" is the kind of line that makes a careful tool feel careless.
    private func nothingRunningSubtitle(herd: VisibleHerd) -> String {
        herd.matching == 1
            ? "Your one agent isn't working right now."
            : "None of your \(herd.matching) agents are working right now."
    }

    /// "All quiet" reads very differently depending on *why* it is quiet, and
    /// the old subtitle could not tell the two apart: a herd of twenty agents
    /// working happily and a herd of twenty agents that all died half an hour
    /// ago both rendered "Nothing needs you right now." Naming how many are
    /// actually working turns a vague reassurance into a claim the user can
    /// check — which is the difference between trusting the panel and
    /// re-opening every pane to be sure.
    private func allQuietSubtitle(herd: VisibleHerd) -> String {
        guard herd.running > 0 else { return "Nothing needs you right now." }
        return herd.running == 1
            ? "1 agent is working. Nothing needs you."
            : "\(herd.running) agents are working. Nothing needs you."
    }

    private var noAgentsEmptyState: some View {
        VStack(spacing: 10) {
            FlockMark(size: 40, glow: true)
            Text("No agents yet")
                .font(.system(size: 15, weight: .semibold))
            Text("Shepherd watches the panes herdr is running. Start one and it appears here within a second.")
                .font(.system(size: 12.5))
                .foregroundStyle(Brand.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text(LiveHerdrAdapter.resolveSocketPath())
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Brand.secondaryText)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            newAgentMenu(label: "New agent", prominent: true)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private func emptyState(title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            FlockMark(size: 40, glow: true)
                .opacity(0.92)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(Brand.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    // MARK: - Brand chrome

    private func headerSubtitle(herd: VisibleHerd) -> String {
        switch appModel.connectionState {
        case .connected:
            return "\(herd.needsYou) need you · \(herd.done) done · \(herd.running) running"
        case .connecting:
            return "connecting…"
        case .reconnecting, .disconnected:
            return "disconnected"
        }
    }

    private var panelBackground: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            LinearGradient(
                colors: [Color.primary.opacity(0.03), .clear],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    // MARK: - Keyboard nav

    private func resetExpansion() {
        expansion = .none
        nudgeText = ""
    }

    private func moveSelection(up: Bool) {
        let visible = flatAgentsForKeyboardNav
        guard !visible.isEmpty else { return }

        let newId: AgentID
        if let current = appModel.selectedAgentId,
           let idx = visible.firstIndex(where: { $0.id == current }) {
            let newIdx = up ? max(0, idx - 1) : min(visible.count - 1, idx + 1)
            newId = visible[newIdx].id
        } else {
            newId = visible[0].id
        }
        if appModel.selectedAgentId != newId { resetExpansion() }
        appModel.selectedAgentId = newId
    }

    private func jumpSelected() {
        guard let id = appModel.selectedAgentId,
              let agent = appModel.store.agents[id] else { return }
        jump(agent)
    }

    private func jump(_ agent: Agent) {
        Task {
            let ok = await appModel.jump(agent)
            if ok { dismiss() }
        }
    }

    private func togglePeekSelected() {
        guard let id = appModel.selectedAgentId,
              let agent = appModel.store.agents[id] else { return }
        togglePeek(agent)
    }

    // MARK: - Peek / Nudge / Close

    private func togglePeek(_ agent: Agent) {
        // Expansion only renders on the selected row. Peek on another tile
        // is an explicit action, so selecting that tile is not auto-focus —
        // it is how the expansion has a place to appear. Switching agents
        // is an open, not a toggle-closed of whoever was peeked before.
        let alreadySelected = appModel.selectedAgentId == agent.id
        if !alreadySelected {
            appModel.selectedAgentId = agent.id
            nudgeText = ""
            beginPeekLoad(agent)
            return
        }
        if case .peek = expansion {
            expansion = .none
            return
        }
        if case .peekLoading = expansion {
            return
        }
        beginPeekLoad(agent)
    }

    private func beginPeekLoad(_ agent: Agent) {
        expansion = .peekLoading
        let paneId = agent.id.raw // herdr uses full session-qualified IDs (e.g. "w5:p2")
        Task {
            do {
                var result = try await appModel.adapter.read(
                    paneId: paneId, source: .detection, lines: 20
                )
                if result.text.isEmpty {
                    result = try await appModel.adapter.read(
                        paneId: paneId, source: .recent, lines: 20
                    )
                }
                let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false)
                let last20 = lines.suffix(20).joined(separator: "\n")
                let content = last20.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "(No terminal output is available yet.)"
                    : last20
                await MainActor.run {
                    guard appModel.selectedAgentId == agent.id else { return }
                    expansion = .peek(content)
                }
            } catch {
                await MainActor.run {
                    guard appModel.selectedAgentId == agent.id else { return }
                    expansion = .peekFailed("Peek failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func openNudge(for agent: Agent) {
        if appModel.selectedAgentId != agent.id {
            appModel.selectedAgentId = agent.id
        }
        nudgeText = ""
        expansion = .nudge
        // Drop filter focus so the field that just appeared can take it.
        // Triage keys then stand down via `triageKeysActive`.
        searchFocused = false
    }

    private func submitNudge(_ agent: Agent) {
        let text = nudgeText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(NudgeLimits.maxLength)
        guard !text.isEmpty else {
            expansion = .none
            return
        }
        appModel.nudge(agent, text: String(text))
        nudgeText = ""
        expansion = .none
    }

    private func confirmClose(_ agent: Agent) {
        appModel.closeAgent(agent)
        expansion = .none
        appModel.selectedAgentId = nil
    }
}

// MARK: - WorkspaceGroup

struct WorkspaceGroup {
    let name: String
    let agents: [Agent]
}
