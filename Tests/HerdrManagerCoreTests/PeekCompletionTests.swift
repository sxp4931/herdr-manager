import Foundation
import Testing
@testable import HerdrManagerCore

@Suite("PeekCompletion")
struct PeekCompletionTests {
    private let started = AgentID("wA:p1")
    private let moved = AgentID("wB:p4")

    @Test("A peek whose pane is still selected is shown")
    func showWhenSelectionUnchanged() {
        let decision = PeekCompletion.decide(
            isLatest: true,
            stillLoading: true,
            selectedId: started,
            readPaneId: started
        )
        #expect(decision == .show)
    }

    @Test("A peek that lands after the selection followed a move is read again")
    func rereadWhenSelectionMoved() {
        // The bytes were addressed to the id the agent left. After the move
        // that id can be a shell, and the spinner is drawn on the new row.
        let decision = PeekCompletion.decide(
            isLatest: true,
            stillLoading: true,
            selectedId: moved,
            readPaneId: started
        )
        #expect(decision == .reread)
    }

    @Test("A peek with nothing selected does not leave the spinner up")
    func clearWhenSelectionCleared() {
        let decision = PeekCompletion.decide(
            isLatest: true,
            stillLoading: true,
            selectedId: nil,
            readPaneId: started
        )
        #expect(decision == .clear)
    }

    @Test("A peek that is no longer the one on screen is dropped")
    func ignoreWhenSupersededOrClosed() {
        #expect(PeekCompletion.decide(
            isLatest: false,
            stillLoading: true,
            selectedId: moved,
            readPaneId: started
        ) == .ignore)
        #expect(PeekCompletion.decide(
            isLatest: false,
            stillLoading: true,
            selectedId: started,
            readPaneId: started
        ) == .ignore)
        // Arrowing away closes the spinner before this read returns.
        #expect(PeekCompletion.decide(
            isLatest: true,
            stillLoading: false,
            selectedId: moved,
            readPaneId: started
        ) == .ignore)
        #expect(PeekCompletion.decide(
            isLatest: true,
            stillLoading: false,
            selectedId: started,
            readPaneId: started
        ) == .ignore)
    }
}
