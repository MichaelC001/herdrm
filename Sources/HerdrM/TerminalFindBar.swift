import AppKit

/// Compact find bar overlaid on a terminal pane (⌘F). It only collects the
/// query and reports intent; the owner drives Ghostty's search binding actions.
final class TerminalFindBar: NSView, NSSearchFieldDelegate {
    var onQueryChange: ((String) -> Void)?
    var onNavigate: ((_ forward: Bool) -> Void)?
    var onClose: (() -> Void)?

    private let field = NSSearchField()

    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        applyColors()

        field.placeholderString = String(localized: "Find in terminal")
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.focusRingType = .none

        let previous = button("chevron.up", String(localized: "Previous match"), #selector(previousTapped))
        let next = button("chevron.down", String(localized: "Next match"), #selector(nextTapped))
        let close = button("xmark", String(localized: "Close find"), #selector(closeTapped))

        let stack = NSStackView(views: [field, previous, next, close])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 200),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // CGColors are resolved once, so re-resolve them when light/dark flips.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    /// ⌘G steps to the next match, ⇧⌘G to the previous one.
    static func stepDirection(for event: NSEvent) -> Bool? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.charactersIgnoringModifiers?.lowercased() == "g" else { return nil }
        if modifiers == .command { return true }
        if modifiers == [.command, .shift] { return false }
        return nil
    }

    /// True while the search field is being edited.
    var fieldHasFocus: Bool {
        (window?.firstResponder as? NSTextView)?.delegate === field
    }

    func focusField() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    private func button(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
            target: self,
            action: action
        )
        button.isBordered = false
        button.toolTip = label
        return button
    }

    @objc private func previousTapped() { onNavigate?(false) }
    @objc private func nextTapped() { onNavigate?(true) }
    @objc private func closeTapped() { onClose?() }

    // MARK: NSSearchFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        onQueryChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            onNavigate?(!shift)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

extension LineBreakTerminalView {
    /// ⌘F: show the find bar (or refocus it) and re-run the current query.
    func showFind() {
        let bar = findBar ?? makeFindBar()
        bar.isHidden = false
        bar.focusField()
        if !bar.query.isEmpty { search(bar.query) }
    }

    /// Find keys for a pane whose bar is open and either it or the terminal has
    /// focus: ⌘F re-focuses the field, ⌘G / ⇧⌘G step through matches. The field's
    /// editor sits below this view, so the owning view has to claim the keys.
    func handleFindKey(_ event: NSEvent) -> Bool {
        guard let bar = findBar, !bar.isHidden,
              window?.firstResponder === self || bar.fieldHasFocus else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
            showFind()
            return true
        }
        guard let forward = TerminalFindBar.stepDirection(for: event) else { return false }
        bar.onNavigate?(forward)
        return true
    }

    /// Esc / ✕: clear highlights and hand the keyboard back to the terminal.
    func hideFind() {
        guard let bar = findBar, !bar.isHidden else { return }
        bar.isHidden = true
        performBindingAction("end_search")
        window?.makeFirstResponder(self)
    }

    private func makeFindBar() -> TerminalFindBar {
        let bar = TerminalFindBar(frame: .zero)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        bar.onQueryChange = { [weak self] in self?.search($0) }
        bar.onNavigate = { [weak self] forward in
            // Ghostty orders matches newest-first, so its "next" climbs toward
            // older output. Find bars step down the screen on Return.
            self?.performBindingAction(forward ? "navigate_search:previous" : "navigate_search:next")
        }
        bar.onClose = { [weak self] in self?.hideFind() }
        findBar = bar
        return bar
    }

    private func search(_ query: String) {
        // An empty query would leave a search active that matches nothing.
        performBindingAction(query.isEmpty ? "end_search" : "search:\(query)")
    }
}

