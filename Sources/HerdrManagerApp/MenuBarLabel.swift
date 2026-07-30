import SwiftUI
import HerdrManagerCore

/// The menu-bar item: a custom on-brand amber "H" herd-mark carrying a single
/// worst-state status light in its corner, plus the attention count. No emoji —
/// the glyph is drawn from the same identity as the app icon.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let store = appModel.store
        let blocked = store.blockedCount
        let silent = store.silentCount
        let done = store.doneCount
        let attention = blocked + silent + done
        let connected = appModel.connectionState == .connected
        let dot = Brand.worstColor(
            blocked: blocked, silent: silent, done: done, connected: connected
        )

        HStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                HerdMark(size: 13, glow: connected)
                Circle()
                    .fill(dot)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 0.75))
                    .shadow(color: dot.opacity(0.85), radius: 2)
                    .offset(x: 2, y: -1)
            }
            .frame(width: 16, height: 15)

            if attention > 0 && connected {
                Text("\(attention)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
        .onAppear {
            appModel.start()
        }
    }
}
