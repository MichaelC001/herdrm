import XCTest
@testable import herdrm

final class ClaudeImageBoxesTests: XCTestCase {
    // Captured from Claude Code 2.1.302 on 2026-10-18, two images pasted.
    private let twoBoxes = """
    ╭────────────────────╮ ╭────────────────────╮
    │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│ │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│
    │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│ │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│
    │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│ │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│
    │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│ │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│
    │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│ │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│
    │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│ │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│
    │         #1         │ │         #2         │
    ╰────────────────────╯ ╰────────────────────╯

    ────────────────────────────────────────────
    ❯ [Image #1] [Image #2]
    """

    func testFindsTwoBoxesSideBySideWithTheirInteriors() {
        let boxes = ClaudeImageBoxes.boxes(in: "header\n" + twoBoxes)
        XCTAssertEqual(boxes, [
            ClaudeImageBox(number: 1, interior: CellRect(row: 2, column: 1, rows: 6, columns: 20)),
            ClaudeImageBox(number: 2, interior: CellRect(row: 2, column: 24, rows: 6, columns: 20)),
        ])
    }

    func testBlankInteriorStillCounts() {
        // Kitty placeholders read as blanks; the frame and label decide.
        let text = "╭────╮\n│    │\n│    │\n│ #3 │\n╰────╯"
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: text),
                       [ClaudeImageBox(number: 3, interior: CellRect(row: 1, column: 1, rows: 2, columns: 4))])
    }

    func testTwoDigitNumberAndWiderFrame() {
        let inner = String(repeating: "─", count: 28)
        let text = "╭\(inner)╮\n│" + String(repeating: " ", count: 28) + "│\n│" + String(repeating: " ", count: 11) + "#12" + String(repeating: " ", count: 14) + "│\n╰\(inner)╯"
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: text).map(\.number), [12])
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: text).first?.interior.columns, 28)
    }

    func testFrameWithoutLabelIsNotABox() {
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: "╭────╮\n│    │\n│    │\n╰────╯"), [])
    }

    func testLabelWithoutBordersIsNotABox() {
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: "│ #1 │\n"), [])
    }

    func testBoxCutOffAtTopIsNotABox() {
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: "│    │\n│ #1 │\n╰────╯"), [])
    }

    func testTruncatedRightBorderIsNotABox() {
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: "╭────╮\n│    │\n│ #1\n╰────╯"), [])
    }

    func testEmptyViewport() {
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: ""), [])
    }
}
