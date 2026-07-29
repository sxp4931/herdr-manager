import SwiftUI
import HerdrManagerCore

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let store = appModel.store
        let blocked = store.blockedCount
        let silent = store.silentCount
        let done = store.doneCount
        let attentionTotal = blocked + silent + done
        let connected = appModel.connectionState == .connected

        Group {
            if !connected {
                Text("⚪️⚠︎")
            } else if blocked > 0 {
                Text("🔴\(attentionTotal > 0 ? " \(attentionTotal)" : "")")
            } else if silent > 0 {
                Text("🟠\(attentionTotal > 0 ? " \(attentionTotal)" : "")")
            } else if done > 0 {
                Text("🔵\(attentionTotal > 0 ? " \(attentionTotal)" : "")")
            } else {
                Text("🟢")
            }
        }
        .font(.system(size: 14))
        .onAppear {
            appModel.start()
        }
    }
}
