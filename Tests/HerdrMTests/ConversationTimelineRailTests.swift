import XCTest
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
        XCTAssertEqual(geometry.position(of: 0), 10)
        XCTAssertEqual(geometry.position(of: 49), 490)
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
    }
}
