import Foundation

/// The small process-tree projection needed to find the GUI application that
/// hosts a command-line program. Herdr itself is a terminal executable, so it
/// has no app activation identity of its own.
public struct HostProcess: Sendable, Equatable {
    public let pid: Int32
    public let parentPID: Int32
    public let executableName: String
    public let isForegroundApplication: Bool

    public init(
        pid: Int32,
        parentPID: Int32,
        executableName: String,
        isForegroundApplication: Bool
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.executableName = executableName
        self.isForegroundApplication = isForegroundApplication
    }
}

public enum ApplicationHostResolver {
    /// Finds the first foreground-capable application in each matching
    /// executable's ancestry. Background instances (such as `herdr server`)
    /// naturally produce no result because their ancestry ends at launchd.
    public static func applicationProcessIDs(
        hostingExecutableNamed executableName: String,
        in processes: [HostProcess]
    ) -> [Int32] {
        let byPID = Dictionary(
            processes.map { ($0.pid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var resolved: [Int32] = []
        var resolvedSet: Set<Int32> = []

        for process in processes where process.executableName == executableName {
            var candidate: HostProcess? = process
            var visited: Set<Int32> = []

            while let current = candidate, visited.insert(current.pid).inserted {
                if current.isForegroundApplication {
                    if resolvedSet.insert(current.pid).inserted {
                        resolved.append(current.pid)
                    }
                    break
                }
                guard current.parentPID > 1 else { break }
                candidate = byPID[current.parentPID]
            }
        }

        return resolved
    }
}
