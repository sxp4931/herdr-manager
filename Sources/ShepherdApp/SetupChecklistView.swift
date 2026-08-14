import SwiftUI
import AppKit
import HerdrManagerCore

// MARK: - Face

/// Colour + glyph + word for one setup-check status, resolved together so a
/// new `PreflightStatus` cannot be added without all three. Mirrors
/// `Brand.face(for:)` for agent rows.
struct SetupFace {
    let color: Color
    let strong: Color
    let symbol: String
    let word: String

    static func resolve(_ status: PreflightStatus) -> SetupFace {
        switch status {
        case .pass:
            return SetupFace(
                color: Brand.approveFill,
                strong: Brand.pillWorking,
                symbol: "checkmark.circle.fill",
                word: "Ready"
            )
        case .fail:
            return SetupFace(
                color: Brand.blocked,
                strong: Brand.pillBlocked,
                symbol: "exclamationmark.triangle.fill",
                word: "Action needed"
            )
        case .warn:
            return SetupFace(
                color: Brand.warn,
                strong: Brand.warn,
                symbol: "exclamationmark.circle.fill",
                word: "Limited"
            )
        case .waiting:
            return SetupFace(
                color: Brand.silent,
                strong: Brand.pillSilent,
                symbol: "clock.fill",
                word: "Waiting"
            )
        case .checking:
            return SetupFace(
                color: Brand.unknown,
                strong: Brand.pillUnknown,
                symbol: "ellipsis.circle",
                word: "Checking"
            )
        }
    }
}

// MARK: - Checklist

struct SetupChecklistView: View {
    let report: PreflightReport
    let onRecheck: () -> Void

    /// Height budget for the panel's list area. Five collapsed rows plus one
    /// expanded block; the panel caps this against the screen itself.
    static func estimatedHeight(report: PreflightReport) -> CGFloat {
        let rows = CGFloat(max(report.checks.count, 1))
        let collapsed: CGFloat = 64
        let expandedExtra: CGFloat = report.firstUnresolved == nil ? 0 : 130
        return 12 + rows * collapsed + expandedExtra
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(report.checks) { check in
                SetupCheckRow(
                    check: check,
                    expanded: report.firstUnresolved?.id == check.id,
                    onRecheck: onRecheck
                )
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Check row

/// Same species as `AgentRow`: left status rail, status glyph, title, state
/// pill, mono detail. Only the first unresolved check expands.
private struct SetupCheckRow: View {
    let check: PreflightCheck
    let expanded: Bool
    let onRecheck: () -> Void

    @State private var isHovering = false

    var body: some View {
        let face = SetupFace.resolve(check.status)
        let accent = face.color
        let alarmed = check.status == .fail || check.status == .warn

        HStack(alignment: .top, spacing: 0) {
            Capsule()
                .fill(accent)
                .frame(width: 3.5)
                .padding(.vertical, 8)
                .shadow(
                    color: accent.opacity(alarmed ? 0.75 : 0.25),
                    radius: alarmed ? 5 : 1.5
                )
                .padding(.trailing, 11)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    SetupStatusGlyph(face: face, active: alarmed)
                    Text(check.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    statePill(face: face)
                }

                if let detail = check.detail {
                    Text(detail)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Brand.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(detail)
                }

                if expanded, check.status != .pass, check.status != .checking {
                    expandedBody(face: face)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.trailing, 12)
        }
        .padding(.leading, 8)
        .background(cardBackground(accent: accent, active: alarmed))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    accent.opacity(isHovering || expanded ? 0.4 : 0.14),
                    lineWidth: 1
                )
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .onHover { hovering in isHovering = hovering }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(face: face))
    }

    @ViewBuilder
    private func expandedBody(face: SetupFace) -> some View {
        if let explanation = check.explanation {
            Text(explanation)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(face.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }

        if let command = check.remedyCommand {
            HStack(alignment: .center, spacing: 8) {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CopyIconButton(text: command, help: "Copy command")
            }
            .padding(8)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.top, 4)
        }

        HStack(spacing: 8) {
            if let url = check.remedyURL {
                Link("Get herdr", destination: url)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.amber)
            }
            if check.id == .connected, check.status == .fail {
                Button("Check again") { onRecheck() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Re-run setup checks (⌘R)")
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private func statePill(face: SetupFace) -> some View {
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

    private func accessibilityLabel(face: SetupFace) -> String {
        var parts = [check.title, face.word]
        if let detail = check.detail { parts.append(detail) }
        if expanded, let explanation = check.explanation { parts.append(explanation) }
        return parts.joined(separator: ", ")
    }
}

/// 16 pt status chip matching `AgentRow`'s `StatusGlyph`, with the setup
/// check's named SF Symbol inside.
private struct SetupStatusGlyph: View {
    let face: SetupFace
    let active: Bool
    private let side: CGFloat = 16

    var body: some View {
        ZStack {
            Circle()
                .fill(face.color.opacity(0.14))
            Circle()
                .strokeBorder(face.color.opacity(active ? 0.9 : 0.55), lineWidth: 1)
            Image(systemName: face.symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(face.strong)
        }
        .frame(width: side, height: side)
        .shadow(color: face.color.opacity(active ? 0.45 : 0), radius: active ? 2.5 : 0)
        .accessibilityHidden(true)
    }
}

// MARK: - Copy button

/// 30 pt borderless circle, `doc.on.doc`, flipping to `checkmark` for 1.5 s
/// after a copy. A single discrete state change, not a repeating animation.
struct CopyIconButton: View {
    let text: String
    var help: String = "Copy"

    @State private var copied = false
    @State private var generation = 0

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.borderless)
        .help(copied ? "Copied" : help)
        .accessibilityLabel(copied ? "Copied" : help)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        generation += 1
        let gen = generation
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            if gen == generation {
                copied = false
            }
        }
    }
}

// MARK: - First-success row

struct FirstSuccessRow: View {
    let agentCount: Int
    let onDismiss: () -> Void

    private var message: String {
        let noun = agentCount == 1 ? "agent" : "agents"
        return "Connected to herdr — watching \(agentCount) \(noun)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Brand.approveFill)
            Text(message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Brand.approveFill.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Brand.approveFill.opacity(0.28), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }

    static let estimatedHeight: CGFloat = 56
}

// MARK: - MCP hookup card

struct MCPHookupCard: View {
    let resolution: MCPBridgePath.Resolution
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Let your agents see the herd")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text("Shepherd ships an MCP bridge so Claude Code or Codex can read the same live state you see here — under the same safety policy.")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Brand.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss MCP card")
            }

            HStack(alignment: .center, spacing: 8) {
                Text(resolution.displayText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(resolution.isResolved ? .primary : Brand.secondaryText)
                if let command = resolution.copyableCommand {
                    CopyIconButton(text: command, help: "Copy MCP command")
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    static let estimatedHeight: CGFloat = 150
}

// MARK: - MCP path resolution

enum MCPBridgePath {
    enum Resolution: Equatable {
        case bundled(path: String)
        case swiftRun
        case missing(reason: String)

        var displayText: String {
            switch self {
            case .bundled(let path): return path
            case .swiftRun: return "swift run herdr-manager-mcp"
            case .missing(let reason): return reason
            }
        }

        var copyableCommand: String? {
            switch self {
            case .bundled(let path): return path
            case .swiftRun: return "swift run herdr-manager-mcp"
            case .missing: return nil
            }
        }

        var isResolved: Bool {
            if case .missing = self { return false }
            return true
        }
    }

    /// Resolve at runtime. Never hard-code a path that does not exist.
    static func resolve() -> Resolution {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/herdr-manager-mcp")
        if FileManager.default.isExecutableFile(atPath: helper.path) {
            return .bundled(path: helper.path)
        }
        // A packaged .app without the helper is a broken bundle; say so.
        // `swift run` produces a raw executable, not an .app, so fall back
        // to the package command rather than inventing a path.
        if Bundle.main.bundleURL.pathExtension == "app" {
            return .missing(
                reason: "Shepherd could not find herdr-manager-mcp in this app bundle."
            )
        }
        return .swiftRun
    }
}
