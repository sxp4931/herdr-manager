import AppKit
import Darwin
import HerdrManagerCore

@MainActor
enum HerdrHostActivator {
    /// Brings forward the GUI application that owns a live Herdr client.
    ///
    /// Herdr is a terminal executable rather than an application bundle, so
    /// activating the Herdr PID itself cannot switch macOS Spaces. Walking its
    /// process ancestry finds Terminal, iTerm, Ghostty, or an IDE terminal host
    /// without hard-coding a particular app.
    static func activate() -> Bool {
        let processes = ProcessSnapshot.capture()
        let hostPIDs = ApplicationHostResolver.applicationProcessIDs(
            hostingExecutableNamed: "herdr",
            in: processes
        )

        for pid in hostPIDs {
            guard let application = NSRunningApplication(processIdentifier: pid) else {
                continue
            }
            if application.activate(options: [.activateAllWindows]) {
                return true
            }
        }

        return false
    }
}

private enum ProcessSnapshot {
    static func capture() -> [HostProcess] {
        let capacity = max(Int(proc_listallpids(nil, 0)), 1)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return [] }

        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 0, let parentPID = parentPID(of: pid) else { return nil }

            var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 else {
                return nil
            }

            let runningApplication = NSRunningApplication(processIdentifier: pid)
            let nameBytes = nameBuffer
                .prefix { $0 != 0 }
                .map { UInt8(bitPattern: $0) }
            return HostProcess(
                pid: pid,
                parentPID: parentPID,
                executableName: String(decoding: nameBytes, as: UTF8.self),
                isForegroundApplication: runningApplication?.activationPolicy == .regular
            )
        }
    }

    /// `proc_pidinfo` cannot inspect macOS's setuid `login` intermediary.
    /// `sysctl(KERN_PROC_PID)` can, which keeps the ancestry intact between a
    /// terminal-hosted Herdr process and Terminal.app.
    private static func parentPID(of pid: pid_t) -> pid_t? {
        var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride

        let result = query.withUnsafeMutableBufferPointer { queryBuffer in
            withUnsafeMutablePointer(to: &process) { processBuffer in
                sysctl(
                    queryBuffer.baseAddress,
                    UInt32(queryBuffer.count),
                    processBuffer,
                    &size,
                    nil,
                    0
                )
            }
        }

        guard result == 0, size == MemoryLayout<kinfo_proc>.stride else {
            return nil
        }
        return process.kp_eproc.e_ppid
    }
}
