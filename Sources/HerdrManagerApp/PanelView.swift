import SwiftUI
import HerdrManagerCore

struct PanelView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var peekContent: String?
    @State private var peekAgentId: AgentID?

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 0) {
            header
            statStrip
            Divider()
            if !appModel.pendingActions.isEmpty {
                PendingActionsView()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let groups = visibleGroups
                    if groups.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(groups.enumerated()), id: \.element.name) { wsIndex, group in
                            workspaceSection(index: wsIndex, group: group)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if let content = peekContent {
                peekView(content: content)
            }
            Divider()
            footer
        }
        .frame(width: 360, height: min(520, CGFloat(max(160, rowCount * 46 + 120))))
        .background(panelBackground)
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onKeyPress(.upArrow) {
            dismissPeek()
            moveSelection(up: true)
            return .handled
        }
        .onKeyPress(.downArrow) {
            dismissPeek()
            moveSelection(up: false)
            return .handled
        }
        .onKeyPress(.return) {
            focusSelected()
            return .handled
        }
        .onKeyPress(" ") {
            togglePeek()
            return .handled
        }
        .focusable()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            HerdMark(size: 16, glow: appModel.connectionState == .connected)
            VStack(alignment: .leading, spacing: 0) {
                Text("Herdr Manager")
                    .font(.system(size: 13, weight: .bold))
                Text(headerSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            iconButton(system: "arrow.clockwise", help: "Resync (⌘R)", shortcut: "r") {
                appModel.resync()
            }
            iconButton(
                system: appModel.showAll ? "eye.fill" : "eye.slash.fill",
                help: "Show all (⌘A)", shortcut: "a"
            ) {
                appModel.showAll.toggle()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func iconButton(
        system: String, help: String, shortcut: Character, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.borderless)
        .help(help)
        .keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
    }

    // MARK: - Stat strip

    private var statStrip: some View {
        let s = appModel.store
        let chips: [(label: String, count: Int, color: Color)] = [
            ("blocked", s.blockedCount, Brand.blocked),
            ("silent", s.silentCount, Brand.silent),
            ("done", s.doneCount, Brand.done),
            ("working", workingCount, Brand.working),
        ]
        let active = chips.filter { $0.count > 0 }
        let shown = active.isEmpty
            ? [("idle", s.agents.count, Brand.idle)]
            : active
        return HStack(spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, chip in
                HStack(spacing: 4) {
                    Circle()
                        .fill(chip.color)
                        .frame(width: 6, height: 6)
                        .shadow(color: chip.color.opacity(0.7), radius: 2)
                    Text("\(chip.count) \(chip.label)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(chip.color.opacity(0.12)))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            let total = appModel.store.agents.count
            let attention = appModel.store.attentionAgents.count
            Text("\(attention) attention · \(total) total")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            connectionIndicator
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var connectionIndicator: some View {
        switch appModel.connectionState {
        case .connected:
            Circle().fill(.green).frame(width: 6, height: 6)
            Text("connected").font(.caption2).foregroundStyle(.secondary)
        case .connecting:
            Circle().fill(.yellow).frame(width: 6, height: 6)
            Text("connecting…").font(.caption2).foregroundStyle(.secondary)
        case .reconnecting(let attempt):
            Circle().fill(.orange).frame(width: 6, height: 6)
            Text("reconnecting #\(attempt)…").font(.caption2).foregroundStyle(.secondary)
        case .disconnected:
            Circle().fill(.red).frame(width: 6, height: 6)
            Text("disconnected").font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            HerdMark(size: 34, glow: true, herd: true)
                .opacity(0.92)
            Text("All quiet")
                .font(.system(size: 13, weight: .semibold))
            Text("The herd is resting — nothing needs you right now.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - Workspace sections

    private func workspaceSection(index: Int, group: WorkspaceGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(group.name.isEmpty ? "(default)" : group.name.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                if !appModel.showAll && !group.hasAttention {
                    Text("\(group.agents.count) idle")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .keyboardShortcut(index < 9 ? KeyEquivalent(Character(String(index + 1))) : KeyEquivalent("0"), modifiers: .command)

            if appModel.showAll || group.hasAttention {
                let agentsToShow = appModel.showAll ? group.agents : group.attentionOnly
                ForEach(agentsToShow) { agent in
                    AgentRow(
                        agent: agent,
                        isSelected: appModel.selectedAgentId == agent.id
                    )
                    .equatable()
                    .onTapGesture(count: 2) {
                        appModel.selectedAgentId = agent.id
                        appModel.focusAgent(agent)
                    }
                    .onTapGesture {
                        appModel.selectedAgentId = agent.id
                    }
                }
            }
        }
    }

    // MARK: - Data

    private var visibleGroups: [WorkspaceGroup] {
        let agents = Array(appModel.store.agents.values)
        let grouped = Dictionary(grouping: agents, by: { $0.workspaceName })

        var groups: [WorkspaceGroup] = grouped.map { name, agents in
            // Deterministic total order: attentionPriority, then displayName, then id
            let sorted = agents.sorted { a, b in
                let pa = Self.attentionPriorityFull(a)
                let pb = Self.attentionPriorityFull(b)
                if pa != pb { return pa < pb }
                let nameA = a.displayName.isEmpty ? a.name : a.displayName
                let nameB = b.displayName.isEmpty ? a.name : b.displayName
                if nameA != nameB { return nameA < nameB }
                return a.id.raw < b.id.raw
            }
            let attention = sorted.filter { Self.isAttention($0) }
            return WorkspaceGroup(name: name.isEmpty ? "(default)" : name, agents: sorted, attentionOnly: attention)
        }

        // Deterministic group order: workspaces with attention first, then alphabetical by name
        groups.sort { a, b in
            if a.hasAttention != b.hasAttention { return a.hasAttention }
            return a.name < b.name
        }

        return groups
    }

    private var rowCount: Int {
        visibleGroups.reduce(0) { sum, group in
            let agentsCount = appModel.showAll ? group.agents.count : group.attentionOnly.count
            return sum + 1 + agentsCount // header + agents
        }
    }

    private var flatVisibleAgents: [Agent] {
        visibleGroups.flatMap { group in
            appModel.showAll ? group.agents : group.attentionOnly
        }
    }

    // MARK: - Brand chrome

    private var headerSubtitle: String {
        let total = appModel.store.agents.count
        let att = appModel.store.attentionAgents.count
        switch appModel.connectionState {
        case .connected:
            return att > 0 ? "\(total) agents · \(att) need you" : "\(total) agents · all quiet"
        case .connecting:
            return "connecting…"
        case .reconnecting(let n):
            return "reconnecting #\(n)…"
        case .disconnected:
            return "disconnected"
        }
    }

    private var workingCount: Int {
        appModel.store.agents.values.filter { $0.status == .working }.count
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

    private func moveSelection(up: Bool) {
        let visible = flatVisibleAgents
        guard !visible.isEmpty else { return }

        if let current = appModel.selectedAgentId,
           let idx = visible.firstIndex(where: { $0.id == current }) {
            let newIdx = up ? max(0, idx - 1) : min(visible.count - 1, idx + 1)
            appModel.selectedAgentId = visible[newIdx].id
        } else {
            appModel.selectedAgentId = visible.first?.id
        }
    }

    private func focusSelected() {
        guard let id = appModel.selectedAgentId,
              let agent = appModel.store.agents[id] else { return }
        appModel.focusAgent(agent)
    }

    // MARK: - Peek

    private func togglePeek() {
        if peekContent != nil {
            dismissPeek()
            return
        }
        guard let id = appModel.selectedAgentId,
              let agent = appModel.store.agents[id] else { return }
        let paneId = agent.id.raw  // herdr uses full session-qualified IDs (e.g. "w5:p2")
        peekAgentId = id
        Task {
            do {
                var result = try await appModel.adapter.read(paneId: paneId, source: .detection)
                if result.text.isEmpty {
                    result = try await appModel.adapter.read(paneId: paneId, source: .recent)
                }
                let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false)
                let last20 = lines.suffix(20).joined(separator: "\n")
                await MainActor.run {
                    self.peekContent = last20
                }
            } catch {
                await MainActor.run {
                    self.peekContent = "(peek failed: \(error.localizedDescription))"
                }
            }
        }
    }

    private func dismissPeek() {
        peekContent = nil
        peekAgentId = nil
    }

    private func peekView(content: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            ScrollView {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 160)
            .background(Color.black.opacity(0.03))
        }
    }

    // MARK: - Sorting helpers

    private static func isAttention(_ agent: Agent) -> Bool {
        agent.status == .blocked || agent.verdict.isSilent || agent.status == .done
    }

    private static func attentionPriorityFull(_ agent: Agent) -> Int {
        if agent.status == .blocked { return 0 }
        if agent.status == .done { return 1 }
        if agent.verdict.isSilent { return 2 }
        if agent.status == .working { return 3 }
        if agent.status == .idle { return 4 }
        return 5
    }
}

// MARK: - WorkspaceGroup

struct WorkspaceGroup {
    let name: String
    let agents: [Agent]
    let attentionOnly: [Agent]

    var hasAttention: Bool { !attentionOnly.isEmpty }
}
