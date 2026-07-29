import SwiftUI
import HerdrManagerCore

struct PendingActionsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let actions = appModel.pendingActions
        guard !actions.isEmpty else { return AnyView(EmptyView()) }

        let grouped = Dictionary(grouping: actions, by: { $0.tool })

        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                HStack {
                    Text("Pending Actions (\(actions.count))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 2)

                ForEach(Array(grouped.keys.sorted()), id: \.self) { tool in
                    let toolActions = grouped[tool] ?? []
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(tool)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if toolActions.count >= 2 {
                                Button {
                                    appModel.approveAll(toolActions.map(\.actionId))
                                } label: {
                                    Text("Approve All (\(toolActions.count))")
                                        .font(.system(size: 9, weight: .medium))
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.mini)
                            }
                        }
                        .padding(.horizontal, 12)

                        ForEach(toolActions, id: \.actionId) { action in
                            actionRow(action)
                        }
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func actionRow(_ action: PendingAction) -> some View {
        HStack(spacing: 6) {
            // Key param preview
            let paramPreview = action.params.values.first.map { String($0.prefix(30)) } ?? ""
            Text(paramPreview.isEmpty ? action.actionId : paramPreview)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            Button {
                appModel.approveAction(action.actionId)
            } label: {
                Text("OK")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .help("Approve")

            Button {
                appModel.denyAction(action.actionId)
            } label: {
                Text("Deny")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .help("Deny")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }
}
