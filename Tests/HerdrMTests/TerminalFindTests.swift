import AppKit
import XCTest
@testable import herdrm

/// Drives the real terminal view, find bar and window with real key events.
/// The libghostty surface is absent here, so these cover the routing — which
/// view claims which key, and what the bar reports — not Ghostty's matching.
@MainActor
final class TerminalFindTests: XCTestCase {
    private var window: NSWindow!
    private var view: LineBreakTerminalView!
    /// Every `onNavigate` the bar reports, `true` = step down / next.
    private var steps: [Bool] = []

    override func setUp() {
        super.setUp()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        view = LineBreakTerminalView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        window.makeFirstResponder(view)
        steps = []
    }

    override func tearDown() {
        window = nil
        view = nil
        super.tearDown()
    }

    private func key(_ chars: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: 0
        )!
    }

    /// Opens the bar the way ⌘F does, then records what it reports.
    private func openBar() -> TerminalFindBar {
        view.showFind()
        let bar = try! XCTUnwrap(view.findBar)
        bar.onNavigate = { [unowned self] in steps.append($0) }
        return bar
    }

    func testShowFindMovesKeyboardFocusIntoTheField() {
        let bar = openBar()
        XCTAssertFalse(bar.isHidden)
        XCTAssertTrue(bar.fieldHasFocus)
    }

    /// The bug that shipped broken: with the field focused, the terminal view's
    /// key handler ran first and returned early, so ⌘G never reached the bar.
    func testCommandGStepsWhileTheFieldHasFocus() {
        let bar = openBar()
        XCTAssertTrue(bar.fieldHasFocus)
        XCTAssertTrue(view.performKeyEquivalent(with: key("g", .command)))
        XCTAssertTrue(view.performKeyEquivalent(with: key("g", [.command, .shift])))
        XCTAssertEqual(steps, [true, false])
    }

    func testCommandGStepsWhileTheTerminalHasFocusAndTheBarIsOpen() {
        _ = openBar()
        window.makeFirstResponder(view)
        XCTAssertTrue(view.performKeyEquivalent(with: key("g", .command)))
        XCTAssertEqual(steps, [true])
    }

    func testCommandFWhileFieldHasFocusKeepsTheBarAndFocus() {
        let bar = openBar()
        XCTAssertTrue(view.performKeyEquivalent(with: key("f", .command)))
        XCTAssertFalse(bar.isHidden)
        XCTAssertTrue(bar.fieldHasFocus)
    }

    func testFindKeysAreLeftAloneWhenTheBarIsClosed() {
        XCTAssertFalse(view.handleFindKey(key("g", .command)))
        _ = openBar()
        view.hideFind()
        XCTAssertFalse(view.handleFindKey(key("g", .command)))
        XCTAssertEqual(steps, [])
    }

    func testOtherModifiersOnGAreNotClaimed() {
        _ = openBar()
        for modifiers: NSEvent.ModifierFlags in [[], .shift, .control, [.command, .option]] {
            XCTAssertFalse(view.handleFindKey(key("g", modifiers)), "\(modifiers)")
        }
        XCTAssertEqual(steps, [])
    }

    /// A pane that is not the one being searched must not react: kept-alive and
    /// split panes all receive `performKeyEquivalent`.
    func testAnotherPanesBarDoesNotClaimTheKeys() {
        _ = openBar()
        let other = LineBreakTerminalView(frame: view.frame)
        window.contentView!.addSubview(other)
        other.showFind()
        window.makeFirstResponder(view)
        // `view`'s bar is open and `view` has focus; `other`'s bar is open but
        // neither it nor its field has focus.
        XCTAssertFalse(other.handleFindKey(key("g", .command)))
        XCTAssertTrue(view.handleFindKey(key("g", .command)))
    }

    func testEscapeClosesTheBarAndReturnsFocusToTheTerminal() {
        let bar = openBar()
        XCTAssertTrue(bar.control(
            NSControl(), textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        ))
        XCTAssertTrue(bar.isHidden)
        XCTAssertTrue(window.firstResponder === view)
    }

    func testReturnStepsDown() {
        let bar = openBar()
        XCTAssertTrue(bar.control(
            NSControl(), textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        XCTAssertEqual(steps, [true])
    }

    func testTypingReportsTheQuery() {
        let bar = openBar()
        var queries: [String] = []
        bar.onQueryChange = { queries.append($0) }
        bar.query = "a b:c\\d"
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertEqual(queries, ["a b:c\\d"])
    }
}
