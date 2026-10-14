import XCTest
import HerdrKit
@testable import herdrm

final class ConversationTimelineRailTests: XCTestCase {
    func testEmptyAndSingleTurn() {
        let empty = ConversationRailGeometry(count: 0, height: 500)
        XCTAssertNil(empty.index(at: 10))
        XCTAssertEqual(empty.marks(selectedIndex: nil), [])
        let single = ConversationRailGeometry(count: 1, height: 500)
        XCTAssertEqual(single.position(of: 0), 250)
        XCTAssertEqual(single.index(at: -100), 0)
        XCTAssertEqual(single.marks(selectedIndex: 0).first?.isSelected, true)
    }

    func testFiftyTurnsKeepOldestAtTopAndExactTurnMapping() {
        let geometry = ConversationRailGeometry(count: 50, height: 500)
        XCTAssertEqual(geometry.position(of: 0), 103)
        XCTAssertEqual(geometry.position(of: 49), 397)
        XCTAssertEqual(geometry.marks(selectedIndex: 25).count, 50)
        for index in 0..<50 { XCTAssertEqual(geometry.index(at: geometry.position(of: index)), index) }
        XCTAssertEqual(geometry.index(at: -10), 0)
        XCTAssertEqual(geometry.index(at: 1000), 49)
    }

    func testFiveThousandTurnsUseBoundedClustersAndExposeEveryIndex() {
        let geometry = ConversationRailGeometry(count: 5_000, height: 500)
        let marks = geometry.marks(selectedIndex: 2_321)
        XCTAssertLessThanOrEqual(marks.count, 121)
        XCTAssertEqual(marks.flatMap { Array($0.indices) }, Array(0..<5_000))
        XCTAssertEqual(marks.filter(\.isSelected).count, 1)
        XCTAssertTrue(marks.first(where: \.isSelected)!.indices.contains(2_321))
        XCTAssertEqual(marks.first?.indices.lowerBound, 0)
        XCTAssertEqual(marks.last?.indices.upperBound, 5_000)
        for index in [0, 1, 57, 2_321, 4_999] {
            XCTAssertEqual(geometry.index(at: geometry.position(of: index)), index)
        }
    }

    func testKeyboardTraversalIsChronologicalAndClamped() {
        XCTAssertNil(ConversationRailGeometry.adjacent(nil, delta: 1, count: 0))
        XCTAssertEqual(ConversationRailGeometry.adjacent(nil, delta: 1, count: 50), 0)
        XCTAssertEqual(ConversationRailGeometry.adjacent(nil, delta: -1, count: 50), 49)
        XCTAssertEqual(ConversationRailGeometry.adjacent(25, delta: 1, count: 50), 26)
        XCTAssertEqual(ConversationRailGeometry.adjacent(0, delta: -1, count: 50), 0)
        XCTAssertEqual(ConversationRailGeometry.adjacent(49, delta: 1, count: 50), 49)
    }

    func testVeryShortRailStillHasBoundedValidGeometry() {
        let geometry = ConversationRailGeometry(count: 5_000, height: 10)
        XCTAssertEqual(geometry.marks(selectedIndex: nil).count, 1)
        XCTAssertEqual(geometry.index(at: 5), 0)
        XCTAssertEqual(geometry.position(of: 0), 5)
        XCTAssertEqual(geometry.position(of: 4_999), 5)
    }

    func testDenseHistoryAndHoverStayAboveTheTerminalInputArea() {
        for viewportHeight in [CGFloat(0), 12, 48, 200, 500, 1_500] {
            let viewport = ConversationRailViewport(height: viewportHeight)
            for count in [1, 12, 5_000] {
                for focus in [nil, 0, count / 2, count - 1] as [Int?] {
                    let geometry = ConversationRailGeometry(count: count, height: viewport.height, zoomedIndex: focus)
                    for mark in geometry.marks(selectedIndex: focus) {
                        let position = viewport.topInset + mark.y
                        XCTAssertGreaterThanOrEqual(position, 0)
                        XCTAssertLessThanOrEqual(position, viewportHeight * 0.8)
                    }
                }
            }
        }
    }

    func testShortConversationStaysPackedAndHoverGrowthTapersAcrossNeighbors() {
        let geometry = ConversationRailGeometry(count: 12, height: 1_000)
        XCTAssertEqual(geometry.span, 66)
        XCTAssertEqual(geometry.position(of: 1) - geometry.position(of: 0), 6)
        XCTAssertEqual((geometry.position(of: 0) + geometry.position(of: 11)) / 2, 500)
        let widths = (5...11).map {
            ConversationRailGeometry.markWidth(indices: $0..<($0 + 1), selected: false, previewIndex: 5)
        }
        XCTAssertEqual(widths, [30, 24, 20, 16, 12, 9, 7])
        XCTAssertEqual(ConversationRailGeometry.markWidth(indices: 5..<6, selected: false, previewIndex: nil), 7)
    }

    func testHoverLensExpandsNearbyMarksWithoutChangingTheirOrderOrIdentity() {
        let plain = ConversationRailGeometry(count: 5_000, height: 500)
        for focus in [0, 1, 57, 2_321, 4_998, 4_999] {
            let zoomed = ConversationRailGeometry(count: 5_000, height: 500, zoomedIndex: focus)
            XCTAssertEqual(zoomed.position(of: focus), plain.position(of: focus), accuracy: 0.001)
            let positions = (0..<5_000).map { zoomed.position(of: $0) }
            XCTAssertEqual(positions, positions.sorted())
            for index in [0, max(0, focus - 1), focus, min(4_999, focus + 1), 4_999] {
                XCTAssertEqual(zoomed.index(at: zoomed.position(of: index)), index)
            }
            let marks = zoomed.marks(selectedIndex: focus)
            XCTAssertEqual(marks.flatMap { Array($0.indices) }, Array(0..<5_000))
            XCTAssertLessThanOrEqual(marks.count, 150)
            XCTAssertEqual(marks.filter(\.isSelected).count, 1)
        }
        let center = ConversationRailGeometry(count: 5_000, height: 500, zoomedIndex: 2_500)
        XCTAssertGreaterThan(center.position(of: 2_501) - center.position(of: 2_500), 10)
        XCTAssertEqual(center.marks(selectedIndex: 2_500).first(where: \.isSelected)?.indices, 2_500..<2_501)
    }

    func testSelectedClaudeReplyHighlightsItsHumanTurn() {
        let turns = [ConversationTurn(id: "turn", messageID: "prompt")]
        let messages = [ConversationMessage(id: "reply", turnID: "turn", role: "assistant")]
        XCTAssertEqual(ConversationRailSelection.index(messageID: "reply", turns: turns, messages: messages), 0)
        XCTAssertEqual(ConversationRailSelection.index(messageID: "prompt", turns: turns, messages: messages), 0)
        XCTAssertNil(ConversationRailSelection.index(messageID: "unrelated", turns: turns, messages: messages))
    }

    func testCompactPreviewUsesPromptHeadingAndOnlyItsCachedReply() {
        let turn = ConversationTurn(id: "turn", messageID: "prompt", preview: "status")
        let replies = [
            ConversationMessage(id: "other", turnID: "another", role: "assistant", blocks: [.init(id: "t", kind: "text", text: "Wrong conversation")]),
            ConversationMessage(id: "reply", turnID: "turn", role: "assistant", blocks: [.init(id: "t", kind: "text", text: "Latest checkpoint: 世界 🌍")])
        ]
        let preview = ConversationRailPreview(turn: turn, messages: replies)
        XCTAssertEqual(preview.title, "status")
        XCTAssertEqual(preview.body, "Latest checkpoint: 世界 🌍")
        let multiline = ConversationRailPreview(turn: .init(id: "turn", messageID: "prompt", preview: "Review this\nKeep whitespace and Unicode 世界"), messages: [])
        XCTAssertEqual(multiline.title, "Review this")
        XCTAssertEqual(multiline.body, "Keep whitespace and Unicode 世界")
    }
}
