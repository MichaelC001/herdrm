import AppKit
import SwiftUI

/// A Canvas remains the rail's keyboard and accessibility surface. AppKit owns
/// pointer tracking so the retained terminal and SwiftUI focus host cannot
/// consume a rail click before it reaches the timeline.
struct ConversationRailPointerSurface: NSViewRepresentable {
    let activeRange: ClosedRange<CGFloat>?
    let onHover: (NSPoint?) -> Void
    let onClick: (NSPoint) -> Void

    func makeNSView(context: Context) -> ConversationRailPointerView {
        ConversationRailPointerView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    func updateNSView(_ view: ConversationRailPointerView, context: Context) {
        let changedRange = view.activeRange != activeRange
        view.activeRange = activeRange
        view.onHover = onHover
        view.onClick = onClick
        if changedRange { view.window?.invalidateCursorRects(for: view) }
    }
}

final class ConversationRailPointerView: NSView {
    var activeRange: ClosedRange<CGFloat>?
    var onHover: (NSPoint?) -> Void = { _ in }
    var onClick: (NSPoint) -> Void = { _ in }
    private var pointerTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Tracking-area mouseMoved delivery is opt-in on NSWindow. The rail
        // can be hosted before a native terminal has enabled that flag.
        window?.acceptsMouseMovedEvents = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, bounds.contains(local), activeRange?.contains(local.y) ?? true else { return nil }
        return self
    }

    override func updateTrackingAreas() {
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        let active = activeRange.map { NSRect(x: 0, y: $0.lowerBound, width: bounds.width, height: $0.upperBound - $0.lowerBound) } ?? bounds
        addCursorRect(active.intersection(bounds), cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) { hover(event) }
    override func mouseMoved(with event: NSEvent) { hover(event) }
    override func mouseExited(with event: NSEvent) { onHover(nil) }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), activeRange?.contains(point.y) ?? true else { return }
        // Deliberately avoid first-responder changes and super.mouseDown: this
        // navigation must never turn into an input event for the terminal.
        onClick(point)
    }

    private func hover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onHover(bounds.contains(point) ? point : nil)
    }
}
