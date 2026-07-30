import Testing
@testable import HerdrManagerCore

@Suite("Application host resolver")
struct ApplicationHostResolverTests {
    @Test("Resolves a terminal app through login and shell ancestors")
    func resolvesTerminalHost() {
        let processes = [
            HostProcess(pid: 473, parentPID: 1, executableName: "Terminal", isForegroundApplication: true),
            HostProcess(pid: 609, parentPID: 473, executableName: "login", isForegroundApplication: false),
            HostProcess(pid: 637, parentPID: 609, executableName: "zsh", isForegroundApplication: false),
            HostProcess(pid: 1_947, parentPID: 637, executableName: "herdr", isForegroundApplication: false),
        ]

        let result = ApplicationHostResolver.applicationProcessIDs(
            hostingExecutableNamed: "herdr",
            in: processes
        )

        #expect(result == [473])
    }

    @Test("Ignores a background server and deduplicates clients in one app")
    func ignoresServerAndDeduplicatesHost() {
        let processes = [
            HostProcess(pid: 1, parentPID: 0, executableName: "launchd", isForegroundApplication: false),
            HostProcess(pid: 473, parentPID: 1, executableName: "Terminal", isForegroundApplication: true),
            HostProcess(pid: 609, parentPID: 473, executableName: "login", isForegroundApplication: false),
            HostProcess(pid: 637, parentPID: 609, executableName: "zsh", isForegroundApplication: false),
            HostProcess(pid: 700, parentPID: 609, executableName: "zsh", isForegroundApplication: false),
            HostProcess(pid: 1_947, parentPID: 637, executableName: "herdr", isForegroundApplication: false),
            HostProcess(pid: 1_948, parentPID: 1, executableName: "herdr", isForegroundApplication: false),
            HostProcess(pid: 1_949, parentPID: 700, executableName: "herdr", isForegroundApplication: false),
        ]

        let result = ApplicationHostResolver.applicationProcessIDs(
            hostingExecutableNamed: "herdr",
            in: processes
        )

        #expect(result == [473])
    }

    @Test("Stops safely when ancestry is incomplete or cyclic")
    func handlesInvalidAncestry() {
        let processes = [
            HostProcess(pid: 10, parentPID: 11, executableName: "herdr", isForegroundApplication: false),
            HostProcess(pid: 11, parentPID: 10, executableName: "zsh", isForegroundApplication: false),
            HostProcess(pid: 20, parentPID: 99, executableName: "herdr", isForegroundApplication: false),
        ]

        let result = ApplicationHostResolver.applicationProcessIDs(
            hostingExecutableNamed: "herdr",
            in: processes
        )

        #expect(result.isEmpty)
    }
}
