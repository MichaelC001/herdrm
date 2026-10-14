import Foundation

/// Keys typed into the agent's attached terminal to move the program's own history:
/// Claude's fullscreen renderer keeps its transcript itself and scrolls it on these.
public enum AppScrollKey: Sendable {
    case pageUp
    case toBottom
}

#if os(macOS)
/// Claude history read by HerdrM itself, for Local and SSH devices alike: the transcript
/// comes from `ClaudeTranscriptStore`, and a jump moves the pane's herdr viewport with
/// the official `pane.copy_search` and `pane.scroll` methods. Needs nothing from herdr
/// beyond the Claude session id it already reports for the pane.
///
/// Claude in fullscreen mode draws on the alternate screen, so herdr holds no
/// scrollback for it. The jump then pages Claude's own history up through `appScroll`
/// (keys typed into the attach, as the user would) until the prompt is on screen.
public struct ClaudeHistoryProvider: ConversationHistoryProviding {
    public typealias AppScroll = @Sendable (AppScrollKey) async -> Bool

    private let store: ClaudeTranscriptStore
    private let device: Device
    private let service: HerdrService
    private let appScroll: AppScroll?
    /// Fullscreen jumps give up after this many pages and return to the bottom.
    static let maximumPages = 120
    /// How long a page may take to redraw before the history counts as at its top.
    private let pageSettle: Duration

    public init(store: ClaudeTranscriptStore, device: Device, service: HerdrService,
                appScroll: AppScroll? = nil, pageSettle: Duration = .milliseconds(250)) {
        self.store = store
        self.device = device
        self.service = service
        self.appScroll = appScroll
        self.pageSettle = pageSettle
    }

    public func read(target: String, expectedSessionID: String, window: ConversationWindow, limits: ConversationLimits = .init()) async throws -> ConversationPage {
        switch try await store.snapshot(device: device, sessionID: expectedSessionID) {
        case .unavailable(let reason): return ConversationPage(availability: reason)
        case .ready(let index): return try index.page(window, limits: limits)
        }
    }

    public func readBlock(target: String, expectedSessionID: String, blockCursor: String, maxBytes: Int = 1_048_576) async throws -> BlockPage {
        guard case .ready(let index) = try await store.snapshot(device: device, sessionID: expectedSessionID) else {
            throw ConversationHistoryError.disconnected
        }
        return try index.block(cursor: blockCursor, maxBytes: maxBytes)
    }

    public func jump(target: String, expectedSessionID: String, expectedGeneration: String, messageID: String, messageRevision: String) async throws -> ConversationJumpResult {
        guard case .ready(let index) = try await store.snapshot(device: device, sessionID: expectedSessionID) else {
            throw ConversationJumpNotice.sourceMissing
        }
        guard index.generation == expectedGeneration else { throw ConversationJumpNotice.sourceChanged }
        let wanted = try index.jumpTarget(messageID: messageID, messageRevision: messageRevision)
        func result(row: Int, revision: UInt64, offset: Int, scrolledApp: Bool = false) -> ConversationJumpResult {
            ConversationJumpResult(binding: index.binding, messageID: messageID, messageRevision: messageRevision,
                                   contentSeq: revision, sourceRow: UInt64(row), offsetFromBottom: UInt64(max(0, offset)),
                                   scrolledApp: scrolledApp)
        }
        do {
            // New output between the search and the scroll shifts the rows: search again.
            for _ in 0..<3 {
                guard let found = try await search(target, for: wanted.key) else { continue }
                guard let metrics = try await service.paneScrollMetrics(paneID: target) else {
                    throw ConversationJumpNotice.unavailable
                }
                let row: Int
                do {
                    row = try Self.row(for: wanted, in: found.matches)
                } catch ConversationJumpNotice.notFound where metrics.maxOffsetFromBottom == 0 && appScroll != nil {
                    return try await pageAppHistory(target, for: wanted, result: result)
                }
                guard try await service.paneContentRevision(paneID: target) == found.contentRevision else { continue }
                let landed = try await service.scrollPane(paneID: target, offsetFromBottom: Self.offset(showing: row, metrics: metrics))
                return result(row: row, revision: found.contentRevision, offset: landed?.offset ?? 0)
            }
            throw ConversationJumpNotice.contentChanged
        } catch {
            throw ConversationJumpNotice.map(error)
        }
    }

    /// Pages the program's own history up until the prompt is on screen. Scrolling up,
    /// the first match is the newest one, so only the newest of the prompts sharing
    /// this start can be found this way. Returns to the bottom when it gives up.
    ///
    /// Each page costs one screen read once the redraw has settled, searched here: a
    /// copy-mode search would need two more round trips per page to the device.
    private func pageAppHistory(_ pane: String, for wanted: ClaudeTranscriptIndex.JumpTarget,
                                result: (Int, UInt64, Int, Bool) -> ConversationJumpResult) async throws -> ConversationJumpResult {
        guard let appScroll, wanted.occurrence == wanted.occurrences - 1 else { throw ConversationJumpNotice.notFound }
        var screen = try await service.readPaneText(paneID: pane)
        for page in 1...Self.maximumPages {
            guard await appScroll(.pageUp) else { throw ConversationJumpNotice.unavailable }
            guard let next = try await settledScreen(pane, after: screen) else { break }  // top of the history
            screen = next
            if let row = Self.promptRow(of: wanted.key, in: screen) {
                return result(row, 0, page, true)
            }
        }
        _ = await appScroll(.toBottom)
        throw ConversationJumpNotice.notFound
    }

    /// The screen once the program has redrawn after a key: read until its history part
    /// differs from `previous` and two reads in a row agree, so a half-drawn frame is
    /// never searched. nil when nothing moved within `pageSettle`: the top of the history.
    private func settledScreen(_ pane: String, after previous: String) async throws -> String? {
        let deadline = ContinuousClock.now + pageSettle
        let before = Self.historyPart(previous)
        var last = before
        while true {
            try await Task.sleep(for: Self.pollInterval)
            let screen = try await service.readPaneText(paneID: pane)
            let history = Self.historyPart(screen)
            let moved = history != before
            if moved, history == last { return screen }
            if !moved, ContinuousClock.now >= deadline { return nil }
            if moved, ContinuousClock.now >= deadline + pageSettle { return screen }
            last = history
        }
    }

    /// The upper two thirds of the screen. A working Claude redraws its spinner and
    /// status lines at the bottom all the time; only the history above them scrolls.
    static func historyPart(_ screen: String) -> ArraySlice<Substring> {
        let rows = screen.split(separator: "\n", omittingEmptySubsequences: false)
        return rows.prefix(max(1, rows.count * 2 / 3))
    }

    static let pollInterval: Duration = .milliseconds(15)

    /// The row on `screen` where a prompt starting with `key` is drawn at the left edge.
    static func promptRow(of key: String, in screen: String) -> Int? {
        let rows = screen.split(separator: "\n", omittingEmptySubsequences: false)
        return rows.lastIndex { row in
            guard let range = row.range(of: key) else { return false }
            return row.distance(from: row.startIndex, to: range.lowerBound) <= 4
        }
    }

    /// One copy-mode search; nil when output landed between reading the revision and searching.
    private func search(_ pane: String, for key: String) async throws -> PaneSearchResult? {
        let revision = try await service.paneContentRevision(paneID: pane)
        do {
            return try await service.searchPane(paneID: pane, query: key, contentRevision: revision)
        } catch HerdrError.rpc(code: "stale_content", _) {
            return nil
        }
    }

    /// The terminal row of the wanted prompt. Prompts render at the left edge, so a
    /// match further right is Claude quoting it. Older prompts may have scrolled out
    /// of herdr's history, so the matches left are the transcript's newest ones.
    static func row(for target: ClaudeTranscriptIndex.JumpTarget, in matches: [PaneTextMatch]) throws -> Int {
        let rows = Array(Set(matches.filter { $0.col <= 4 }.map(\.row))).sorted()
        guard !rows.isEmpty else { throw ConversationJumpNotice.notFound }
        guard rows.count <= target.occurrences else { throw ConversationJumpNotice.ambiguous }
        let index = target.occurrence - (target.occurrences - rows.count)
        guard index >= 0 else { throw ConversationJumpNotice.notFound }
        return rows[index]
    }

    /// Offset from the bottom that puts `row` one line below the top of the viewport.
    static func offset(showing row: Int, metrics: PaneScrollMetrics) -> Int {
        let top = max(0, row - 1)
        return min(metrics.maxOffsetFromBottom, max(0, metrics.maxOffsetFromBottom - top))
    }
}
#endif
