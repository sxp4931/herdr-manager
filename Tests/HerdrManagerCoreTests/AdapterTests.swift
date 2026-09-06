import Foundation
import Testing
@testable import HerdrManagerCore

// MARK: - Protocol-17 Fixtures & Event Envelope

@Suite("HerdrAdapter.parseSnapshot (Protocol 17)")
struct ParseSnapshotTests {

    @Test("Decodes protocol as integer 17")
    func protocolInteger17() throws {
        let json: [String: Any] = [
            "version": "0.1.0",
            "protocol": 17,
            "workspaces": [] as [[String: Any]],
            "tabs": [] as [[String: Any]],
            "panes": [] as [[String: Any]]
        ]
        let snap = try LiveHerdrAdapter.parseSnapshot(json)
        #expect(snap.protocol == 17)
        #expect(snap.version == "0.1.0")
    }

    @Test("Decodes protocol from nested snapshot envelope")
    func nestedSnapshotEnvelope() throws {
        let inner: [String: Any] = [
            "version": "0.2.0",
            "protocol": 17,
            "workspaces": [] as [[String: Any]],
            "tabs": [] as [[String: Any]],
            "panes": [] as [[String: Any]]
        ]
        let outer: [String: Any] = [
            "type": "session_snapshot",
            "snapshot": inner
        ]
        let snap = try LiveHerdrAdapter.parseSnapshot(outer)
        #expect(snap.protocol == 17)
        #expect(snap.version == "0.2.0")
    }

    @Test("Decodes workspaces, tabs, and panes")
    func decodesCollections() throws {
        // Use JSONSerialization to create the dict so integer types match what the parser expects
        let jsonString = """
        {
            "version": "0.1.0",
            "protocol": 17,
            "workspaces": [{"workspace_id": "w1", "label": "Workspace One"}],
            "tabs": [{"tab_id": "t1", "workspace_id": "w1", "label": "Tab One"}],
            "panes": [{
                "pane_id": "w1:p1",
                "workspace_id": "w1",
                "tab_id": "t1",
                "agent": "claude",
                "agent_status": "working",
                "state_change_seq": 42,
                "cwd": "/tmp"
            }],
            "focused_workspace_id": "w1",
            "focused_tab_id": "t1",
            "focused_pane_id": "w1:p1"
        }
        """
        let data = jsonString.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let snap = try LiveHerdrAdapter.parseSnapshot(json)
        #expect(snap.workspaces.count == 1)
        #expect(snap.workspaces.first?.workspaceId == "w1")
        #expect(snap.workspaces.first?.name == "Workspace One")
        #expect(snap.tabs.count == 1)
        #expect(snap.tabs.first?.tabId == "t1")
        #expect(snap.panes.count == 1)
        #expect(snap.panes.first?.paneId == "w1:p1")
        #expect(snap.panes.first?.agentStatus == "working")
        #expect(snap.panes.first?.stateChangeSeq == 42)
        #expect(snap.focusedWorkspaceId == "w1")
        #expect(snap.focusedPaneId == "w1:p1")
    }

    @Test("Missing protocol defaults to 0")
    func missingProtocolDefaultsToZero() throws {
        let json: [String: Any] = [
            "version": "0.1.0",
            "workspaces": [] as [[String: Any]],
            "tabs": [] as [[String: Any]],
            "panes": [] as [[String: Any]]
        ]
        let snap = try LiveHerdrAdapter.parseSnapshot(json)
        #expect(snap.protocol == 0)
    }

    @Test("JSON number protocol and seq survive NSNumber bridging")
    func jsonNumbersDecode() throws {
        let data = Data("""
        {
            "version": "0.1.0",
            "protocol": 17,
            "workspaces": [],
            "tabs": [],
            "panes": [{
                "pane_id": "w1:p1",
                "workspace_id": "w1",
                "tab_id": "t1",
                "agent": "claude",
                "agent_status": "working",
                "state_change_seq": 42,
                "revision": 7
            }]
        }
        """.utf8)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let snap = try LiveHerdrAdapter.parseSnapshot(json)
        #expect(snap.protocol == 17)
        #expect(snap.panes.first?.stateChangeSeq == 42)
        #expect(snap.panes.first?.revision == 7)
    }

    @Test("Malformed collection fields do not throw")
    func malformedCollectionsAreEmpty() throws {
        let json: [String: Any] = [
            "version": "0.1.0",
            "protocol": 17,
            "workspaces": "not-an-array",
            "tabs": 3,
            "panes": ["nope"]
        ]
        let snap = try LiveHerdrAdapter.parseSnapshot(json)
        #expect(snap.protocol == 17)
        #expect(snap.workspaces.isEmpty)
        #expect(snap.tabs.isEmpty)
        #expect(snap.panes.isEmpty)
    }

    @Test("Empty workspace, tab, and pane ids are dropped")
    func emptyIdsAreDropped() throws {
        let json: [String: Any] = [
            "version": "0.1.0",
            "protocol": 17,
            "workspaces": [
                ["workspace_id": "", "label": "ghost"] as [String: Any],
                ["workspace_id": "w1", "label": "real"] as [String: Any]
            ],
            "tabs": [
                ["tab_id": "", "workspace_id": "w1", "label": "ghost"] as [String: Any],
                ["tab_id": "t1", "workspace_id": "w1", "label": "real"] as [String: Any]
            ],
            "panes": [
                [
                    "pane_id": "",
                    "workspace_id": "w1",
                    "tab_id": "t1",
                    "agent": "claude",
                    "agent_status": "working"
                ] as [String: Any],
                [
                    "pane_id": "w1:p1",
                    "workspace_id": "w1",
                    "tab_id": "t1",
                    "agent": "claude",
                    "agent_status": "working"
                ] as [String: Any]
            ]
        ]
        let snap = try LiveHerdrAdapter.parseSnapshot(json)
        #expect(snap.workspaces.map(\.workspaceId) == ["w1"])
        #expect(snap.tabs.map(\.tabId) == ["t1"])
        #expect(snap.panes.map(\.paneId) == ["w1:p1"])
    }

    @Test("Name maps skip empty ids and keep the last duplicate")
    func uniqueNameMapDropsEmptyAndDedupes() {
        let map = HerdrSnapshot.uniqueNameMap([
            ("", "ghost"),
            ("w1", "first"),
            ("w1", "second"),
            ("w2", "other")
        ])
        #expect(map["w1"] == "second")
        #expect(map["w2"] == "other")
        #expect(map[""] == nil)
        #expect(map.count == 2)
    }
}

// MARK: - parseEvent

@Suite("HerdrAdapter.parseEvent")
struct ParseEventTests {

    @Test("pane.agent_status_changed yields agentStatusChanged with pane id and status")
    func agentStatusChanged() throws {
        let jsonString = """
        {
            "event": "pane.agent_status_changed",
            "data": {
                "pane_id": "w5:p2",
                "workspace_id": "w5",
                "agent_status": "blocked",
                "state_change_seq": 7
            }
        }
        """
        let data = jsonString.data(using: .utf8)!
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let event = LiveHerdrAdapter.parseEvent(dict)
        if case .agentStatusChanged(let paneId, let status, let seq) = event {
            #expect(paneId == "w5:p2")
            #expect(status == "blocked")
            #expect(seq == 7)
        } else {
            Issue.record("Expected .agentStatusChanged, got \(event)")
        }
    }

    @Test("pane.created yields paneCreated")
    func paneCreated() {
        let dict: [String: Any] = [
            "event": "pane.created",
            "data": [
                "pane_id": "w1:p9",
                "workspace_id": "w1",
                "tab_id": "t3"
            ] as [String: Any]
        ]
        let event = LiveHerdrAdapter.parseEvent(dict)
        if case .paneCreated(let paneId, let wsId, let tabId) = event {
            #expect(paneId == "w1:p9")
            #expect(wsId == "w1")
            #expect(tabId == "t3")
        } else {
            Issue.record("Expected .paneCreated, got \(event)")
        }
    }

    @Test("pane.closed yields paneClosed")
    func paneClosed() {
        let dict: [String: Any] = [
            "event": "pane.closed",
            "data": ["pane_id": "w1:p1"] as [String: Any]
        ]
        let event = LiveHerdrAdapter.parseEvent(dict)
        if case .paneClosed(let paneId) = event {
            #expect(paneId == "w1:p1")
        } else {
            Issue.record("Expected .paneClosed, got \(event)")
        }
    }

    @Test("Unknown event kind maps to .ignored, NOT .disconnected")
    func unknownEventIsIgnored() {
        let dict: [String: Any] = [
            "event": "totally.new",
            "data": ["foo": "bar"] as [String: Any]
        ]
        let event = LiveHerdrAdapter.parseEvent(dict)
        if case .ignored = event {
            // pass
        } else {
            Issue.record("Expected .ignored for unknown event, got \(event)")
        }
    }

    @Test("Missing event key maps to .ignored")
    func missingEventKeyIsIgnored() {
        let dict: [String: Any] = [
            "data": ["pane_id": "w1:p1"] as [String: Any]
        ]
        let event = LiveHerdrAdapter.parseEvent(dict)
        if case .ignored = event {
            // pass
        } else {
            Issue.record("Expected .ignored when event key missing, got \(event)")
        }
    }

    @Test("Missing data key maps to .ignored when there is no pane_id")
    func missingDataKeyIsIgnored() {
        let dict: [String: Any] = [
            "event": "pane.agent_status_changed"
        ]
        let event = LiveHerdrAdapter.parseEvent(dict)
        if case .ignored = event {
            // pass
        } else {
            Issue.record("Expected .ignored when data key missing, got \(event)")
        }
    }

    @Test("Top-level pane_id without a data envelope still drives pane.closed")
    func flatEventWithoutDataEnvelope() {
        let closed = LiveHerdrAdapter.parseEvent([
            "event": "pane.closed",
            "pane_id": "w1:p1"
        ])
        if case .paneClosed(let paneId) = closed {
            #expect(paneId == "w1:p1")
        } else {
            Issue.record("Expected .paneClosed for flat pane.closed, got \(closed)")
        }

        let status = LiveHerdrAdapter.parseEvent([
            "event": "pane.agent_status_changed",
            "pane_id": "w5:p2",
            "agent_status": "blocked",
            "state_change_seq": 7
        ] as [String: Any])
        if case .agentStatusChanged(let paneId, let agentStatus, let seq) = status {
            #expect(paneId == "w5:p2")
            #expect(agentStatus == "blocked")
            #expect(seq == 7)
        } else {
            Issue.record("Expected .agentStatusChanged for flat status event, got \(status)")
        }
    }

    @Test("Empty pane_id on a pane lifecycle event is ignored")
    func emptyPaneIdIsIgnored() {
        let closed = LiveHerdrAdapter.parseEvent([
            "event": "pane.closed",
            "data": ["pane_id": ""] as [String: Any]
        ])
        if case .ignored = closed {
            // pass
        } else {
            Issue.record("Expected .ignored for empty pane_id, got \(closed)")
        }

        let updated = LiveHerdrAdapter.parseEvent([
            "event": "pane_updated",
            "data": [
                "pane": [
                    "pane_id": "",
                    "agent": "claude",
                    "agent_status": "working"
                ] as [String: Any]
            ] as [String: Any]
        ])
        if case .ignored = updated {
            // pass
        } else {
            Issue.record("Expected .ignored for empty pane_updated pane_id, got \(updated)")
        }
    }

    // MARK: - Real herdr wire format (underscored names, Bug 2)

    @Test("pane_updated (real wire format) yields .paneUpdated with full agent info")
    func paneUpdatedRealWireFormat() throws {
        let jsonString = """
        {
            "event": "pane_updated",
            "data": {
                "type": "pane_updated",
                "pane": {
                    "pane_id": "wE:p5",
                    "terminal_id": "term_1",
                    "workspace_id": "wE",
                    "tab_id": "wE:t3",
                    "focused": false,
                    "cwd": "/workspace/herdr-manager",
                    "foreground_cwd": "/workspace/herdr-manager",
                    "agent": "codex",
                    "terminal_title": "[ . ] Action Required | Herdr Manager",
                    "terminal_title_stripped": "Action Required | Herdr Manager",
                    "agent_status": "blocked",
                    "agent_session": {"source": "herdr:codex", "agent": "codex", "kind": "id", "value": "019f"},
                    "tokens": {"stuck_for": "3m"},
                    "state_change_seq": 507,
                    "revision": 507
                }
            }
        }
        """
        let data = jsonString.data(using: .utf8)!
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let event = LiveHerdrAdapter.parseEvent(dict)
        if case .paneUpdated(let info) = event {
            #expect(info.paneId == "wE:p5")
            #expect(info.agentStatus == "blocked")
            #expect(info.stateChangeSeq == 507)
            #expect(info.agent == "codex")
            #expect(info.workspaceId == "wE")
            #expect(info.tabId == "wE:t3")
        } else {
            Issue.record("Expected .paneUpdated, got \(event)")
        }
    }

    @Test("pane_closed (real wire format) yields .paneClosed")
    func paneClosedRealWireFormat() {
        let dict: [String: Any] = [
            "event": "pane_closed",
            "data": ["type": "pane_closed", "pane_id": "wE:p4", "workspace_id": "wE"] as [String: Any]
        ]
        let event = LiveHerdrAdapter.parseEvent(dict)
        if case .paneClosed(let paneId) = event {
            #expect(paneId == "wE:p4")
        } else {
            Issue.record("Expected .paneClosed, got \(event)")
        }
    }

    @Test("pane_focused (real wire format) yields .paneFocused")
    func paneFocusedRealWireFormat() {
        let dict: [String: Any] = [
            "event": "pane_focused",
            "data": ["type": "pane_focused", "pane_id": "wE:p5", "workspace_id": "wE"] as [String: Any]
        ]
        let event = LiveHerdrAdapter.parseEvent(dict)
        if case .paneFocused(let paneId, let wsId) = event {
            #expect(paneId == "wE:p5")
            #expect(wsId == "wE")
        } else {
            Issue.record("Expected .paneFocused, got \(event)")
        }
    }

    @Test("pane_exited (real wire format) yields .paneExited")
    func paneExitedRealWireFormat() {
        let dict: [String: Any] = [
            "event": "pane_exited",
            "data": ["type": "pane_exited", "pane_id": "wE:p6", "workspace_id": "wE"] as [String: Any]
        ]
        let event = LiveHerdrAdapter.parseEvent(dict)
        if case .paneExited(let paneId) = event {
            #expect(paneId == "wE:p6")
        } else {
            Issue.record("Expected .paneExited, got \(event)")
        }
    }

    @Test("workspace_focused (real wire format) yields .workspacesChanged")
    func workspaceFocusedRealWireFormat() {
        let dict: [String: Any] = [
            "event": "workspace_focused",
            "data": ["type": "workspace_focused", "workspace_id": "wE"] as [String: Any]
        ]
        let event = LiveHerdrAdapter.parseEvent(dict)
        if case .workspacesChanged = event {
            // pass
        } else {
            Issue.record("Expected .workspacesChanged, got \(event)")
        }
    }

    @Test("Dotted pane.updated (subscribe-type spelling) yields .paneUpdated")
    func dottedPaneUpdated() throws {
        let jsonString = """
        {
            "event": "pane.updated",
            "data": {
                "pane": {
                    "pane_id": "wE:p5",
                    "workspace_id": "wE",
                    "tab_id": "wE:t3",
                    "agent": "codex",
                    "agent_status": "working",
                    "state_change_seq": 12
                }
            }
        }
        """
        let data = jsonString.data(using: .utf8)!
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let event = LiveHerdrAdapter.parseEvent(dict)
        if case .paneUpdated(let info) = event {
            #expect(info.paneId == "wE:p5")
            #expect(info.agentStatus == "working")
            #expect(info.stateChangeSeq == 12)
        } else {
            Issue.record("Expected .paneUpdated for dotted pane.updated, got \(event)")
        }
    }

    @Test("Dotted pane.updated with a flat data payload still parses")
    func dottedPaneUpdatedFlat() {
        let dict: [String: Any] = [
            "event": "pane.updated",
            "data": [
                "pane_id": "w1:p1",
                "workspace_id": "w1",
                "tab_id": "t1",
                "agent": "claude",
                "agent_status": "blocked",
                "state_change_seq": 3
            ] as [String: Any]
        ]
        let event = LiveHerdrAdapter.parseEvent(dict)
        if case .paneUpdated(let info) = event {
            #expect(info.paneId == "w1:p1")
            #expect(info.agentStatus == "blocked")
            #expect(info.stateChangeSeq == 3)
        } else {
            Issue.record("Expected .paneUpdated for flat dotted pane.updated, got \(event)")
        }
    }

    @Test("Dotted pane.focused / pane.exited / workspace.focused match subscribe types")
    func dottedLifecycleEvents() {
        let focused = LiveHerdrAdapter.parseEvent([
            "event": "pane.focused",
            "data": ["pane_id": "w1:p1", "workspace_id": "w1"] as [String: Any]
        ])
        if case .paneFocused(let paneId, let wsId) = focused {
            #expect(paneId == "w1:p1")
            #expect(wsId == "w1")
        } else {
            Issue.record("Expected .paneFocused, got \(focused)")
        }

        let exited = LiveHerdrAdapter.parseEvent([
            "event": "pane.exited",
            "data": ["pane_id": "w1:p2"] as [String: Any]
        ])
        if case .paneExited(let paneId) = exited {
            #expect(paneId == "w1:p2")
        } else {
            Issue.record("Expected .paneExited, got \(exited)")
        }

        let ws = LiveHerdrAdapter.parseEvent([
            "event": "workspace.focused",
            "data": ["workspace_id": "w1"] as [String: Any]
        ])
        if case .workspacesChanged = ws {
            // pass
        } else {
            Issue.record("Expected .workspacesChanged, got \(ws)")
        }
    }

    @Test("Genuinely unknown underscored event name still maps to .ignored")
    func unknownUnderscoredEventIsIgnored() {
        let dict: [String: Any] = [
            "event": "totally_new_underscored_event",
            "data": ["foo": "bar"] as [String: Any]
        ]
        let event = LiveHerdrAdapter.parseEvent(dict)
        if case .ignored = event {
            // pass
        } else {
            Issue.record("Expected .ignored for unknown underscored event, got \(event)")
        }
    }
}

// MARK: - agent.list parsing (Bug 4)

@Suite("HerdrAdapter.parseAgentList")
struct ParseAgentListTests {

    @Test("Produces HerdrAgentInfo with non-zero state_change_seq")
    func nonZeroStateChangeSeq() throws {
        let jsonString = """
        {
            "type": "agent_list",
            "agents": [
                {
                    "pane_id": "wA:p1", "workspace_id": "wA", "tab_id": "wA:t1",
                    "terminal_id": "term_1", "agent": "claude", "display_agent": "Claude",
                    "name": null, "title": "Claude", "terminal_title_stripped": "Claude",
                    "agent_status": "working", "focused": true, "state_change_seq": 12,
                    "revision": 3, "interactive_ready": true, "launch_pending": false
                }
            ]
        }
        """
        let data = jsonString.data(using: .utf8)!
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let agents = LiveHerdrAdapter.parseAgentList(dict)
        #expect(agents.count == 1)
        #expect(agents.first?.paneId == "wA:p1")
        #expect(agents.first?.stateChangeSeq == 12)
        #expect((agents.first?.stateChangeSeq ?? 0) > 0)
    }

    @Test("Drops entries with no agent (plain shells)")
    func dropsShellEntries() throws {
        let jsonString = """
        {
            "type": "agent_list",
            "agents": [
                {
                    "pane_id": "wA:p1", "workspace_id": "wA", "tab_id": "wA:t1",
                    "terminal_id": "term_1", "agent": "claude",
                    "agent_status": "working", "focused": true, "state_change_seq": 5, "revision": 1
                },
                {
                    "pane_id": "wA:p2", "workspace_id": "wA", "tab_id": "wA:t1",
                    "terminal_id": "term_2", "agent": null,
                    "agent_status": "unknown", "focused": false, "state_change_seq": 0, "revision": 1
                }
            ]
        }
        """
        let data = jsonString.data(using: .utf8)!
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let agents = LiveHerdrAdapter.parseAgentList(dict)
        #expect(agents.count == 1)
        #expect(agents.first?.paneId == "wA:p1")
    }

    @Test("Drops entries with an empty pane_id")
    func dropsEmptyPaneId() throws {
        let jsonString = """
        {
            "type": "agent_list",
            "agents": [
                {
                    "pane_id": "", "workspace_id": "wA", "tab_id": "wA:t1",
                    "agent": "claude", "agent_status": "working",
                    "state_change_seq": 5, "revision": 1
                },
                {
                    "pane_id": "wA:p1", "workspace_id": "wA", "tab_id": "wA:t1",
                    "agent": "claude", "agent_status": "working",
                    "state_change_seq": 5, "revision": 1
                }
            ]
        }
        """
        let data = jsonString.data(using: .utf8)!
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let agents = LiveHerdrAdapter.parseAgentList(dict)
        #expect(agents.count == 1)
        #expect(agents.first?.paneId == "wA:p1")
    }
}

// MARK: - Subscription params builder (Bug 1)

@Suite("LiveHerdrAdapter.globalSubscriptionTypes")
struct SubscriptionParamsTests {

    @Test("No emitted subscription type requires pane_id")
    func noPaneScopedSubscriptionTypes() {
        let paneScopedTypes: Set<String> = [
            "pane.agent_status_changed", "pane.scroll_changed", "pane.output_matched"
        ]
        for type in LiveHerdrAdapter.globalSubscriptionTypes {
            #expect(!paneScopedTypes.contains(type), "\(type) requires pane_id and must not be globally subscribed")
        }
    }

    @Test("Subscription list is non-empty and includes pane.updated")
    func includesPaneUpdated() {
        #expect(LiveHerdrAdapter.globalSubscriptionTypes.contains("pane.updated"))
        #expect(!LiveHerdrAdapter.globalSubscriptionTypes.isEmpty)
    }
}

// MARK: - agent.focus params (Bug 3)

@Suite("LiveHerdrAdapter.focusParams")
struct FocusParamsTests {

    @Test("Builds params keyed 'target', not 'pane_id'")
    func usesTargetKey() {
        let params = LiveHerdrAdapter.focusParams(paneId: "w1:p2")
        #expect(params["target"] as? String == "w1:p2")
        #expect(params["pane_id"] == nil)
    }
}

@Suite("LiveHerdrAdapter prompt submission")
struct PromptSubmissionTests {

    @Test("Nudge text uses bracketed-paste-aware pane input")
    func textRequest() {
        let params = LiveHerdrAdapter.promptTextParams(
            paneId: "wE:p5", text: "Run the focused tests"
        )
        #expect(params["pane_id"] as? String == "wE:p5")
        #expect(params["text"] as? String == "Run the focused tests")
        #expect(params["target"] == nil)
    }

    @Test("Nudge submission sends Enter as a separate agent key event")
    func enterRequest() {
        let params = LiveHerdrAdapter.promptEnterParams(paneId: "wE:p5")
        #expect(params["target"] as? String == "wE:p5")
        #expect(params["keys"] as? [String] == ["enter"])
        #expect(params["pane_id"] == nil)
    }
}

// MARK: - WorkspaceCreation decoding

@Suite("WorkspaceCreation Codable")
struct WorkspaceCreationTests {

    @Test("Round-trip encode/decode")
    func roundTrip() throws {
        let original = WorkspaceCreation(workspaceId: "w9", rootPaneId: "w9:p3", tabId: "t1")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkspaceCreation.self, from: data)
        #expect(decoded == original)
        #expect(decoded.workspaceId == "w9")
        #expect(decoded.rootPaneId == "w9:p3")
        #expect(decoded.tabId == "t1")
    }

    @Test("Decodes from workspace.create response shape")
    func decodeFromResponseShape() throws {
        // This is the shape herdr returns for workspace.create
        let response: [String: Any] = [
            "type": "workspace_created",
            "workspace": ["workspace_id": "w9"],
            "tab": ["tab_id": "t1"],
            "root_pane": ["pane_id": "w9:p3"]
        ]
        // We can't directly test LiveHerdrAdapter.createWorkspace without a socket,
        // but we can verify the WorkspaceCreation type decodes the expected fields.
        let wsId = (response["workspace"] as? [String: Any])?["workspace_id"] as? String
        let tabId = (response["tab"] as? [String: Any])?["tab_id"] as? String
        let rootPaneId = (response["root_pane"] as? [String: Any])?["pane_id"] as? String

        let creation = WorkspaceCreation(
            workspaceId: wsId ?? "",
            rootPaneId: rootPaneId ?? "",
            tabId: tabId
        )
        #expect(creation.workspaceId == "w9")
        #expect(creation.rootPaneId == "w9:p3")
        #expect(creation.tabId == "t1")
    }

    @Test("tabId is optional")
    func tabIdOptional() throws {
        let creation = WorkspaceCreation(workspaceId: "w1", rootPaneId: "w1:p1")
        #expect(creation.tabId == nil)
    }
}

// MARK: - Response Envelopes

/// Live herdr nests these results one level below the response envelope.
/// Reading the fields off the envelope silently produced empty text (blank
/// Peek) and a nil shell pid (dead process-gone diagnosis), so the nesting is
/// pinned here against the real protocol-17 shapes.
@Suite("HerdrAdapter response envelopes")
struct ResponseEnvelopeTests {

    @Test("pane.read unwraps the nested `read` object")
    func paneReadNested() throws {
        let response: [String: Any] = [
            "type": "pane_read",
            "read": [
                "pane_id": "wE:p5",
                "workspace_id": "wE",
                "tab_id": "wE:t3",
                "source": "detection",
                "format": "text",
                "text": "line one\nline two",
                "revision": 609,
                "truncated": false
            ] as [String: Any]
        ]
        let result = LiveHerdrAdapter.parsePaneRead(response, requested: .detection)
        #expect(result.text == "line one\nline two")
        #expect(result.source == "detection")
    }

    @Test("pane.read still accepts a flat result")
    func paneReadFlat() throws {
        let response: [String: Any] = ["text": "flat", "source": "recent"]
        let result = LiveHerdrAdapter.parsePaneRead(response, requested: .detection)
        #expect(result.text == "flat")
        #expect(result.source == "recent")
    }

    @Test("pane.read falls back to the requested source when absent")
    func paneReadSourceFallback() throws {
        let result = LiveHerdrAdapter.parsePaneRead(["read": [String: Any]()], requested: .recent)
        #expect(result.text.isEmpty)
        #expect(result.source == "recent")
    }

    @Test("pane.process_info unwraps the nested `process_info` object")
    func processInfoNested() throws {
        let response: [String: Any] = [
            "type": "pane_process_info",
            "process_info": [
                "pane_id": "wE:p5",
                "shell_pid": 71997,
                "foreground_processes": [
                    [
                        "pid": 72004,
                        "name": "codex",
                        "argv0": "codex",
                        "cmdline": "codex",
                        "cwd": "/workspace/herdr-manager"
                    ] as [String: Any]
                ]
            ] as [String: Any]
        ]
        let info = LiveHerdrAdapter.parseProcessInfo(response)
        #expect(info.shellPid == 71997)
        #expect(info.foregroundProcesses.count == 1)
        #expect(info.foregroundProcesses.first?.pid == 72004)
        #expect(info.foregroundProcesses.first?.name == "codex")
    }

    @Test("pane.process_info still accepts a flat result")
    func processInfoFlat() throws {
        let response: [String: Any] = ["shell_pid": 42, "foreground_processes": [[String: Any]]()]
        let info = LiveHerdrAdapter.parseProcessInfo(response)
        #expect(info.shellPid == 42)
        #expect(info.foregroundProcesses.isEmpty)
    }
}

@Suite("LiveHerdrAdapter pane reads and splits")
struct PaneReadAndSplitTests {

    @Test("Bounded pane read includes the requested line count")
    func boundedReadParams() {
        let params = LiveHerdrAdapter.readParams(
            paneId: "wE:p5", source: .detection, lines: 20
        )
        #expect(params["pane_id"] as? String == "wE:p5")
        #expect(params["source"] as? String == "detection")
        #expect(params["lines"] as? Int == 20)
    }

    @Test("Unbounded pane read omits line count")
    func unboundedReadParams() {
        let params = LiveHerdrAdapter.readParams(
            paneId: "wE:p5", source: .recent, lines: nil
        )
        #expect(params["lines"] == nil)
    }

    @Test("pane.split targets an existing pane and focuses the result")
    func splitParams() {
        let params = LiveHerdrAdapter.splitPaneParams(
            targetPaneId: "wE:p1", cwd: "/tmp/project"
        )
        #expect(params["target_pane_id"] as? String == "wE:p1")
        #expect(params["direction"] as? String == "right")
        #expect(params["focus"] as? Bool == true)
        #expect(params["cwd"] as? String == "/tmp/project")
    }

    @Test("pane.split unwraps the returned pane_info envelope")
    func splitResponse() throws {
        let response: [String: Any] = [
            "type": "pane_info",
            "pane": [
                "pane_id": "wE:p9",
                "workspace_id": "wE",
                "tab_id": "wE:t1"
            ] as [String: Any]
        ]
        let paneId = try LiveHerdrAdapter.parsePaneInfoID(response)
        #expect(paneId == "wE:p9")
    }
}

@Suite("herdr socket resolution guidance")
struct HerdrSocketGuidanceTests {
    @Test("Missing-socket copy names the resolved path and HERDR_SOCKET_PATH")
    func missingSocketMentionsOverride() {
        let path = "/tmp/custom/herdr.sock"
        let message = LiveHerdrAdapter.missingSocketMessage(resolvedPath: path)
        #expect(message.contains(path))
        #expect(message.contains("HERDR_SOCKET_PATH"))
        #expect(message.contains("HERDR_SESSION"))
        #expect(message.contains("--socket"))
        #expect(message.contains("herdr.dev"))
    }

    @Test("Socket hint names the resolved path and HERDR_SOCKET_PATH")
    func socketHintMentionsOverride() {
        let path = "/tmp/custom/herdr.sock"
        let hint = LiveHerdrAdapter.socketHint(resolvedPath: path)
        #expect(hint.contains(path))
        #expect(hint.contains("HERDR_SOCKET_PATH"))
        #expect(hint.contains("HERDR_SESSION"))
        #expect(hint.contains("--socket"))
        #expect(LiveHerdrAdapter.missingSocketMessage(resolvedPath: path).contains(hint))
    }

    @Test("Protocol status line is quiet on the verified protocol and names others")
    func protocolStatusLine() {
        let verified = LiveHerdrAdapter.health(
            forProtocol: LiveHerdrAdapter.minSupportedProtocolVersion
        )
        #expect(LiveHerdrAdapter.protocolStatusLine(for: verified) == nil)

        let older = LiveHerdrAdapter.health(forProtocol: 16)
        let olderLine = LiveHerdrAdapter.protocolStatusLine(for: older)
        #expect(olderLine?.contains("16") == true)
        #expect(olderLine?.contains("older") == true)

        let unknown = LiveHerdrAdapter.health(forProtocol: 0)
        #expect(LiveHerdrAdapter.protocolStatusLine(for: unknown)?.contains("unknown") == true)
    }
}

@Suite("AdapterHealth capability gate")
struct AdapterHealthTests {
    @Test("Unknown protocol disables writes with a stable reason")
    func unknownProtocol() {
        let health = LiveHerdrAdapter.health(forProtocol: 0)
        #expect(health.protocolVersion == 0)
        #expect(health.compatible == false)
        #expect(health.writesEnabled == false)
        #expect(health.reason == "protocol unknown")
    }

    @Test("Verified protocol enables writes")
    func verifiedProtocol() {
        let health = LiveHerdrAdapter.health(
            forProtocol: LiveHerdrAdapter.minSupportedProtocolVersion
        )
        #expect(health.compatible)
        #expect(health.writesEnabled)
        #expect(health.reason == nil)
    }

    @Test("Older protocol keeps reads conceptually but disables writes")
    func olderProtocol() {
        let health = LiveHerdrAdapter.health(forProtocol: 16)
        #expect(health.protocolVersion == 16)
        #expect(health.compatible == false)
        #expect(health.writesEnabled == false)
        #expect(health.reason?.contains("older") == true)
        #expect(health.reason?.contains("writes disabled") == true)
        #expect(health.reason?.contains("16") == true)
    }

    @Test("Newer protocol stays writable so a herdr bump does not lock the herd")
    func newerProtocol() {
        let health = LiveHerdrAdapter.health(forProtocol: 18)
        #expect(health.compatible)
        #expect(health.writesEnabled)
        #expect(health.reason?.contains("newer") == true)
        #expect(health.reason?.contains("18") == true)
    }

    @Test("Negative protocol is unknown, not an 'older' version")
    func negativeProtocolIsUnknown() {
        let health = LiveHerdrAdapter.health(forProtocol: -1)
        #expect(health.protocolVersion == -1)
        #expect(health.compatible == false)
        #expect(health.writesEnabled == false)
        #expect(health.reason == "protocol unknown")
    }

    @Test("supportedProtocolRange starts at the verified baseline")
    func supportedRange() {
        #expect(LiveHerdrAdapter.supportedProtocolRange.lowerBound == 17)
        #expect(LiveHerdrAdapter.supportedProtocolRange.contains(17))
        #expect(LiveHerdrAdapter.supportedProtocolRange.contains(99))
        #expect(!LiveHerdrAdapter.supportedProtocolRange.contains(16))
    }
}

@Suite("Subscription line decode failures")
struct SubscriptionLineDecodeTests {
    @Test("Valid pane_updated line yields an event")
    func validLine() throws {
        let data = Data(#"""
        {"event":"pane_updated","data":{"type":"pane_updated","pane":{"pane_id":"wE:p5","workspace_id":"wE","tab_id":"wE:t3","agent":"codex","agent_status":"blocked","state_change_seq":9}}}
        """#.utf8)
        let event = LiveHerdrAdapter.event(fromSubscriptionLine: data)
        guard case .paneUpdated(let info)? = event else {
            Issue.record("Expected paneUpdated, got \(String(describing: event))")
            return
        }
        #expect(info.paneId == "wE:p5")
        #expect(info.agentStatus == "blocked")
        #expect(info.stateChangeSeq == 9)
    }

    @Test("Invalid JSON is dropped instead of thrown")
    func invalidJSONIsDropped() {
        #expect(LiveHerdrAdapter.event(fromSubscriptionLine: Data("not-json".utf8)) == nil)
        #expect(LiveHerdrAdapter.event(fromSubscriptionLine: Data()) == nil)
        #expect(LiveHerdrAdapter.event(fromSubscriptionLine: Data("[1,2,3]".utf8)) == nil)
    }

    @Test("Unknown event kind is ignored, not treated as a disconnect")
    func unknownEventIsIgnored() {
        let data = Data(#"""
        {"event":"totally.new","data":{"foo":"bar"}}
        """#.utf8)
        let event = LiveHerdrAdapter.event(fromSubscriptionLine: data)
        guard case .ignored? = event else {
            Issue.record("Expected ignored, got \(String(describing: event))")
            return
        }
    }

    @Test("type/data envelope parses the same as event/data")
    func typeDataEnvelope() {
        let data = Data(#"""
        {"type":"pane_updated","data":{"pane":{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"t1","agent":"claude","agent_status":"working","state_change_seq":4}}}
        """#.utf8)
        let event = LiveHerdrAdapter.event(fromSubscriptionLine: data)
        guard case .paneUpdated(let info)? = event else {
            Issue.record("Expected paneUpdated, got \(String(describing: event))")
            return
        }
        #expect(info.paneId == "w1:p1")
        #expect(info.agentStatus == "working")
        #expect(info.stateChangeSeq == 4)
    }
}

@Suite("JSONNumber")
struct JSONNumberTests {
    @Test("Accepts Int, NSNumber, whole Double, and decimal strings")
    func intShapes() throws {
        #expect(JSONNumber.int(17) == 17)
        #expect(JSONNumber.int(Int64(17)) == 17)
        #expect(JSONNumber.int(NSNumber(value: 17)) == 17)
        #expect(JSONNumber.int(17.0) == 17)
        #expect(JSONNumber.int("17") == 17)
        #expect(JSONNumber.int(" 17 ") == 17)
        #expect(JSONNumber.int(17.5) == nil)
        #expect(JSONNumber.int("nope") == nil)
        #expect(JSONNumber.int(nil) == nil)
        #expect(JSONNumber.int(true) == nil)
        #expect(JSONNumber.int(false) == nil)
        let jsonTrue = try JSONSerialization.jsonObject(with: Data("true".utf8))
        let jsonFalse = try JSONSerialization.jsonObject(with: Data("false".utf8))
        #expect(JSONNumber.int(jsonTrue) == nil)
        #expect(JSONNumber.int(jsonFalse) == nil)
        #expect(JSONNumber.uint64(true) == nil)
        #expect(JSONNumber.uint64(jsonTrue) == nil)

        let jsonHalf = try JSONSerialization.jsonObject(with: Data("17.5".utf8))
        #expect(JSONNumber.int(jsonHalf) == nil)
        #expect(JSONNumber.uint64(jsonHalf) == nil)
        #expect(!JSONNumber.matchesStringId(jsonHalf, expected: "17"))
        let jsonWhole = try JSONSerialization.jsonObject(with: Data("17".utf8))
        #expect(JSONNumber.int(jsonWhole) == 17)
        #expect(JSONNumber.uint64(jsonWhole) == 17)
        #expect(JSONNumber.int(NSNumber(value: 17.5)) == nil)
        #expect(JSONNumber.uint64(NSNumber(value: 17.5)) == nil)
    }

    @Test("uint64 rejects negatives and non-integers")
    func uint64Shapes() {
        #expect(JSONNumber.uint64(42) == 42)
        #expect(JSONNumber.uint64(NSNumber(value: 42)) == 42)
        #expect(JSONNumber.uint64(42.0) == 42)
        #expect(JSONNumber.uint64(-1) == nil)
        #expect(JSONNumber.uint64(NSNumber(value: -3)) == nil)
        #expect(JSONNumber.uint64("9") == 9)
    }

    @Test("JSON-RPC response ids match as string or number")
    func responseIdMatch() {
        #expect(JSONNumber.matchesStringId("1", expected: "1"))
        #expect(JSONNumber.matchesStringId(1, expected: "1"))
        #expect(JSONNumber.matchesStringId(NSNumber(value: 1), expected: "1"))
        #expect(JSONNumber.matchesStringId(1.0, expected: "1"))
        #expect(!JSONNumber.matchesStringId(2, expected: "1"))
        #expect(!JSONNumber.matchesStringId("2", expected: "1"))
        #expect(!JSONNumber.matchesStringId(nil, expected: "1"))
        #expect(!JSONNumber.matchesStringId(["id": 1], expected: "1"))
        #expect(!JSONNumber.matchesStringId(true, expected: "1"))
    }
}

@Suite("NDJSONFraming")
struct NDJSONFramingTests {
    @Test("Returns a complete line and leaves the remainder")
    func completeLine() {
        var buffer = Data("{\"a\":1}\n{\"b\":2}\n".utf8)
        var skipping = false
        let first = NDJSONFraming.consume(buffer: &buffer, skipping: &skipping, maxBytes: 64)
        guard case .line(let line) = first else {
            Issue.record("Expected line, got \(first)")
            return
        }
        #expect(String(data: line, encoding: .utf8) == "{\"a\":1}\n")
        #expect(skipping == false)
        let second = NDJSONFraming.consume(buffer: &buffer, skipping: &skipping, maxBytes: 64)
        guard case .line(let line2) = second else {
            Issue.record("Expected second line, got \(second)")
            return
        }
        #expect(String(data: line2, encoding: .utf8) == "{\"b\":2}\n")
        #expect(buffer.isEmpty)
    }

    @Test("Asks for more data when the line is incomplete")
    func needMore() {
        var buffer = Data("{\"partial\"".utf8)
        var skipping = false
        let outcome = NDJSONFraming.consume(buffer: &buffer, skipping: &skipping, maxBytes: 64)
        #expect(outcome == .needMore)
        #expect(buffer.count == 10)
        #expect(skipping == false)
    }

    @Test("Drops a complete oversized line and keeps the next frame aligned")
    func skipsCompleteOversizedLine() {
        var buffer = Data("abcdefghij\nkeep\n".utf8)
        var skipping = false
        let skipped = NDJSONFraming.consume(buffer: &buffer, skipping: &skipping, maxBytes: 8)
        #expect(skipped == .skippedOversized)
        #expect(skipping == false)
        let kept = NDJSONFraming.consume(buffer: &buffer, skipping: &skipping, maxBytes: 8)
        guard case .line(let line) = kept else {
            Issue.record("Expected kept line, got \(kept)")
            return
        }
        #expect(String(data: line, encoding: .utf8) == "keep\n")
    }

    @Test("Drains an oversized line that spans chunks without retaining it")
    func drainsPartialOversizedLine() {
        var buffer = Data("xxxxxxxxxxxxxxxx".utf8)
        var skipping = false
        let first = NDJSONFraming.consume(buffer: &buffer, skipping: &skipping, maxBytes: 8)
        #expect(first == .stillSkipping)
        #expect(skipping)
        #expect(buffer.isEmpty)

        buffer.append(contentsOf: Data("yyyy\nnext\n".utf8))
        let drained = NDJSONFraming.consume(buffer: &buffer, skipping: &skipping, maxBytes: 8)
        #expect(drained == .skippedOversized)
        #expect(skipping == false)
        let next = NDJSONFraming.consume(buffer: &buffer, skipping: &skipping, maxBytes: 8)
        guard case .line(let line) = next else {
            Issue.record("Expected next line, got \(next)")
            return
        }
        #expect(String(data: line, encoding: .utf8) == "next\n")
    }
}
