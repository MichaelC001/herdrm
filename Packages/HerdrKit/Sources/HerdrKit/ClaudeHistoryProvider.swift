import Foundation

#if os(macOS)
/// Claude history read by HerdrM itself, for Local and SSH devices alike: the transcript
/// comes from `ClaudeTranscriptStore`, and a jump moves the pane's herdr viewport with
/// the official `pane.copy_search` and `pane.scroll` methods. Needs nothing from herdr
/// beyond the Claude session id it already reports for the pane.
public struct ClaudeHistoryProvider: ConversationHistoryProviding {
    private let store: ClaudeTranscriptStore
    private let device: Device
    private let service: HerdrService

    public init(store: ClaudeTranscriptStore, device: Device, service: HerdrService) {
        self.store = store
        self.device = device
        self.service = service
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
        do {
            // New output between the search and the scroll shifts the rows: search again.
            for _ in 0..<3 {
                let revision = try await service.paneContentRevision(paneID: target)
                let found: PaneSearchResult
                do {
                    found = try await service.searchPane(paneID: target, query: wanted.key, contentRevision: revision)
                } catch HerdrError.rpc(code: "stale_content", _) {
                    continue
                }
                let row = try Self.row(for: wanted, in: found.matches)
                guard let metrics = try await service.paneScrollMetrics(paneID: target) else {
                    throw ConversationJumpNotice.unavailable
                }
                guard try await service.paneContentRevision(paneID: target) == found.contentRevision else { continue }
                let landed = try await service.scrollPane(paneID: target, offsetFromBottom: Self.offset(showing: row, metrics: metrics))
                return ConversationJumpResult(
                    binding: index.binding, messageID: messageID, messageRevision: messageRevision,
                    contentSeq: found.contentRevision, sourceRow: UInt64(row),
                    offsetFromBottom: UInt64(max(0, landed?.offset ?? 0))
                )
            }
            throw ConversationJumpNotice.contentChanged
        } catch {
            throw ConversationJumpNotice.map(error)
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
