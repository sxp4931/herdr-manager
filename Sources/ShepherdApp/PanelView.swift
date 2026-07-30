import SwiftUI
import AppKit
import HerdrManagerCore

struct PanelView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            if !appModel.pendingActions.isEmpty {
                PendingActionsView()
                Divider()
            }
            content
            Divider()
            if let errorText = appModel.lastError {
                errorBanner(errorText)
            }
            if let health = appModel.adapterHealth, !health.compatible || !health.writesEnabled {
                healthBanner(health)
            }
            footer
        }
        // Width is fixed; height is whatever the content adds up to. A
        // `minHeight`/`maxHeight` pair here is actively harmful: the
        // `MenuBarExtra` window resolves such a frame to its *minimum* and then
        // clips the header — which is what kept the old panel at 220pt. The
        // list is the only flexible piece, and it carries an explicit height.
        .frame(width: Layout.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(panelBackground)
        .onKeyPress(.escape) {
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
            guard !searchFocused else { return .ignored }
            moveSelection(up: true)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !searchFocused else { return .ignored }
            moveSelection(up: false)
            return .handled
        }
        .onKeyPress(.return) {
            guard !searchFocused else { return .ignored }
            jumpSelected()
            return .handled
        }
        .onKeyPress(" ") {
            guard !searchFocused else { return .ignored }
            togglePeekSelected()
            return .handled
        }
        .focusable()
        .onChange(of: appModel.selectedAgentId) { _, _ in
            resetExpansion()
        }
    }

    /// One place to tune the panel's overall geometry. The panel used to be a
    /// 400×560 box with a 400pt scroll area, which put ~2.5 rows on screen at
    /// once; these are the roomier numbers everything else is sized against.
    private enum Layout {
        static let panelWidth: CGFloat = 500
        static let gutter: CGFloat = 14

        /// List sizing. These are estimates, not measurements: they only decide
        /// how tall the scroll area is, so being a few points off costs at worst
        /// a slightly early scrollbar.
        static let listMaxHeight: CGFloat = 540
        static let emptyStateHeight: CGFloat = 210
        static let rowBaseHeight: CGFloat = 64
        static let rowReasonHeight: CGFloat = 17
        static let rowActionsHeight: CGFloat = 40
        static let rowPeekHeight: CGFloat = 228
        static let rowInlineHeight: CGFloat = 36
        static let groupHeaderHeight: CGFloat = 33
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            FlockMark(size: 20, glow: appModel.connectionState == .connected)
            VStack(alignment: .leading, spacing: 1) {
                Text("Shepherd")
                    .font(.system(size: 15, weight: .bold))
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            iconButton(system: "arrow.clockwise", help: "Resync (⌘R)", shortcut: "r") {
                appModel.resync()
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
        }
        .padding(.horizontal, Layout.gutter)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }

    private func iconButton(
        system: String, help: String, shortcut: Character, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.borderless)
        .help(help)
        .keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
    }

    // MARK: - Filter bar (scope + search)

    private var filterBar: some View {
        VStack(spacing: 9) {
            scopePicker
            searchField
        }
        .padding(.horizontal, Layout.gutter)
        .padding(.vertical, 10)
    }

    private var scopePicker: some View {
        @Bindable var appModel = appModel
        return Picker("", selection: $appModel.scope) {
            ForEach(TriageScope.allCases, id: \.self) { scope in
                Text("\(scope.label) \(count(for: scope))").tag(scope)
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
                .foregroundStyle(.secondary)
            TextField("Filter by name, kind, workspace…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear filter")
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
                    searchFocused ? Brand.amber.opacity(0.7) : Color.primary.opacity(0.10),
                    lineWidth: 1
                )
        )
    }

    private func count(for scope: TriageScope) -> Int {
        switch scope {
        case .needsYou: return needsYouAgents.count
        case .running: return runningAgents.count
        case .all: return appModel.store.agents.count
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3, pinnedViews: [.sectionHeaders]) {
                switch appModel.scope {
                case .needsYou:
                    if needsYouAgents.isEmpty {
                        emptyStateBody
                    } else {
                        flatList(needsYouAgents)
                    }
                case .running:
                    if runningAgents.isEmpty {
                        emptyStateBody
                    } else {
                        flatList(runningAgents)
                    }
                case .all:
                    if allGroups.isEmpty {
                        emptyStateBody
                    } else {
                        groupedList
                    }
                }
            }
            .padding(.vertical, 6)
        }
        // A ScrollView has no ideal height of its own, so inside the
        // `MenuBarExtra` window it collapses to almost nothing unless it is
        // told how tall to be. `listHeight` measures the content and clamps it,
        // so a short list shrinks the panel and a long one fills it and scrolls.
        .frame(height: listHeight)
        .scrollIndicators(.automatic)
    }

    /// Estimated height of the visible list, capped at the panel's budget.
    /// Collapsed groups still contribute their header, so folding a group
    /// shrinks the panel to fit rather than leaving dead space behind.
    private var listHeight: CGFloat {
        let agents = flatAgentsForKeyboardNav
        let headers = appModel.scope == .all
            ? CGFloat(allGroups.count) * Layout.groupHeaderHeight
            : 0
        guard !agents.isEmpty || headers > 0 else { return Layout.emptyStateHeight }

        var height: CGFloat = 12 + headers // list's own vertical padding
        for agent in agents {
            height += rowHeight(agent)
        }
        return min(height, Layout.listMaxHeight)
    }

    /// Height of one row: two text lines plus padding, and whatever the row
    /// grows by while it is the selected/expanded one.
    private func rowHeight(_ agent: Agent) -> CGFloat {
        var height = Layout.rowBaseHeight
        if agent.verdict.reasonText != nil { height += Layout.rowReasonHeight }
        guard appModel.selectedAgentId == agent.id else { return height }

        height += Layout.rowActionsHeight
        switch expansion {
        case .none: break
        case .peek: height += Layout.rowPeekHeight
        case .peekLoading, .nudge, .closeConfirm: height += Layout.rowInlineHeight
        }
        return height
    }

    @ViewBuilder
    private func flatList(_ agents: [Agent]) -> some View {
        ForEach(agents) { agent in
            row(for: agent)
        }
    }

    @ViewBuilder
    private var groupedList: some View {
        ForEach(allGroups, id: \.name) { group in
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
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(group.name.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(group.agents.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
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
        .background(.ultraThinMaterial)
        .help(collapsed ? "Expand \(group.name)" : "Collapse \(group.name)")
    }

    private func row(for agent: Agent) -> some View {
        let isSelected = appModel.selectedAgentId == agent.id
        return AgentRow(
            agent: agent,
            isSelected: isSelected,
            expansion: isSelected ? expansion : .none,
            nudgeText: $nudgeText,
            onSelect: { appModel.selectedAgentId = agent.id },
            onJump: { jump(agent) },
            onPeekToggle: { togglePeek(agent) },
            onNudgeOpen: { openNudge() },
            onNudgeSubmit: { submitNudge(agent) },
            onCloseRequest: { expansion = .closeConfirm },
            onCloseConfirm: { confirmClose(agent) },
            onCancelExpansion: { expansion = .none }
        )
        .equatable()
    }

    // MARK: - Data

    private static func needsYou(_ agent: Agent) -> Bool {
        agent.status == .blocked || agent.verdict.isSilent || agent.status == .done || agent.verdict.isProcessGone
    }

    /// Worst-first priority for the "Needs you" ranking. Process-gone is
    /// grouped with blocked (both map to `Brand.blocked` in `Brand.color(for:)`
    /// — the same "this needs you NOW" urgency), then silent, then done.
    private static func needsYouPriority(_ agent: Agent) -> Int {
        if agent.status == .blocked || agent.verdict.isProcessGone { return 0 }
        if agent.verdict.isSilent { return 1 }
        if agent.status == .done { return 2 }
        return 3
    }

    /// Case-insensitive substring match across every field the row shows, so
    /// the filter matches whatever the user can actually read on screen.
    private func matchesSearch(_ agent: Agent) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        let haystack = [
            agent.displayName,
            agent.name,
            agent.kind.label,
            agent.workspaceName,
            agent.tabName,
            agent.cwd,
            agent.status.rawValue,
        ]
        return haystack.contains { $0.lowercased().contains(query) }
    }

    private var needsYouAgents: [Agent] {
        appModel.store.agents.values
            .filter { Self.needsYou($0) && matchesSearch($0) }
            .sorted { a, b in
                let pa = Self.needsYouPriority(a)
                let pb = Self.needsYouPriority(b)
                if pa != pb { return pa < pb }
                return a.enteredAt < b.enteredAt // longest-waiting first
            }
    }

    private var runningAgents: [Agent] {
        appModel.store.agents.values
            .filter { $0.status == .working && matchesSearch($0) }
            .sorted { $0.enteredAt < $1.enteredAt }
    }

    private var allGroups: [WorkspaceGroup] {
        let agents = appModel.store.agents.values.filter { matchesSearch($0) }
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

    private var flatAgentsForKeyboardNav: [Agent] {
        switch appModel.scope {
        case .needsYou: return needsYouAgents
        case .running: return runningAgents
        // Collapsed groups are not on screen, so arrow keys must skip them.
        case .all: return allGroups
            .filter { !collapsedGroups.contains($0.name) }
            .flatMap { $0.agents }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            newAgentMenu(label: "＋ New agent")
            if case .starting(let kind) = appModel.newAgentState {
                Text("Starting \(kind)…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            notificationToggle
            connectionIndicator
        }
        .padding(.horizontal, Layout.gutter)
        .padding(.vertical, 10)
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
    }

    @ViewBuilder
    private var connectionIndicator: some View {
        switch appModel.connectionState {
        case .connected:
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("connected").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .connecting:
            HStack(spacing: 4) {
                Circle().fill(.yellow).frame(width: 7, height: 7)
                Text("connecting…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .reconnecting, .disconnected:
            // Calm, steady indicator while the background poll keeps retrying
            // silently. No per-attempt number and no alarming colour — the UI
            // flips to "connected" exactly once on the next successful poll.
            HStack(spacing: 4) {
                Circle().fill(Color.secondary).frame(width: 7, height: 7)
                Text("disconnected").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - New agent menu

    private let pinnedKinds = ["claude", "codex", "opencode"]

    @ViewBuilder
    private func newAgentMenu(label: String) -> some View {
        Menu {
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
            Text(label).font(.system(size: 12.5, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onAppear { appModel.loadAgentKindsIfNeeded() }
    }

    @ViewBuilder
    private func kindSubmenu(_ kind: String) -> some View {
        if appModel.workspaceOptions.isEmpty {
            Text(kind.capitalized)
        } else {
            Menu(kind.capitalized) {
                ForEach(appModel.workspaceOptions) { ws in
                    Button(ws.name) {
                        appModel.startNewAgent(kind: kind, workspaceId: ws.id)
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
                .foregroundStyle(.red)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, Layout.gutter)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.06))
    }

    private func healthBanner(_ health: AdapterHealth) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            let reason = health.reason ?? (health.compatible ? "writes disabled" : "incompatible protocol")
            Text("v\(health.protocolVersion): \(reason)")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, Layout.gutter)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.06))
    }

    // MARK: - Empty states

    @ViewBuilder
    private var emptyStateBody: some View {
        if appModel.connectionState != .connected {
            disconnectedEmptyState
        } else if appModel.store.agents.isEmpty {
            noAgentsEmptyState
        } else if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            emptyState(
                title: "No matches",
                subtitle: "Nothing here matches “\(searchText)”."
            )
        } else if appModel.scope == .running {
            emptyState(title: "Nothing running", subtitle: "No agents are currently working.")
        } else {
            emptyState(title: "All quiet", subtitle: "Nothing needs you right now.")
        }
    }

    private var disconnectedEmptyState: some View {
        VStack(spacing: 10) {
            FlockMark(size: 40, glow: false, dimmed: true)
            Text("herdr isn't running")
                .font(.system(size: 15, weight: .semibold))
            Text("Looked for it at:")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            Text(LiveHerdrAdapter.resolveSocketPath())
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private var noAgentsEmptyState: some View {
        VStack(spacing: 10) {
            FlockMark(size: 40, glow: true)
            Text("No agents yet")
                .font(.system(size: 15, weight: .semibold))
            Text("Start one below to get going.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            newAgentMenu(label: "＋ New agent")
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
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    // MARK: - Brand chrome

    private var headerSubtitle: String {
        switch appModel.connectionState {
        case .connected:
            return "\(needsYouAgents.count) need you · \(runningAgents.count) running · \(appModel.store.agents.count) agents"
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
                colors: [Brand.bgMid.opacity(0.22), Brand.bgDeep.opacity(0.06), .clear],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                colors: [Brand.amber.opacity(0.10), .clear],
                center: .topLeading, startRadius: 8, endRadius: 340
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

        if let current = appModel.selectedAgentId,
           let idx = visible.firstIndex(where: { $0.id == current }) {
            let newIdx = up ? max(0, idx - 1) : min(visible.count - 1, idx + 1)
            appModel.selectedAgentId = visible[newIdx].id
        } else {
            appModel.selectedAgentId = visible.first?.id
        }
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
        if case .peek = expansion {
            expansion = .none
            return
        }
        if case .peekLoading = expansion {
            return
        }
        expansion = .peekLoading
        let paneId = agent.id.raw // herdr uses full session-qualified IDs (e.g. "w5:p2")
        Task {
            do {
                var result = try await appModel.adapter.read(paneId: paneId, source: .detection)
                if result.text.isEmpty {
                    result = try await appModel.adapter.read(paneId: paneId, source: .recent)
                }
                let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false)
                let last20 = lines.suffix(20).joined(separator: "\n")
                await MainActor.run {
                    guard appModel.selectedAgentId == agent.id else { return }
                    expansion = .peek(last20)
                }
            } catch {
                await MainActor.run {
                    guard appModel.selectedAgentId == agent.id else { return }
                    expansion = .peek("(peek failed: \(error.localizedDescription))")
                }
            }
        }
    }

    private func openNudge() {
        nudgeText = ""
        expansion = .nudge
    }

    private func submitNudge(_ agent: Agent) {
        let text = nudgeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            expansion = .none
            return
        }
        appModel.nudge(agent, text: text)
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
