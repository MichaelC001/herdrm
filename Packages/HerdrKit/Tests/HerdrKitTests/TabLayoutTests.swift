import Foundation
import XCTest
@testable import HerdrKit

final class TabLayoutTests: XCTestCase {
    /// Captured from `layout.export {tab_id: "w1A:t3"}` on herdr 0.9.1 after
    /// `pane split --direction right --ratio 0.6` then `--direction down --ratio 0.3`.
    private let exportJSON = """
    {"workspace_id":"w1A","tab_id":"w1A:t3","zoomed":false,"focused_pane_id":"w1A:p3",
     "root":{"type":"split","direction":"right","ratio":0.6,
       "first":{"type":"pane","pane_id":"w1A:p3","cwd":"/Users/adulvac"},
       "second":{"type":"split","direction":"down","ratio":0.3,
         "first":{"type":"pane","pane_id":"w1A:p4","cwd":"/Users/adulvac"},
         "second":{"type":"pane","pane_id":"w1A:p5","cwd":"/Users/adulvac"}}}}
    """

    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

    private func decodeExport() throws -> TabLayoutDescription {
        try JSONDecoder().decode(TabLayoutDescription.self, from: Data(exportJSON.utf8))
    }

    func testDecodesLayoutExport() throws {
        let layout = try decodeExport()
        XCTAssertEqual(layout.workspaceID, "w1A")
        XCTAssertEqual(layout.tabID, "w1A:t3")
        XCTAssertFalse(layout.zoomed)
        XCTAssertEqual(layout.focusedPaneID, "w1A:p3")
        guard case .split(let direction, let ratio, let first, let second) = layout.root else {
            return XCTFail("root is not a split")
        }
        XCTAssertEqual(direction, .right)
        XCTAssertEqual(ratio, 0.6, accuracy: 1e-9)
        XCTAssertEqual(first, .pane(paneID: "w1A:p3"))
        guard case .split(.down, let inner, .pane("w1A:p4"), .pane("w1A:p5")) = second else {
            return XCTFail("second child is not the expected down split")
        }
        XCTAssertEqual(inner, 0.3, accuracy: 1e-9)
    }

    func testPaneIDsAreDepthFirstFirstBeforeSecond() throws {
        let layout = try decodeExport()
        XCTAssertEqual(layout.root.paneIDs, ["w1A:p3", "w1A:p4", "w1A:p5"])
        XCTAssertEqual(layout.root.paneCount, 3)
        XCTAssertEqual(LayoutNode.pane(paneID: nil).paneIDs, [])
    }

    func testLayoutNodeRoundTrips() throws {
        let layout = try decodeExport()
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(TabLayoutDescription.self, from: data), layout)
    }

    func testRejectsUnknownNodeType() {
        let json = Data(#"{"type":"tabs"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LayoutNode.self, from: json))
    }

    // MARK: - Geometry

    func testSinglePaneFillsTheBounds() {
        let solved = TabLayoutGeometry.solve(.pane(paneID: "a"), in: bounds, gap: 6)
        XCTAssertEqual(solved.panes, [PaneFrame(paneID: "a", rect: bounds)])
        XCTAssertTrue(solved.dividers.isEmpty)
    }

    func testNestedSplitsProduceTheExpectedFramesAndDividers() throws {
        let layout = try decodeExport()
        let solved = TabLayoutGeometry.solve(layout.root, in: bounds, gap: 10)

        // right 0.6 of 1000 with a 10pt gap: first gets 594, second starts at 604.
        let frames = Dictionary(uniqueKeysWithValues: solved.panes.map { ($0.paneID, $0.rect) })
        XCTAssertEqual(frames["w1A:p3"], CGRect(x: 0, y: 0, width: 594, height: 600))
        // down 0.3 of 600 with a 10pt gap inside the right column (396 wide).
        XCTAssertEqual(frames["w1A:p4"], CGRect(x: 604, y: 0, width: 396, height: 177))
        XCTAssertEqual(frames["w1A:p5"], CGRect(x: 604, y: 187, width: 396, height: 413))

        XCTAssertEqual(solved.dividers.count, 2)
        let root = try XCTUnwrap(solved.dividers.first { $0.path == SplitPath([]) })
        XCTAssertEqual(root.direction, .right)
        XCTAssertEqual(root.rect, CGRect(x: 594, y: 0, width: 10, height: 600))
        XCTAssertEqual(root.containerRect, bounds)

        let inner = try XCTUnwrap(solved.dividers.first { $0.path == SplitPath([true]) })
        XCTAssertEqual(inner.direction, .down)
        XCTAssertEqual(inner.rect, CGRect(x: 604, y: 177, width: 396, height: 10))
        XCTAssertEqual(inner.containerRect, CGRect(x: 604, y: 0, width: 396, height: 600))
    }

    func testOverridesReplaceTheTreeRatio() throws {
        let layout = try decodeExport()
        let solved = TabLayoutGeometry.solve(layout.root, in: bounds, gap: 0, overrides: [SplitPath([]): 0.5])
        let frames = Dictionary(uniqueKeysWithValues: solved.panes.map { ($0.paneID, $0.rect) })
        XCTAssertEqual(frames["w1A:p3"]?.width, 500)
        XCTAssertEqual(frames["w1A:p4"]?.minX, 500)
    }

    func testRatiosAreClampedToKeepBothSidesVisible() {
        let node = LayoutNode.split(direction: .down, ratio: 0.01, first: .pane(paneID: "a"), second: .pane(paneID: "b"))
        let low = TabLayoutGeometry.solve(node, in: bounds, gap: 0)
        XCTAssertEqual(low.panes[0].rect.height, 60)   // 0.1 floor
        let high = TabLayoutGeometry.solve(node, in: bounds, gap: 0, overrides: [SplitPath([]): 0.99])
        XCTAssertEqual(high.panes[0].rect.height, 540) // 0.9 ceiling
        XCTAssertEqual(TabLayoutGeometry.clampRatio(0.5), 0.5)
    }

    func testFramesAreWholePoints() {
        let node = LayoutNode.split(direction: .right, ratio: 1.0 / 3.0, first: .pane(paneID: "a"), second: .pane(paneID: "b"))
        let solved = TabLayoutGeometry.solve(node, in: CGRect(x: 0, y: 0, width: 1001, height: 601), gap: 7)
        for frame in solved.panes {
            XCTAssertEqual(frame.rect.minX, frame.rect.minX.rounded())
            XCTAssertEqual(frame.rect.width, frame.rect.width.rounded())
        }
        // The two panes and the gap tile the width exactly.
        XCTAssertEqual(solved.panes.map(\.rect.width).reduce(0, +) + 7, 1001)
    }

    func testDividerMapsPointerToRatio() {
        let divider = DividerFrame(
            path: SplitPath([true]), direction: .down,
            rect: CGRect(x: 604, y: 177, width: 396, height: 10),
            containerRect: CGRect(x: 604, y: 0, width: 396, height: 600)
        )
        XCTAssertEqual(divider.ratio(at: CGPoint(x: 700, y: 300)), 0.5)
        XCTAssertEqual(divider.ratio(at: CGPoint(x: 700, y: -50)), 0.1) // clamped
        let vertical = DividerFrame(path: SplitPath([]), direction: .right, rect: .zero, containerRect: bounds)
        XCTAssertEqual(vertical.ratio(at: CGPoint(x: 250, y: 0)), 0.25)
    }

    // MARK: - Neighbours

    func testNeighboursFollowTheGeometry() throws {
        // p3 | p4 (top right, 30%) / p5 (bottom right, 70%)
        let root = try decodeExport().root
        // Both right-hand panes touch p3; the one sharing more of its height wins.
        XCTAssertEqual(TabLayoutGeometry.neighbor(of: "w1A:p3", in: root, direction: .right), "w1A:p5")
        XCTAssertNil(TabLayoutGeometry.neighbor(of: "w1A:p3", in: root, direction: .left))
        XCTAssertEqual(TabLayoutGeometry.neighbor(of: "w1A:p4", in: root, direction: .left), "w1A:p3")
        XCTAssertEqual(TabLayoutGeometry.neighbor(of: "w1A:p4", in: root, direction: .down), "w1A:p5")
        XCTAssertEqual(TabLayoutGeometry.neighbor(of: "w1A:p5", in: root, direction: .up), "w1A:p4")
        XCTAssertEqual(TabLayoutGeometry.neighbor(of: "w1A:p5", in: root, direction: .left), "w1A:p3")
        XCTAssertNil(TabLayoutGeometry.neighbor(of: "w1A:p5", in: root, direction: .down))
        XCTAssertNil(TabLayoutGeometry.neighbor(of: "nope", in: root, direction: .down))
    }

    func testLeftNeighbourPrefersTheOneOverlappingMost() {
        let root = LayoutNode.split(
            direction: .right, ratio: 0.5,
            first: .split(direction: .down, ratio: 0.3, first: .pane(paneID: "tl"), second: .pane(paneID: "bl")),
            second: .pane(paneID: "r")
        )
        XCTAssertEqual(TabLayoutGeometry.neighbor(of: "r", in: root, direction: .left), "bl")
        XCTAssertEqual(TabLayoutGeometry.neighbor(of: "tl", in: root, direction: .right), "r")
    }
}
