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
            Divider()
            if !appModel.pendingActions.isEmpty {
                PendingActionsView()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
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
        .frame(width: 360, height: min(480, CGFloat(max(120, rowCount * 28 + 80))))
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
        HStack {
            Text("Herdr Manager")
                .font(.headline)
            Spacer()
            Button {
                appModel.resync()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Resync (⌘R)")
            .keyboardShortcut("r", modifiers: .command)

            Button {
                appModel.showAll.toggle()
            } label: {
                Image(systemName: appModel.showAll ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .help("Show all (⌘A)")
            .keyboardShortcut("a", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
        VStack(spacing: 4) {
            Text("🟢 All clear")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("No agents need attention")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Workspace sections

    private func workspaceSection(index: Int, group: WorkspaceGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(group.name)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if !appModel.showAll && !group.hasAttention {
                    Text("(\(group.agents.count) idle)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
                    .onTapGesture {
                        appModel.selectedAgentId = agent.id
                    }
                    .onTapGesture(count: 2) {
                        appModel.selectedAgentId = agent.id
                        appModel.focusAgent(agent)
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
            let sorted = agents.sorted { a, b in
                Self.attentionPriority(a) < Self.attentionPriority(b)
            }
            let attention = sorted.filter { Self.isAttention($0) }
            return WorkspaceGroup(name: name.isEmpty ? "(default)" : name, agents: sorted, attentionOnly: attention)
        }

        // Sort: workspaces with attention first, then alphabetical
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

    private static func attentionPriority(_ agent: Agent) -> Int {
        switch agent.status {
        case .blocked: return 0
        case .done: return 1
        case .idle: return 3
        case .working: return 4
        case .unknown: return 5
        }
        // silent verdict agents that aren't blocked/done
    }

    // Override for silent verdict
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
