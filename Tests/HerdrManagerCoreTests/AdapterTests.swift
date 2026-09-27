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
        #expect(snap.panes.first?.label == nil)
    }

    @Test("A pane rename is the label, and an empty one is a clear")
    func paneRenameLabel() throws {
        let jsonString = """
        {
            "version": "0.1.0",
            "protocol": 17,
            "workspaces": [],
            "tabs": [],
            "panes": [
                {"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "t1", "agent_status": "working", "label": "api"},
                {"pane_id": "w1:p2", "workspace_id": "w1", "tab_id": "t1", "agent_status": "idle", "label": ""},
                {"pane_id": "w1:p3", "workspace_id": "w1", "tab_id": "t1", "agent_status": "idle", "label": " "},
                {"pane_id": "w1:p1", "workspace_id": "w1", "tab_id": "t1", "agent_status": "working", "label": "web"}
            ]
        }
        """
        let data = jsonString.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let snap = try LiveHerdrAdapter.parseSnapshot(json)
        let indexed = LiveHerdrAdapter.paneLabelIndex(in: snap.panes)
        #expect(indexed.ids == Set(["w1:p1", "w1:p2", "w1:p3"]))
        #expect(indexed.labels["w1:p1"] == "web")
        #expect(indexed.labels["w1:p2"] == nil)
        #expect(indexed.labels["w1:p3"] == " ")

        let updated = LiveHerdrAdapter.parseEvent([
            "event": "pane_updated",
            "data": [
                "type": "pane_updated",
                "pane": [
                    "pane_id": "w1:p1",
                    "workspace_id": "w1",
                    "tab_id": "t1",
                    "agent": "claude",
                    "agent_status": "working",
                    "label": "api"
                ] as [String: Any]
            ] as [String: Any]
        ])
        guard case .paneUpdated(let info) = updated else {
            Issue.record("Expected pane_updated, got \(updated)")
            return
        }
        #expect(info.paneLabel == "api")

        let cleared = LiveHerdrAdapter.parseEvent([
            "event": "pane.updated",
            "data": [
                "pane": [
                    "pane_id": "w1:p1",
                    "agent": "claude",
                    "agent_status": "working",
                    "label": ""
                ] as [String: Any]
            ] as [String: Any]
        ])
        guard case .paneUpdated(let empty) = cleared else {
            Issue.record("Expected pane_updated, got \(cleared)")
            return
        }
        #expect(empty.paneLabel == nil)
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

    @Test("workspace_renamed and tab_renamed carry the new label")
    func renameEventsCarryTheLabel() throws {
        let workspace = """
        {"event":"workspace_renamed","data":{"type":"workspace_renamed","workspace_id":"wA","label":"Proj"}}
        """
        let workspaceEvent = LiveHerdrAdapter.parseEvent(
            try JSONSerialization.jsonObject(with: Data(workspace.utf8)) as! [String: Any]
        )
        if case .workspaceRenamed(let id, let label) = workspaceEvent {
            #expect(id == "wA")
            #expect(label == "Proj")
        } else {
            Issue.record("Expected .workspaceRenamed, got \(workspaceEvent)")
        }

        let tab = """
        {"event":"tab.renamed","data":{"tab_id":"wA:t9","workspace_id":"wA","label":"suite"}}
        """
        let tabEvent = LiveHerdrAdapter.parseEvent(
            try JSONSerialization.jsonObject(with: Data(tab.utf8)) as! [String: Any]
        )
        if case .tabRenamed(let id, let label) = tabEvent {
            #expect(id == "wA:t9")
            #expect(label == "suite")
        } else {
            Issue.record("Expected .tabRenamed, got \(tabEvent)")
        }

        let empty = LiveHerdrAdapter.parseEvent([
            "event": "workspace_renamed",
            "data": ["workspace_id": "wA", "label": ""] as [String: Any]
        ])
        if case .ignored = empty {
            // An empty label must not become a refetch either.
        } else {
            Issue.record("Expected .ignored for an empty rename label, got \(empty)")
        }
    }

    @Test("workspace_focused is not a layout change")
    func workspaceFocusedIsNotALayoutChange() {
        let dict: [String: Any] = [
            "event": "workspace_focused",
            "data": ["type": "workspace_focused", "workspace_id": "wE"] as [String: Any]
        ]
        let event = LiveHerdrAdapter.parseEvent(dict)
        guard case .ignored = event else {
            Issue.record("Expected .ignored for workspace_focused, got \(event)")
            return
        }

        let created = LiveHerdrAdapter.parseEvent([
            "event": "workspace_created",
            "data": ["workspace_id": "wE", "label": "proj"] as [String: Any]
        ])
        guard case .workspacesChanged = created else {
            Issue.record("Expected .workspacesChanged for workspace_created, got \(created)")
            return
        }

        let tab = LiveHerdrAdapter.parseEvent([
            "event": "tab.focused",
            "data": ["tab_id": "wE:t1", "workspace_id": "wE"] as [String: Any]
        ])
        guard case .ignored = tab else {
            Issue.record("Expected .ignored for tab.focused, got \(tab)")
            return
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

    @Test("Dotted pane.focused and pane.exited parse, and workspace.focused does not refetch")
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
        guard case .ignored = ws else {
            Issue.record("Expected .ignored for workspace.focused, got \(ws)")
            return
        }
    }

    @Test("pane_moved carries the previous id, the new pane, and a created workspace label")
    func paneMovedRealWireFormat() throws {
        let jsonString = """
        {
            "event": "pane_moved",
            "data": {
                "type": "pane_moved",
                "previous_pane_id": "wA:p1",
                "previous_workspace_id": "wA",
                "previous_tab_id": "wA:t1",
                "pane": {
                    "pane_id": "wB:p4",
                    "workspace_id": "wB",
                    "tab_id": "wB:t1",
                    "agent": "claude",
                    "agent_status": "blocked",
                    "state_change_seq": 9,
                    "title": "Claude"
                },
                "created_workspace": {
                    "workspace_id": "wB",
                    "label": "proj",
                    "focused": true,
                    "pane_count": 1,
                    "tab_count": 1,
                    "number": 2,
                    "active_tab_id": "wB:t1",
                    "agent_status": "blocked"
                },
                "created_tab": {
                    "tab_id": "wB:t1",
                    "workspace_id": "wB",
                    "label": "main"
                }
            }
        }
        """
        let data = jsonString.data(using: .utf8)!
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let event = LiveHerdrAdapter.parseEvent(dict)
        if case .paneMoved(let previous, let info, let workspace, let tab) = event {
            #expect(previous == "wA:p1")
            #expect(info.paneId == "wB:p4")
            #expect(info.workspaceId == "wB")
            #expect(info.tabId == "wB:t1")
            #expect(info.agent == "claude")
            #expect(info.agentStatus == "blocked")
            #expect(info.stateChangeSeq == 9)
            #expect(workspace == "proj")
            #expect(tab == "main")
        } else {
            Issue.record("Expected .paneMoved, got \(event)")
        }
    }

    @Test("A flat pane.moved with no previous id is the same pane")
    func flatPaneMovedKeepsTheOnlyId() {
        let event = LiveHerdrAdapter.parseEvent([
            "event": "pane.moved",
            "data": [
                "pane_id": "w1:p1",
                "workspace_id": "w1",
                "tab_id": "w1:t2",
                "agent": "codex",
                "agent_status": "working",
                "state_change_seq": 3
            ] as [String: Any]
        ])
        if case .paneMoved(let previous, let info, let workspace, let tab) = event {
            #expect(previous.isEmpty)
            #expect(info.paneId == "w1:p1")
            #expect(info.tabId == "w1:t2")
            #expect(info.agentStatus == "working")
            #expect(info.stateChangeSeq == 3)
            #expect(workspace == nil)
            #expect(tab == nil)
        } else {
            Issue.record("Expected .paneMoved for flat pane.moved, got \(event)")
        }
    }

    @Test("pane_moved with an empty new pane id is ignored")
    func emptyMovedPaneIdIsIgnored() {
        let event = LiveHerdrAdapter.parseEvent([
            "event": "pane_moved",
            "data": [
                "previous_pane_id": "wA:p1",
                "pane": ["pane_id": ""]
            ] as [String: Any]
        ])
        if case .ignored = event {
            // pass
        } else {
            Issue.record("Expected .ignored for empty moved pane id, got \(event)")
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

    @Test("pane.moved is subscribed so a cross-workspace id change is delivered")
    func includesPaneMoved() {
        // herdr's Subscription::PaneMoved carries no pane_id. Omitting it
        // leaves the re-key path dead: the move is not a close plus a create.
        #expect(LiveHerdrAdapter.globalSubscriptionTypes.contains("pane.moved"))
        #expect(LiveHerdrAdapter.globalSubscriptionTypes.filter { $0 == "pane.moved" }.count == 1)
    }

    @Test("Focus subscriptions are not requested")
    func omitsFocusSubscriptions() {
        // A focus does not change the herd. Subscribing to workspace.focused
        // made herdmgr refetch on every click.
        let types = LiveHerdrAdapter.globalSubscriptionTypes
        #expect(!types.contains("pane.focused"))
        #expect(!types.contains("workspace.focused"))
        #expect(!types.contains("tab.focused"))
        #expect(types.contains("workspace.created"))
        #expect(types.contains("tab.created"))
        #expect(types.contains("pane.agent_detected"))
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
        #expect(info.foregroundProcesses.first?.argv == nil)
    }

    @Test("pane.process_info keeps argv, and a non-string element drops the field")
    func processInfoArgv() throws {
        let response: [String: Any] = [
            "process_info": [
                "shell_pid": 1,
                "foreground_processes": [
                    [
                        "pid": 2,
                        "name": "sh",
                        "argv0": "/bin/sh",
                        "argv": ["/bin/sh", "/tmp/test-bin/pi"],
                        "cmdline": "/bin/sh /tmp/test-bin/pi",
                    ] as [String: Any],
                ],
            ] as [String: Any],
        ]
        let info = LiveHerdrAdapter.parseProcessInfo(response)
        #expect(info.foregroundProcesses.first?.argv == ["/bin/sh", "/tmp/test-bin/pi"])

        let mixed: [String: Any] = [
            "foreground_processes": [
                [
                    "pid": 3,
                    "name": "sh",
                    "argv": ["/bin/sh", 1] as [Any],
                ] as [String: Any],
            ],
        ]
        let dropped = LiveHerdrAdapter.parseProcessInfo(mixed)
        #expect(dropped.foregroundProcesses.first?.argv == nil)
        #expect(dropped.foregroundProcesses.first?.name == "sh")

        let empty: [String: Any] = [
            "foreground_processes": [
                ["pid": 4, "name": "bash", "argv": [String]()] as [String: Any],
            ],
        ]
        #expect(LiveHerdrAdapter.parseProcessInfo(empty).foregroundProcesses.first?.argv == nil)
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

    @Test("pane.split and tab.create omit an empty cwd")
    func emptyCwdIsOmitted() {
        let split = LiveHerdrAdapter.splitPaneParams(targetPaneId: "wE:p1", cwd: "")
        #expect(split["target_pane_id"] as? String == "wE:p1")
        #expect(split["cwd"] == nil)
        let splitMissing = LiveHerdrAdapter.splitPaneParams(targetPaneId: "wE:p1", cwd: nil)
        #expect(splitMissing["cwd"] == nil)

        let tab = LiveHerdrAdapter.createTabParams(
            workspaceId: "w1", cwd: "", label: "Claude", focus: true
        )
        #expect(tab["workspace_id"] as? String == "w1")
        #expect(tab["label"] as? String == "Claude")
        #expect(tab["focus"] as? Bool == true)
        #expect(tab["cwd"] == nil)

        let withCwd = LiveHerdrAdapter.createTabParams(
            workspaceId: nil, cwd: "/work", label: nil, focus: false
        )
        #expect(withCwd["cwd"] as? String == "/work")
        #expect(withCwd["workspace_id"] == nil)
        #expect(withCwd["label"] == nil)
        #expect(withCwd["focus"] as? Bool == false)
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

@Suite("LiveHerdrAdapter protocol reading after herdr goes away")
struct ProtocolReadingResetTests {
    /// A socket path nothing listens on, so every connect fails the way it
    /// does while herdr is stopped or restarting.
    private func unreachableSocketPath() -> String {
        "/tmp/herdr-missing-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test("An earlier herd-read serial cannot put an older protocol back")
    func earlierReadSerialDoesNotClobberProtocol() async {
        let adapter = LiveHerdrAdapter(socketPath: unreachableSocketPath())
        adapter.setLatestProtocol(18, readSerial: 2)
        adapter.setLatestProtocol(17, readSerial: 1)
        #expect(adapter.health().protocolVersion == 18)

        adapter.setLatestProtocol(19, readSerial: 3)
        #expect(adapter.health().protocolVersion == 19)

        // A connect failure clears the reading. The serial it carries has
        // to outrank the earlier success, and that success must not return.
        do {
            _ = try await adapter.herdSnapshot(readSerial: 4)
            Issue.record("Expected the snapshot to fail with no herdr listening")
        } catch {
            #expect(error is NDJSONClientError)
        }
        #expect(adapter.health().protocolVersion == 0)
        adapter.setLatestProtocol(19, readSerial: 3)
        #expect(adapter.health().protocolVersion == 0)

        // The next read, and any caller that does not pass a serial, records.
        adapter.setLatestProtocol(17)
        #expect(adapter.health().protocolVersion == 17)
        adapter.setLatestProtocol(18, readSerial: 5)
        #expect(adapter.health().protocolVersion == 18)
    }

    @Test("A request that cannot reach herdr forgets the old protocol reading")
    func connectFailureClearsReading() async {
        let adapter = LiveHerdrAdapter(socketPath: unreachableSocketPath())
        adapter.setLatestProtocol(LiveHerdrAdapter.minSupportedProtocolVersion)
        #expect(adapter.health().writesEnabled)

        do {
            _ = try await adapter.herdSnapshot()
            Issue.record("Expected the snapshot to fail with no herdr listening")
        } catch {
            #expect(error is NDJSONClientError)
        }

        let health = adapter.health()
        #expect(health.protocolVersion == 0)
        #expect(!health.writesEnabled)
        #expect(health.reason == "protocol unknown")
    }

    @Test("An older-protocol reading does not outlive a failed connect")
    func failedConnectClearsOlderReading() async {
        let adapter = LiveHerdrAdapter(socketPath: unreachableSocketPath())
        adapter.setLatestProtocol(16)
        #expect(adapter.health().reason?.contains("older") == true)

        do {
            try await adapter.connect()
            Issue.record("Expected connect to fail with no herdr listening")
        } catch {}

        #expect(adapter.health().protocolVersion == 0)
        #expect(adapter.health().reason == "protocol unknown")
    }

    @Test("A herdr restarted on an older protocol between calls is caught by the refreshed gate")
    func restartBetweenCallsIsReRead() async throws {
        let path = FakeHerdrServer.temporaryPath()
        let original = try FakeHerdrServer(path: path, reply: .protocolVersion(17))
        let adapter = LiveHerdrAdapter(socketPath: path)
        _ = try await adapter.herdSnapshot()
        #expect(adapter.health().writesEnabled)

        original.stop()
        let restarted = try FakeHerdrServer(path: path, reply: .protocolVersion(16))
        defer { restarted.stop() }

        // No request failed across the restart, so the cached reading is
        // still the old build's. This is what the MCP write gate used.
        #expect(adapter.health().protocolVersion == 17)

        let health = await adapter.refreshHealth()
        #expect(health.protocolVersion == 16)
        #expect(!health.writesEnabled)
        #expect(adapter.health().protocolVersion == 16)
    }

    @Test("A refreshed gate re-enables writes once herdr is back on a verified protocol")
    func refreshAfterUpgradeEnablesWrites() async throws {
        let path = FakeHerdrServer.temporaryPath()
        let server = try FakeHerdrServer(path: path, reply: .protocolVersion(18))
        defer { server.stop() }
        let adapter = LiveHerdrAdapter(socketPath: path)
        adapter.setLatestProtocol(16)

        let health = await adapter.refreshHealth()
        #expect(health.protocolVersion == 18)
        #expect(health.writesEnabled)
    }

    @Test("A refresh that herdr answers with an error forgets the old reading")
    func refreshErrorClearsReading() async throws {
        let path = FakeHerdrServer.temporaryPath()
        let server = try FakeHerdrServer(path: path, reply: .error("snapshot unavailable"))
        defer { server.stop() }
        let adapter = LiveHerdrAdapter(socketPath: path)
        adapter.setLatestProtocol(LiveHerdrAdapter.minSupportedProtocolVersion)

        let health = await adapter.refreshHealth()
        #expect(health.protocolVersion == 0)
        #expect(!health.writesEnabled)
        #expect(health.reason?.hasPrefix("protocol unknown") == true)
        #expect(health.reason?.contains("snapshot unavailable") == true)
        #expect(adapter.health().protocolVersion == 0)
    }

    @Test("A refresh with nothing listening leaves writes off and says why")
    func refreshWithNoHerdrLeavesWritesOff() async {
        let path = unreachableSocketPath()
        let adapter = LiveHerdrAdapter(socketPath: path)
        adapter.setLatestProtocol(LiveHerdrAdapter.minSupportedProtocolVersion)

        let health = await adapter.refreshHealth()
        #expect(!health.writesEnabled)
        #expect(health.reason?.contains(path) == true)
        #expect(adapter.health().reason == "protocol unknown")
    }

    @Test("A connect failure on an earlier herd-read serial leaves a newer protocol in place")
    func earlierConnectFailureDoesNotClearNewerProtocol() async {
        let adapter = LiveHerdrAdapter(socketPath: unreachableSocketPath())
        adapter.setLatestProtocol(18, readSerial: 5)
        #expect(adapter.health().writesEnabled)

        do {
            _ = try await adapter.herdSnapshot(readSerial: 4)
            Issue.record("Expected the snapshot to fail with no herdr listening")
        } catch {
            #expect(error is NDJSONClientError)
        }

        // Captured before the reading already on the gate, so the failed
        // connect must not wipe it.
        #expect(adapter.health().protocolVersion == 18)
        #expect(adapter.health().writesEnabled)
    }

    @Test("An earlier herd snapshot does not put an older protocol back")
    func earlierHerdSnapshotDoesNotClobberProtocol() async throws {
        let path = FakeHerdrServer.temporaryPath()
        let server = try FakeHerdrServer(path: path, reply: .protocolVersion(16))
        defer { server.stop() }
        let adapter = LiveHerdrAdapter(socketPath: path)
        adapter.setLatestProtocol(18, readSerial: 5)

        let herd = try await adapter.herdSnapshot(readSerial: 4)
        #expect(herd.protocol == 16)
        #expect(adapter.health().protocolVersion == 18)
        #expect(adapter.health().writesEnabled)

        _ = try await adapter.herdSnapshot(readSerial: 6)
        #expect(adapter.health().protocolVersion == 16)
        #expect(!adapter.health().writesEnabled)
    }

    @Test("An earlier snapshot does not put an older protocol back")
    func earlierSnapshotDoesNotClobberProtocol() async throws {
        let path = FakeHerdrServer.temporaryPath()
        let server = try FakeHerdrServer(path: path, reply: .protocolVersion(16))
        defer { server.stop() }
        let adapter = LiveHerdrAdapter(socketPath: path)
        adapter.setLatestProtocol(18, readSerial: 5)

        let snap = try await adapter.snapshot(readSerial: 4)
        #expect(snap.protocol == 16)
        #expect(adapter.health().protocolVersion == 18)

        _ = try await adapter.snapshot(readSerial: 6)
        #expect(adapter.health().protocolVersion == 16)

        // A caller that does not pass a serial still records, which is the
        // CLI and any one-shot reader that is alone on the adapter.
        adapter.setLatestProtocol(18, readSerial: 7)
        _ = try await adapter.snapshot()
        #expect(adapter.health().protocolVersion == 16)
    }

    @Test("An earlier refresh failure does not clear a newer protocol")
    func earlierRefreshFailureDoesNotClearNewerProtocol() async {
        let adapter = LiveHerdrAdapter(socketPath: unreachableSocketPath())
        adapter.setLatestProtocol(18, readSerial: 5)

        let health = await adapter.refreshHealth(readSerial: 4)
        #expect(!health.writesEnabled)
        #expect(health.reason?.contains("protocol unknown") == true)
        #expect(adapter.health().protocolVersion == 18)
        #expect(adapter.health().writesEnabled)
    }

    @Test("A newer refresh that cannot reach herdr forgets the old protocol")
    func newerRefreshFailureClearsProtocol() async {
        let adapter = LiveHerdrAdapter(socketPath: unreachableSocketPath())
        adapter.setLatestProtocol(18, readSerial: 5)

        let health = await adapter.refreshHealth(readSerial: 6)
        #expect(!health.writesEnabled)
        #expect(adapter.health().protocolVersion == 0)
        #expect(!adapter.health().writesEnabled)
    }

    @Test("An earlier refresh that herdr answers with an error leaves a newer protocol in place")
    func earlierRefreshErrorDoesNotClearNewerProtocol() async throws {
        let path = FakeHerdrServer.temporaryPath()
        let server = try FakeHerdrServer(path: path, reply: .error("snapshot unavailable"))
        defer { server.stop() }
        let adapter = LiveHerdrAdapter(socketPath: path)
        adapter.setLatestProtocol(18, readSerial: 5)

        let health = await adapter.refreshHealth(readSerial: 4)
        #expect(!health.writesEnabled)
        #expect(health.reason?.contains("snapshot unavailable") == true)
        #expect(adapter.health().protocolVersion == 18)
        #expect(adapter.health().writesEnabled)
    }

    @Test("A refresh that loses the serial race returns the newer gate, not its own protocol")
    func staleRefreshReturnsTheNewerGate() async throws {
        let path = FakeHerdrServer.temporaryPath()
        let server = try FakeHerdrServer(path: path, reply: .protocolVersion(18))
        defer { server.stop() }
        let adapter = LiveHerdrAdapter(socketPath: path)
        // A later read already saw the downgrade. This refresh still gets
        // a snapshot — protocol 18, writes on — and must not hand that to
        // the caller.
        adapter.setLatestProtocol(16, readSerial: 5)

        let health = await adapter.refreshHealth(readSerial: 4)
        #expect(health.protocolVersion == 16)
        #expect(!health.writesEnabled)
        #expect(adapter.health().protocolVersion == 16)
    }

    @Test("A herd snapshot records its enqueue epoch, so an earlier one cannot replace it")
    func herdSnapshotRecordsEnqueueEpoch() async throws {
        let path = FakeHerdrServer.temporaryPath()
        let server = try FakeHerdrServer(path: path, reply: .protocolVersion(17))
        defer { server.stop() }
        let adapter = LiveHerdrAdapter(socketPath: path)
        let earlier = adapter.issueProtocolEpoch()

        _ = try await adapter.herdSnapshot()
        #expect(adapter.health().protocolVersion == 17)

        // A read that was already in flight when this snapshot started.
        adapter.setLatestProtocol(18, readSerial: 9, epoch: earlier)
        #expect(adapter.health().protocolVersion == 17)
        #expect(adapter.health().writesEnabled)
    }

    @Test("A session snapshot records its enqueue epoch, so an earlier one cannot replace it")
    func snapshotRecordsEnqueueEpoch() async throws {
        let path = FakeHerdrServer.temporaryPath()
        let server = try FakeHerdrServer(path: path, reply: .protocolVersion(17))
        defer { server.stop() }
        let adapter = LiveHerdrAdapter(socketPath: path)
        let earlier = adapter.issueProtocolEpoch()

        _ = try await adapter.snapshot()
        #expect(adapter.health().protocolVersion == 17)

        adapter.setLatestProtocol(18, epoch: earlier)
        #expect(adapter.health().protocolVersion == 17)
        #expect(adapter.health().writesEnabled)
    }

    @Test("A pane read that cannot connect is not undone by an earlier herd read")
    func paneReadConnectFailureIsNotUndoneByAnEarlierEpoch() async {
        let adapter = LiveHerdrAdapter(socketPath: unreachableSocketPath())
        let earlier = adapter.issueProtocolEpoch()
        adapter.setLatestProtocol(17, readSerial: 9, epoch: earlier)
        #expect(adapter.health().writesEnabled)

        do {
            _ = try await adapter.read(paneId: "w1:p1", source: .visible)
            Issue.record("Expected the read to fail with no herdr listening")
        } catch {
            #expect(error is NDJSONClientError)
        }

        #expect(adapter.health().protocolVersion == 0)
        #expect(!adapter.health().writesEnabled)

        // The in-flight herd read had a newer serial and no reason to lose
        // on that gate. It still must not turn writes back on: it started
        // before the socket refused the read.
        adapter.setLatestProtocol(17, readSerial: 10, epoch: earlier)
        #expect(adapter.health().protocolVersion == 0)

        let later = adapter.issueProtocolEpoch()
        adapter.setLatestProtocol(17, readSerial: 11, epoch: later)
        #expect(adapter.health().protocolVersion == 17)
        #expect(adapter.health().writesEnabled)
    }

    @Test("An earlier connect failure does not wipe a protocol recorded later")
    func earlierEpochDoesNotWipeANewerProtocol() {
        let adapter = LiveHerdrAdapter(socketPath: unreachableSocketPath())
        let earlier = adapter.issueProtocolEpoch()
        let later = adapter.issueProtocolEpoch()
        adapter.setLatestProtocol(18, readSerial: 4, epoch: later)

        adapter.setLatestProtocol(0, epoch: earlier)
        #expect(adapter.health().protocolVersion == 18)
        #expect(adapter.health().writesEnabled)
    }

    @Test("A dropped subscription is not undone by a herd read that already started")
    func droppedSubscriptionIsNotUndoneByAnEarlierEpoch() {
        let adapter = LiveHerdrAdapter(socketPath: unreachableSocketPath())
        let earlier = adapter.issueProtocolEpoch()
        adapter.setLatestProtocol(17, readSerial: 4, epoch: earlier)
        #expect(adapter.health().writesEnabled)

        adapter.clearProtocolReading()
        #expect(adapter.health().protocolVersion == 0)
        #expect(!adapter.health().writesEnabled)

        adapter.setLatestProtocol(17, readSerial: 8, epoch: earlier)
        #expect(adapter.health().protocolVersion == 0)

        let later = adapter.issueProtocolEpoch()
        adapter.setLatestProtocol(16, epoch: later)
        #expect(adapter.health().protocolVersion == 16)
        #expect(!adapter.health().writesEnabled)
    }

    @Test("A refresh herdr answers with an error is not undone by an earlier read")
    func refreshErrorIsNotUndoneByAnEarlierEpoch() async throws {
        let path = FakeHerdrServer.temporaryPath()
        let server = try FakeHerdrServer(path: path, reply: .error("snapshot unavailable"))
        defer { server.stop() }
        let adapter = LiveHerdrAdapter(socketPath: path)
        let earlier = adapter.issueProtocolEpoch()
        adapter.setLatestProtocol(17, readSerial: 2, epoch: earlier)

        let health = await adapter.refreshHealth()
        #expect(!health.writesEnabled)
        #expect(health.reason?.contains("snapshot unavailable") == true)
        #expect(adapter.health().protocolVersion == 0)

        // Nil serial, and a serial newer than the one this refresh carried.
        // Neither is allowed to put protocol 17 back: the refresh started
        // after that reading.
        adapter.setLatestProtocol(17, epoch: earlier)
        adapter.setLatestProtocol(17, readSerial: 9, epoch: earlier)
        #expect(adapter.health().protocolVersion == 0)
        #expect(!adapter.health().writesEnabled)
    }
}

@Suite("Mutations obey the write gate on the I/O queue")
struct WriteGateOnIOQueueTests {
    private func unreachableSocketPath() -> String {
        "/tmp/herdr-missing-\(UUID().uuidString.prefix(8)).sock"
    }

    /// A closed gate must refuse before connect. `connectFailed` means the
    /// call got past the gate and tried the socket.
    private func expectRefused(
        _ name: String,
        reasonContains: String,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("\(name): expected the write to be refused")
        } catch let error as NDJSONClientError {
            guard case .writesDisabled(let reason) = error else {
                Issue.record("\(name): expected writesDisabled, got \(error)")
                return
            }
            #expect(reason.contains(reasonContains))
            if !reason.contains(reasonContains) {
                Issue.record("\(name): \(reason)")
            }
        } catch {
            Issue.record("\(name): unexpected error \(error)")
        }
    }

    @Test("An older protocol refuses every mutation and leaves that reading in place")
    func olderProtocolRefusesMutations() async {
        let adapter = LiveHerdrAdapter(socketPath: unreachableSocketPath())
        adapter.setLatestProtocol(16)
        #expect(!adapter.health().writesEnabled)

        await expectRefused("sendKeys", reasonContains: "16") {
            try await adapter.sendKeys(paneId: "w1:p1", keys: ["enter"])
        }
        await expectRefused("prompt", reasonContains: "16") {
            try await adapter.prompt(paneId: "w1:p1", text: "hello")
        }
        await expectRefused("closePane", reasonContains: "16") {
            try await adapter.closePane(paneId: "w1:p1")
        }
        await expectRefused("focus", reasonContains: "16") {
            try await adapter.focus(paneId: "w1:p1")
        }
        await expectRefused("focusWorkspace", reasonContains: "16") {
            try await adapter.focusWorkspace("w1")
        }
        await expectRefused("focusTab", reasonContains: "16") {
            try await adapter.focusTab("w1:t1")
        }
        await expectRefused("focusPane", reasonContains: "16") {
            try await adapter.focusPane("w1:p1")
        }
        await expectRefused("createWorkspace", reasonContains: "16") {
            _ = try await adapter.createWorkspace(cwd: "/tmp", label: "scratch")
        }
        await expectRefused("createTab", reasonContains: "16") {
            _ = try await adapter.createTab(workspaceId: "w1", cwd: nil, label: nil, focus: true)
        }
        await expectRefused("splitPane", reasonContains: "16") {
            _ = try await adapter.splitPane(targetPaneId: "w1:p1", cwd: nil)
        }
        await expectRefused("startAgent", reasonContains: "16") {
            try await adapter.startAgent(paneId: "w1:p1", kind: "claude", name: "claude")
        }
        await expectRefused("reportMetadata", reasonContains: "16") {
            try await adapter.reportMetadata(
                paneId: "w1:p1",
                source: "shepherd",
                tokens: ["stuck_for": "1m"],
                ttlMs: 1000
            )
        }

        // A refusal never connects, so the connect-failure path must not
        // clear the older reading.
        #expect(adapter.health().protocolVersion == 16)
        #expect(!adapter.health().writesEnabled)
    }

    @Test("An unknown protocol refuses a write and does not pretend to have connected")
    func unknownProtocolRefusesWrite() async {
        let adapter = LiveHerdrAdapter(socketPath: unreachableSocketPath())
        await expectRefused("prompt", reasonContains: "unknown") {
            try await adapter.prompt(paneId: "w1:p1", text: "hello")
        }
        #expect(adapter.health().protocolVersion == 0)
        #expect(adapter.health().reason == "protocol unknown")
    }

    @Test("A herd read that records an older protocol blocks the write that follows it")
    func downgradeRecordedByHerdReadBlocksTheNextWrite() async throws {
        let path = FakeHerdrServer.temporaryPath()
        let server = try FakeHerdrServer(path: path, reply: .protocolVersion(16))
        defer { server.stop() }
        let adapter = LiveHerdrAdapter(socketPath: path)
        // The gate still says the previous build. This is the reading a
        // confirm-time refresh stored before revalidation's herd read.
        adapter.setLatestProtocol(17)
        #expect(adapter.health().writesEnabled)

        let herd = try await adapter.herdSnapshot()
        #expect(herd.protocol == 16)
        #expect(adapter.health().protocolVersion == 16)

        // The fake answers any method with success. A write that reached
        // the socket would return, not throw.
        await expectRefused("sendKeys", reasonContains: "16") {
            try await adapter.sendKeys(paneId: "w1:p1", keys: ["enter"])
        }
        #expect(adapter.health().protocolVersion == 16)
        #expect(!adapter.health().writesEnabled)
    }

    @Test("A verified protocol still sends the write")
    func verifiedProtocolSendsTheWrite() async throws {
        let path = FakeHerdrServer.temporaryPath()
        let server = try FakeHerdrServer(path: path, reply: .protocolVersion(17))
        defer { server.stop() }
        let adapter = LiveHerdrAdapter(socketPath: path)
        adapter.setLatestProtocol(17)

        try await adapter.sendKeys(paneId: "w1:p1", keys: ["enter"])
        try await adapter.prompt(paneId: "w1:p1", text: "hello")
        try await adapter.closePane(paneId: "w1:p1")
        // The write does not record a protocol. The verified reading stays.
        #expect(adapter.health().protocolVersion == 17)
        #expect(adapter.health().writesEnabled)
    }

    @Test("Enter failing after the text write is not a rejected prompt")
    func promptEnterFailureIsItsOwnError() async throws {
        let path = FakeHerdrServer.temporaryPath()
        let server = try FakeHerdrServer(path: path, reply: .succeedThenFail)
        defer { server.stop() }
        let adapter = LiveHerdrAdapter(socketPath: path)
        adapter.setLatestProtocol(17)

        do {
            try await adapter.prompt(paneId: "w1:p1", text: "hello")
            Issue.record("expected Enter to fail after the text write")
        } catch NDJSONClientError.promptEnterFailed {
            // The text write returned. Enter's rejection is not attached,
            // and this is not the invalidResponse a rejected text write throws.
        } catch {
            Issue.record("expected promptEnterFailed, got \(error)")
        }

        // Enter's failure is not a connect failure, so the reading stays.
        #expect(adapter.health().protocolVersion == 17)
        #expect(adapter.health().writesEnabled)
    }

    @Test("A verified write that cannot connect still clears the reading")
    func verifiedWriteConnectFailureClearsReading() async {
        let adapter = LiveHerdrAdapter(socketPath: unreachableSocketPath())
        adapter.setLatestProtocol(17)
        #expect(adapter.health().writesEnabled)

        do {
            try await adapter.closePane(paneId: "w1:p1")
            Issue.record("Expected connect to fail with no herdr listening")
        } catch let error as NDJSONClientError {
            guard case .connectFailed = error else {
                Issue.record("Expected connectFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error \(error)")
        }

        #expect(adapter.health().protocolVersion == 0)
        #expect(!adapter.health().writesEnabled)
    }

    @Test("A read is still attempted when writes are off")
    func readIsNotGated() async throws {
        let path = FakeHerdrServer.temporaryPath()
        let server = try FakeHerdrServer(path: path, reply: .protocolVersion(16))
        defer { server.stop() }
        let adapter = LiveHerdrAdapter(socketPath: path)
        adapter.setLatestProtocol(16)

        let herd = try await adapter.herdSnapshot()
        #expect(herd.protocol == 16)
        let snap = try await adapter.snapshot()
        #expect(snap.protocol == 16)
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
        let jsonTrue = try JSONSerialization.jsonObject(with: Data("true".utf8), options: .fragmentsAllowed)
        let jsonFalse = try JSONSerialization.jsonObject(with: Data("false".utf8), options: .fragmentsAllowed)
        #expect(JSONNumber.int(jsonTrue) == nil)
        #expect(JSONNumber.int(jsonFalse) == nil)
        #expect(JSONNumber.uint64(true) == nil)
        #expect(JSONNumber.uint64(jsonTrue) == nil)

        let jsonHalf = try JSONSerialization.jsonObject(with: Data("17.5".utf8), options: .fragmentsAllowed)
        #expect(JSONNumber.int(jsonHalf) == nil)
        #expect(JSONNumber.uint64(jsonHalf) == nil)
        #expect(!JSONNumber.matchesStringId(jsonHalf, expected: "17"))
        let jsonWhole = try JSONSerialization.jsonObject(with: Data("17".utf8), options: .fragmentsAllowed)
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

/// Any non-null JSON-RPC `error` must fail the call. Only an error object
/// with a string `message` used to throw; `{"error":{"code":-32601}}` or
/// `{"error":"boom"}` fell through and returned the envelope as a result,
/// so a rejected write looked sent and a failed snapshot parsed as an empty
/// herd on protocol 0.
@Suite("NDJSONClient response unwrapping")
struct NDJSONResponseUnwrapTests {
    private func invalidResponseDetail(_ response: [String: Any]) -> String? {
        do {
            _ = try NDJSONClient.unwrapResponse(response)
            return nil
        } catch NDJSONClientError.invalidResponse(let detail) {
            return detail
        } catch {
            return "unexpected error: \(error)"
        }
    }

    @Test("Returns the nested result object")
    func returnsNestedResult() throws {
        let result = try NDJSONClient.unwrapResponse([
            "id": "1",
            "result": ["type": "session_snapshot"] as [String: Any]
        ])
        #expect(result["type"] as? String == "session_snapshot")
    }

    @Test("A flat response without `result` is still returned as-is")
    func returnsFlatResponse() throws {
        let result = try NDJSONClient.unwrapResponse(["id": "1", "type": "pane_read"])
        #expect(result["type"] as? String == "pane_read")
    }

    @Test("A JSON null error next to a result is success")
    func nullErrorIsSuccess() throws {
        let result = try NDJSONClient.unwrapResponse([
            "id": "1",
            "error": NSNull(),
            "result": ["ok": true] as [String: Any]
        ])
        #expect(result["ok"] as? Bool == true)
    }

    @Test("Surfaces herdr's error message unchanged")
    func surfacesMessage() {
        let detail = invalidResponseDetail([
            "id": "1",
            "error": ["code": -32000, "message": "pane not found"] as [String: Any]
        ])
        #expect(detail == "pane not found")
    }

    @Test("An error object without a message still fails the call")
    func codeOnlyErrorThrows() {
        let detail = invalidResponseDetail([
            "id": "1",
            "error": ["code": -32601] as [String: Any]
        ])
        #expect(detail?.contains("-32601") == true)
    }

    @Test("An error object with a non-string message still fails the call")
    func nonStringMessageThrows() {
        let detail = invalidResponseDetail([
            "id": "1",
            "error": ["code": "pane_not_found", "message": 42] as [String: Any]
        ])
        #expect(detail?.contains("pane_not_found") == true)
    }

    @Test("A bare string error fails the call with that text")
    func stringErrorThrows() {
        #expect(invalidResponseDetail(["id": "1", "error": "boom"]) == "boom")
    }

    @Test("An empty error object still fails even when a result is present")
    func emptyErrorObjectThrows() {
        let detail = invalidResponseDetail([
            "id": "1",
            "error": [String: Any](),
            "result": ["type": "pane_read"] as [String: Any]
        ])
        #expect(detail != nil)
    }
}

/// `agent.wait` succeeds as `agent_info`. A timeout is an error whose
/// message is exactly `timed out waiting for agent status`, not
/// `settled: false`. Treating that error as a thrown failure made
/// `agent.say` report `wait_failed` and made a spawn brief skip the
/// herd list.
@Suite("agent.wait result")
struct AgentWaitResultTests {
    private func object(_ json: String) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
        guard let object = parsed as? [String: Any] else {
            Issue.record("Expected an object")
            return [:]
        }
        return object
    }

    @Test("A matching agent_info is settled, and any other status is not")
    func agentInfoEnvelope() throws {
        let idle = try object(#"{"type":"agent_info","agent":{"agent_status":"idle","pane_id":"w1:p1"}}"#)
        #expect(LiveHerdrAdapter.agentWaitSettled(idle, until: ["idle", "done", "blocked"]))
        #expect(!LiveHerdrAdapter.agentWaitSettled(idle, until: ["done"]))
        #expect(!LiveHerdrAdapter.agentWaitSettled(idle, until: ["Idle"]))

        let working = try object(#"{"type":"agent_info","agent":{"agent_status":"working"}}"#)
        #expect(LiveHerdrAdapter.agentWaitSettled(working, until: ["working"]))
        #expect(!LiveHerdrAdapter.agentWaitSettled(working, until: ["idle"]))
    }

    @Test("The agent record wins over a settled flag on the same object")
    func agentRecordWins() throws {
        let working = try object(#"{"settled":true,"agent":{"agent_status":"working"}}"#)
        #expect(!LiveHerdrAdapter.agentWaitSettled(working, until: ["idle"]))
        #expect(LiveHerdrAdapter.agentWaitSettled(working, until: ["working"]))
    }

    @Test("A result with no agent record still accepts settled or a top-level status")
    func legacyShapes() throws {
        let settled = try object(#"{"settled":true}"#)
        #expect(LiveHerdrAdapter.agentWaitSettled(settled, until: ["idle"]))
        let other = try object(#"{"settled":false,"status":"working"}"#)
        #expect(!LiveHerdrAdapter.agentWaitSettled(other, until: ["idle"]))
        #expect(LiveHerdrAdapter.agentWaitSettled(other, until: ["working"]))
        let bare = try object(#"{"type":"ok"}"#)
        #expect(!LiveHerdrAdapter.agentWaitSettled(bare, until: ["idle"]))
    }

    @Test("herdr's status timeout is unsettled, and a different failure is not")
    func timeoutIsUnsettled() throws {
        let response: [String: Any] = [
            "id": "7",
            "error": [
                "code": "timeout",
                "message": LiveHerdrAdapter.agentWaitTimeoutDetail
            ] as [String: Any]
        ]
        do {
            _ = try NDJSONClient.unwrapResponse(response)
            Issue.record("Expected the timeout error to throw")
        } catch {
            #expect(LiveHerdrAdapter.agentWaitTimedOut(error))
        }

        #expect(!LiveHerdrAdapter.agentWaitTimedOut(
            NDJSONClientError.invalidResponse("timed out waiting for output match")
        ))
        #expect(!LiveHerdrAdapter.agentWaitTimedOut(
            NDJSONClientError.invalidResponse("timed out waiting for agent status now")
        ))
        #expect(!LiveHerdrAdapter.agentWaitTimedOut(
            NDJSONClientError.invalidResponse("agent is not running")
        ))
        #expect(!LiveHerdrAdapter.agentWaitTimedOut(NDJSONClientError.timeout))
        #expect(!LiveHerdrAdapter.agentWaitTimedOut(
            NDJSONClientError.connectFailed("/tmp/herdr.sock", 2)
        ))
    }
}

/// Shepherd and MCP render failures with `error.localizedDescription`.
/// For an enum that is only CustomStringConvertible that bridges to
/// "The operation couldn't be completed. (…Error error 4.)", so "Connect
/// failed:" / "Approve failed:" lost the socket path, errno, and herdr's
/// own message.
@Suite("Core errors keep their reason in localizedDescription")
struct CoreErrorDescriptionTests {
    @Test("NDJSONClientError carries herdr's message and the socket path")
    func ndjsonClientError() {
        let rejected: Error = NDJSONClientError.invalidResponse("pane not found")
        #expect(rejected.localizedDescription == "invalid response: pane not found")

        let connect: Error = NDJSONClientError.connectFailed("/tmp/herdr.sock", 2)
        #expect(connect.localizedDescription.contains("/tmp/herdr.sock"))
        #expect(connect.localizedDescription.contains("errno 2"))

        let gated: Error = NDJSONClientError.writesDisabled("herdr protocol 16 is older than the minimum verified 17; writes disabled")
        #expect(gated.localizedDescription.contains("writes disabled"))
        #expect(gated.localizedDescription.contains("protocol 16"))

        let entered: Error = NDJSONClientError.promptEnterFailed
        #expect(entered.localizedDescription == "text was inserted, but Enter failed")
        #expect(!entered.localizedDescription.contains("\""))
        #expect(!entered.localizedDescription.contains("invalid response"))
    }

    @Test("SharedActionStoreError carries the store failure")
    func sharedActionStoreError() {
        let error: Error = SharedActionStoreError.writeFailed("rename failed (errno 21)")
        #expect(error.localizedDescription.contains("rename failed (errno 21)"))
        let locked: Error = SharedActionStoreError.lockUnavailable("fcntl lock failed")
        #expect(locked.localizedDescription.contains("fcntl lock failed"))
    }

    @Test("SettingsStoreError carries the size refusal")
    func settingsStoreError() {
        let error: Error = SettingsStoreError.fileTooLarge
        #expect(error.localizedDescription == SettingsStoreError.fileTooLarge.description)
    }
}
