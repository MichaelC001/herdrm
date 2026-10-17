import XCTest
@testable import herdrm

@MainActor
final class ConversationViewportMutationLaneTests: XCTestCase {
    func testReturnToLiveWaitsForAnAlreadyDispatchedJump() async {
        let lane = ConversationViewportMutationLane()
        var events: [String] = []
        var release: CheckedContinuation<Void, Never>?
        lane.submit(kind: .jump, key: "pane") {
            events.append("jump-start")
            await withCheckedContinuation { release = $0 }
            events.append("jump-ack")
        }
        await wait { release != nil }
        lane.submit(kind: .live, key: "pane") { events.append("live") }
        XCTAssertEqual(events, ["jump-start"])
        release?.resume()
        await wait { !lane.isRunning }
        XCTAssertEqual(events, ["jump-start", "jump-ack", "live"])
    }

    func testSelectionSnapCannotBeOvertakenByOldPaneJumpCompletion() async {
        let lane = ConversationViewportMutationLane()
        var events: [String] = []
        var release: CheckedContinuation<Void, Never>?
        lane.submit(kind: .jump, key: "A") {
            events.append("A-jump")
            await withCheckedContinuation { release = $0 }
            events.append("A-ack")
        }
        await wait { release != nil }
        lane.submit(kind: .snap, key: "B") { events.append("B-snap") }
        lane.submit(kind: .snap, key: "A") { events.append("A-snap") }
        lane.submit(kind: .jump, key: "A") { events.append("A-new-jump-failed") }
        release?.resume()
        await wait { !lane.isRunning }
        XCTAssertEqual(events, ["A-jump", "A-ack", "B-snap", "A-snap", "A-new-jump-failed"])
    }

    func testRapidPendingClicksCoalesceWithoutCancelingTheirPredecessorOrLiveBarrier() async {
        let lane = ConversationViewportMutationLane()
        var events: [String] = []
        var release: CheckedContinuation<Void, Never>?
        lane.submit(kind: .jump, key: "pane") {
            events.append("first")
            await withCheckedContinuation { release = $0 }
            events.append("first-ack")
        }
        await wait { release != nil }
        lane.submit(kind: .jump, key: "pane") { events.append("superseded") }
        lane.submit(kind: .jump, key: "pane") { events.append("latest") }
        lane.submit(kind: .live, key: "pane") { events.append("live") }
        release?.resume()
        await wait { !lane.isRunning }
        XCTAssertEqual(events, ["first", "first-ack", "latest", "live"])
    }

    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Navigation operation did not settle")
    }
}
