import SwiftUI
import AppKit

// Custom entry point so we can ignore SIGPIPE before anything touches a socket.
// POSIX sockets raise SIGPIPE on broken connections, which kills the process.
@main
enum ShepherdMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        ShepherdApp.main()
    }
}

struct ShepherdApp: App {
    @State private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Hide from Dock — menu-bar-only app
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(appModel)
        } label: {
            MenuBarLabel()
                .environment(appModel)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: scenePhase) { _, newPhase in
            // Save dwell state when the app is backgrounded or terminated.
            if newPhase == .background || newPhase == .inactive {
                appModel.dwellTracker.save()
            }
        }
    }
}
