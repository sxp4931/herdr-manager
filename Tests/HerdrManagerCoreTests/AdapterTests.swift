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

    @Test("Missing data key maps to .ignored")
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
                    "cwd": "/Users/admin/Documents/Herdr Manager",
                    "foreground_cwd": "/Users/admin/Documents/Herdr Manager",
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
