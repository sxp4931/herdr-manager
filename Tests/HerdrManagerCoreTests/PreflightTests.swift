import Foundation
import Testing
@testable import HerdrManagerCore

// MARK: - Stub environment

/// Deterministic preflight environment. No real filesystem, socket, or process.
private struct StubEnvironment: PreflightEnvironment {
    var executable: (path: String, onInheritedPath: Bool)?
    var existingFiles: Set<String> = []
    var protocolVersion: Int?

    func locateExecutable(named name: String) async -> (path: String, onInheritedPath: Bool)? {
        _ = name
        return executable
    }

    func fileExists(atPath path: String) -> Bool {
        existingFiles.contains(path)
    }

    func probeProtocol(socketPath: String) async -> Int? {
        _ = socketPath
        return protocolVersion
    }
}

private let socket = "/tmp/herdr-preflight-test.sock"
private let supported = 17...17

private func runner(_ env: StubEnvironment, range: ClosedRange<Int> = supported) -> PreflightRunner {
    PreflightRunner(environment: env, socketPath: socket, supportedProtocols: range)
}

private func check(_ report: PreflightReport, _ kind: PreflightCheck.Kind) -> PreflightCheck {
    report.checks.first { $0.id == kind }!
}

@Suite("Preflight")
struct PreflightTests {

    @Test("herdr missing entirely fails install check with brew command")
    func herdrMissing() async {
        let env = StubEnvironment()
        let report = await runner(env).run(agentCount: 0)
        let installed = check(report, .herdrInstalled)
        #expect(installed.status == .fail)
        #expect(installed.remedyCommand == "brew install herdr")
        #expect(report.firstUnresolved?.id == .herdrInstalled)
        #expect(!report.allClear)
    }

    @Test("herdr found only via well-known dirs is a warn and does not block later checks")
    func herdrOffInheritedPath() async {
        let path = "/opt/homebrew/bin/herdr"
        let env = StubEnvironment(
            executable: (path, false),
            existingFiles: [socket],
            protocolVersion: 17
        )
        let report = await runner(env).run(agentCount: 2)
        let installed = check(report, .herdrInstalled)
        #expect(installed.status == .warn)
        #expect(installed.detail == path)
        #expect(check(report, .herdrRunning).status == .pass)
        #expect(check(report, .connected).status == .pass)
        #expect(check(report, .protocolSupported).status == .pass)
        #expect(check(report, .agentsVisible).status == .pass)
        #expect(report.firstUnresolved?.id == .herdrInstalled)
        #expect(!report.allClear)
    }

    @Test("herdr on PATH but socket absent fails the running check")
    func socketAbsent() async {
        let env = StubEnvironment(
            executable: ("/opt/homebrew/bin/herdr", true),
            existingFiles: [],
            protocolVersion: nil
        )
        let report = await runner(env).run(agentCount: 0)
        #expect(check(report, .herdrInstalled).status == .pass)
        let running = check(report, .herdrRunning)
        #expect(running.status == .fail)
        #expect(running.detail == socket)
        #expect(report.firstUnresolved?.id == .herdrRunning)
    }

    @Test("socket present but handshake returns nil fails connected")
    func handshakeFails() async {
        let env = StubEnvironment(
            executable: ("/opt/homebrew/bin/herdr", true),
            existingFiles: [socket],
            protocolVersion: nil
        )
        let report = await runner(env).run(agentCount: 0)
        #expect(check(report, .herdrInstalled).status == .pass)
        #expect(check(report, .herdrRunning).status == .pass)
        #expect(check(report, .connected).status == .fail)
        #expect(report.firstUnresolved?.id == .connected)
    }

    @Test("protocol below the supported range is a warn mentioning read-only")
    func protocolBelowRange() async {
        let env = StubEnvironment(
            executable: ("/opt/homebrew/bin/herdr", true),
            existingFiles: [socket],
            protocolVersion: 16
        )
        let report = await runner(env).run(agentCount: 1)
        let proto = check(report, .protocolSupported)
        #expect(proto.status == .warn)
        #expect(proto.status != .fail)
        #expect(proto.explanation?.localizedCaseInsensitiveContains("read-only") == true)
    }

    @Test("protocol above the supported range is a warn mentioning read-only")
    func protocolAboveRange() async {
        let env = StubEnvironment(
            executable: ("/opt/homebrew/bin/herdr", true),
            existingFiles: [socket],
            protocolVersion: 21
        )
        let report = await runner(env, range: 17...20).run(agentCount: 1)
        let proto = check(report, .protocolSupported)
        #expect(proto.status == .warn)
        #expect(proto.status != .fail)
        #expect(proto.explanation?.localizedCaseInsensitiveContains("read-only") == true)
    }

    @Test("everything good with zero agents waits on agentsVisible")
    func zeroAgents() async {
        let env = StubEnvironment(
            executable: ("/opt/homebrew/bin/herdr", true),
            existingFiles: [socket],
            protocolVersion: 17
        )
        let report = await runner(env).run(agentCount: 0)
        #expect(check(report, .herdrInstalled).status == .pass)
        #expect(check(report, .herdrRunning).status == .pass)
        #expect(check(report, .connected).status == .pass)
        #expect(check(report, .protocolSupported).status == .pass)
        #expect(check(report, .agentsVisible).status == .waiting)
        #expect(report.firstUnresolved?.id == .agentsVisible)
        #expect(!report.allClear)
    }

    @Test("everything good with agents is allClear")
    func allClear() async {
        let env = StubEnvironment(
            executable: ("/opt/homebrew/bin/herdr", true),
            existingFiles: [socket],
            protocolVersion: 17
        )
        let report = await runner(env).run(agentCount: 3)
        for kind in PreflightCheck.Kind.allCases {
            #expect(check(report, kind).status == .pass)
        }
        #expect(report.allClear)
        #expect(report.firstUnresolved == nil)
    }
}

@Suite("Settings onboarding flags")
struct SettingsOnboardingFlagTests {

    @Test("encoding hasEverConnected true round-trips")
    func hasEverConnectedRoundTrip() throws {
        var settings = Settings()
        settings.hasEverConnected = true
        settings.dismissedMCPCard = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(decoded.hasEverConnected == true)
        #expect(decoded.dismissedMCPCard == true)
    }

    @Test("omitted keys decode to false and preserve existing fields")
    func omittedKeysDefaultFalse() throws {
        let json = Data(#"""
        {
            "defaultThresholdMinutes": 9,
            "metadataWriteBackEnabled": false,
            "agentOverrides": {"w1:p1": 12}
        }
        """#.utf8)
        let decoded = try JSONDecoder().decode(Settings.self, from: json)
        #expect(decoded.hasEverConnected == false)
        #expect(decoded.dismissedMCPCard == false)
        #expect(decoded.defaultThresholdMinutes == 9)
        #expect(decoded.metadataWriteBackEnabled == false)
        #expect(decoded.agentOverrides["w1:p1"] == 12)
    }
}
