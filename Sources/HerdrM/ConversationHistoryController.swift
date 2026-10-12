import Foundation
import Combine
import HerdrKit

/// Serializes even cancellation-insensitive socket transports across visibility changes.
private actor ConversationReadGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func perform<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if locked { await withCheckedContinuation { waiters.append($0) } }
        else { locked = true }
        defer {
            if waiters.isEmpty { locked = false }
            else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await operation()
    }
}

public enum ConversationHistoryState: Equatable {
    case idle, loading, ready
    case unavailable(String), failed(String)
}

/// Only the selected, visible pane owns reads. No transcript content is persisted.
@MainActor
public final class ConversationHistoryController: ObservableObject {
    @Published public private(set) var messages: [ConversationMessage] = []
    @Published public private(set) var turns: [ConversationTurn] = []
    @Published public private(set) var state: ConversationHistoryState = .idle
    @Published public private(set) var completeness = "source_available"
    @Published public private(set) var selectedMessageID: String?
    @Published public private(set) var matchedMessageIDs: [String] = []
    @Published public private(set) var hasNewMessages = false
    @Published public private(set) var isLoadingOlder = false
    @Published public private(set) var isLoadingNewer = false
    @Published public private(set) var canLoadOlder = false
    @Published public private(set) var canLoadNewer = false
    @Published public private(set) var copyInProgress = false
    @Published public var isPresented = false { didSet { restartPolling() } }
    @Published public var searchQuery = ""

    private struct Selection: Equatable, Sendable {
        let deviceID: UUID
        let paneID: String
        let sessionID: String
    }
    private let readGate = ConversationReadGate()
    private var selection: Selection?
    private var provider: (any ConversationHistoryProviding)?
    private var epoch = UUID()
    private var binding: ConversationBinding?
    private var appliedChangesRevision = ""
    private var beforeCursor: String?
    private var afterCursor: String?
    private var changesCursor: String?
    private var visible = false
    private var followingLatest = true
    private var requestTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var queue: [ConversationWindow] = []
    private var copyToken: UUID?
    private var copyingMessageID: String?
    private var pageIDs: [[String]] = []
    private var cacheSizes: [String: Int] = [:]
    private struct PageAnchor { let before: String?; let after: String? }
    private var navigationAnchors: [String: PageAnchor] = [:]
    private var failures = 0
    private var queryGeneration = UUID()
    private let pollingSleep: @Sendable (TimeInterval) async throws -> Void
    private let maximumPages = 8
    private let maximumBytes = 8 * 1_048_576

    public init() {
        pollingSleep = { delay in try await Task.sleep(for: .seconds(delay)) }
    }
    /// Fixture clock seam; production always uses cancellable Task sleep.
    init(pollingSleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.pollingSleep = pollingSleep
    }
    deinit { requestTask?.cancel(); pollingTask?.cancel() }

    public func select(deviceID: UUID, paneID: String, session: AgentSessionRef?, provider: any ConversationHistoryProviding) {
        let sessionID = session?.sessionID ?? ""
        let next = Selection(deviceID: deviceID, paneID: paneID, sessionID: sessionID)
        if selection == next {
            self.provider = sessionID.isEmpty ? nil : provider
            if sessionID.isEmpty { state = .unavailable("no_binding"); return }
            if case .unavailable("disconnected") = state, visible { refresh() }
            return
        }
        resetRequests()
        clearContent()
        selection = next
        self.provider = sessionID.isEmpty ? nil : provider
        followingLatest = true
        if sessionID.isEmpty { state = .unavailable("no_binding") }
        else if visible { enqueue(.latest) }
        restartPolling()
    }

    public func stop() {
        resetRequests()
        selection = nil; provider = nil; visible = false; isPresented = false
        clearContent(); state = .idle
    }
    public func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        if visible {
            if selection != nil { refresh() }
        } else {
            resetRequests()
            copyToken = nil; copyingMessageID = nil; copyInProgress = false
        }
        restartPolling()
    }
    public func open(turnID: String? = nil) {
        isPresented = true
        if let turnID, let turn = turns.first(where: { $0.id == turnID }) { selectMessage(turn.messageID) }
        else if messages.isEmpty { enqueue(.latest) }
    }
    public func close() { isPresented = false }
    public func refresh() {
        guard selection != nil else { return }
        enqueue(changesCursor.map { .changes(cursor: $0) } ?? .latest)
    }
    public func search(_ query: String) {
        searchQuery = query
        queryGeneration = UUID()
        matchedMessageIDs = []
        queue.removeAll { if case .search = $0 { return true }; return false }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        enqueue(.search(query: query))
    }
    public func loadOlder() {
        guard visible, let cursor = beforeCursor, !isLoadingOlder else { return }
        followingLatest = false; isLoadingOlder = true
        enqueue(.before(cursor: cursor))
    }
    public func loadNewer() {
        guard visible, let cursor = afterCursor, !isLoadingNewer else { return }
        isLoadingNewer = true; enqueue(.after(cursor: cursor))
    }
    public func selectMessage(_ id: String) {
        selectedMessageID = id; followingLatest = false
        promotePage(containing: id)
        if let anchor = navigationAnchors[id], messages.contains(where: { $0.id == id }) {
            beforeCursor = anchor.before; afterCursor = anchor.after
            canLoadOlder = beforeCursor != nil; canLoadNewer = afterCursor != nil
        } else { enqueue(.around(messageID: id)) }
    }
    public func nextTurn() { navigateTurn(delta: 1) }
    public func previousTurn() { navigateTurn(delta: -1) }
    private func navigateTurn(delta: Int) {
        guard !turns.isEmpty else { return }
        let current = turns.firstIndex(where: { $0.messageID == selectedMessageID }) ?? (delta > 0 ? -1 : turns.count)
        let next = min(turns.count - 1, max(0, current + delta))
        selectMessage(turns[next].messageID)
    }
    public func showLatest() {
        followingLatest = true; hasNewMessages = false
        enqueue(.latest)
    }

    private func resetRequests() {
        epoch = UUID(); requestTask?.cancel(); requestTask = nil
        pollingTask?.cancel(); pollingTask = nil; queue = []
        isLoadingOlder = false; isLoadingNewer = false
        copyToken = nil; copyingMessageID = nil; copyInProgress = false
    }
    private func clearContent() {
        messages = []; turns = []; matchedMessageIDs = []; pageIDs = []; cacheSizes = [:]; navigationAnchors = [:]
        binding = nil; appliedChangesRevision = ""; completeness = "source_available"; beforeCursor = nil; afterCursor = nil; changesCursor = nil
        canLoadOlder = false; canLoadNewer = false; selectedMessageID = nil; hasNewMessages = false
        failures = 0; searchQuery = ""; queryGeneration = UUID()
    }
    private func enqueue(_ window: ConversationWindow) {
        guard selection != nil, provider != nil, visible else { return }
        if !queue.contains(window) { queue.append(window) }
        drain()
    }
    private func drain() {
        guard requestTask == nil, !copyInProgress, !queue.isEmpty, let selection, let provider else { return }
        let window = queue.removeFirst(), token = epoch, queryToken = queryGeneration
        let gate = readGate
        if messages.isEmpty { state = .loading }
        requestTask = Task { [weak self] in
            do {
                let page = try await gate.perform { try await provider.read(target: selection.paneID, expectedSessionID: selection.sessionID, window: window, limits: .init()) }
                guard let self, self.epoch == token, !Task.isCancelled else { return }
                if case .search = window, self.queryGeneration != queryToken {
                    self.requestTask = nil; self.drain(); return
                }
                self.apply(page, window: window)
                if page.availability == "ready" { self.failures = 0 }
            } catch {
                guard let self, self.epoch == token, !Task.isCancelled else { return }
                self.handle(ConversationHistoryError.map(error))
            }
            guard let self, self.epoch == token else { return }
            if case .before = window { self.isLoadingOlder = false }
            if case .after = window { self.isLoadingNewer = false }
            self.requestTask = nil
            self.drain()
        }
    }
    private func apply(_ page: ConversationPage, window: ConversationWindow) {
        guard page.availability == "ready" else {
            let previousFailures = failures
            clearContent()
            failures = min(previousFailures + 1, 5)
            state = .unavailable(page.availability)
            return
        }
        guard let incoming = page.binding, incoming.provider == "claude", incoming.sessionID == selection?.sessionID else {
            clearContent(); state = .unavailable("session_changed"); return
        }
        if let binding, binding != incoming {
            clearContent(); self.binding = incoming
            queue = [.latest]; return
        }
        binding = incoming
        completeness = page.completeness
        let changed = !appliedChangesRevision.isEmpty && appliedChangesRevision != page.revision
        let removed = Set(page.removedMessageIDs)
        messages.removeAll { removed.contains($0.id) }
        for id in removed { cacheSizes.removeValue(forKey: id); navigationAnchors.removeValue(forKey: id) }
        turns.removeAll { removed.contains($0.messageID) }
        matchedMessageIDs.removeAll { removed.contains($0) }
        let oldIDs = Set(messages.map(\.id))
        switch window {
        case .latest, .before, .after, .around:
            for message in page.messages { navigationAnchors[message.id] = .init(before: page.beforeCursor, after: page.afterCursor) }
        default: break
        }
        mergeMessages(page.messages + page.upserts)
        if !followingLatest, page.upserts.contains(where: { !oldIDs.contains($0.id) }) { hasNewMessages = true }
        var indexed = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for turn in page.turns { indexed[turn.id] = turn }
        turns = indexed.values.sorted { $0.ordinal < $1.ordinal }
        switch window {
        case .latest:
            beforeCursor = page.beforeCursor; afterCursor = page.afterCursor
            // A navigation read must not skip unapplied edits to cached older bodies.
            if changesCursor == nil { changesCursor = page.changesCursor }
            if appliedChangesRevision.isEmpty { appliedChangesRevision = page.revision }
            if followingLatest { selectedMessageID = messages.last?.id }
        case .before, .after:
            // These cursors anchor the current body page, including its evicted neighbours.
            // Initial latest endpoint cursors no longer describe the page being browsed.
            beforeCursor = page.beforeCursor; afterCursor = page.afterCursor
        case .around:
            beforeCursor = page.beforeCursor; afterCursor = page.afterCursor
        case .changes:
            appliedChangesRevision = page.revision
            changesCursor = page.changesCursor ?? changesCursor
            if changed, !searchQuery.isEmpty { search(searchQuery) }
            if followingLatest { selectedMessageID = messages.last?.id }
        case .search(let query, _):
            for id in page.matchMessageIDs where !matchedMessageIDs.contains(id) { matchedMessageIDs.append(id) }
            if let cursor = page.searchCursor { enqueue(.search(query: query, cursor: cursor)) }
        case .turns: break
        }
        // A continuation is meaningful only for initial/index/change reads, never search pagination.
        if let cursor = page.turnsCursor { enqueue(.turns(cursor: cursor)) }
        canLoadOlder = beforeCursor != nil
        canLoadNewer = afterCursor != nil
        state = .ready
    }
    private func mergeMessages(_ incoming: [ConversationMessage]) {
        guard !incoming.isEmpty else { return }
        var items = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        pageIDs = pageIDs.map { $0.filter { items[$0] != nil } }.filter { !$0.isEmpty }
        let ownedIDs = Set(pageIDs.flatMap { $0 })
        let newIDs = Set(incoming.map(\.id)).subtracting(ownedIDs)
        // Revisions update the original page so an active body does not migrate to a
        // background insertion page. Access promotes recency; writes do not.
        if !newIDs.isEmpty { pageIDs.append(Array(newIDs)) }
        for message in incoming {
            items[message.id] = message
            cacheSizes[message.id] = (try? JSONEncoder().encode(message).count) ?? maximumBytes + 1
        }
        var bytes = cacheSizes.values.reduce(0, +)
        while pageIDs.count > maximumPages || bytes > maximumBytes {
            guard pageIDs.count > 1 else { break }
            guard let index = pageIDs.firstIndex(where: { !isProtected($0) }) else { break }
            let evicted = pageIDs.remove(at: index)
            for id in evicted {
                items.removeValue(forKey: id)
                bytes -= cacheSizes.removeValue(forKey: id) ?? 0
            }
        }
        // An untrusted provider can return a single oversized page. Bound that too.
        while bytes > maximumBytes {
            let candidates = items.values.filter { $0.id != selectedMessageID && $0.id != copyingMessageID }
            // The cap still wins for a malformed oversized protected body.
            guard let oldest = (candidates.isEmpty ? Array(items.values) : candidates).min(by: { $0.order < $1.order }) else { break }
            items.removeValue(forKey: oldest.id)
            bytes -= cacheSizes.removeValue(forKey: oldest.id) ?? 0
        }
        pageIDs = pageIDs.map { $0.filter { items[$0] != nil } }.filter { !$0.isEmpty }
        navigationAnchors = navigationAnchors.filter { items[$0.key] != nil }
        messages = items.values.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
    }
    private func isProtected(_ ids: [String]) -> Bool {
        ids.contains { $0 == selectedMessageID || $0 == copyingMessageID }
    }
    private func promotePage(containing id: String) {
        guard let index = pageIDs.firstIndex(where: { $0.contains(id) }) else { return }
        pageIDs.append(pageIDs.remove(at: index))
    }
    private func handle(_ error: Error) {
        switch error as? ConversationHistoryError {
        case .cursorExpired:
            let wanted = selectedMessageID, query = searchQuery
            clearContent(); queue = [.latest]
            if let wanted, !followingLatest { selectedMessageID = wanted; queue.append(.around(messageID: wanted)) }
            if !query.isEmpty { searchQuery = query; queue.append(.search(query: query)) }
        case .sessionChanged:
            clearContent(); queue = []; state = .unavailable("session_changed")
        case .unsupportedServer:
            clearContent(); queue = []; state = .unavailable("unsupported_server")
        case .disconnected:
            failures = min(failures + 1, 5); queue = []; state = .unavailable("disconnected")
        default: failures = min(failures + 1, 5); queue = []; state = .failed(error.localizedDescription)
        }
    }
    private func restartPolling() {
        pollingTask?.cancel(); pollingTask = nil
        guard visible, selection != nil, provider != nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = (self.isPresented ? 1.0 : 3.0) * pow(2.0, Double(self.failures))
                do { try await self.pollingSleep(min(delay, 30)) } catch { return }
                guard self.visible, !Task.isCancelled else { return }
                if case .unavailable(let reason) = self.state,
                   !["disconnected", "loading", "no_binding", "not_recorded", "source_missing", "access_denied"].contains(reason) { continue }
                if self.requestTask == nil, !self.copyInProgress { self.refresh() }
            }
        }
    }

    /// Reconstructs text only after every continuation passes identity/revision checks.
    /// The caller writes the clipboard after this completes successfully.
    public func copyText(messageID: String) async throws -> String {
        try await completeMessage(messageID: messageID).visibleText
    }

    /// A transient expanded message for full reading; never adds oversized bodies to the cache.
    public func completeMessage(messageID: String) async throws -> ConversationMessage {
        guard !copyInProgress, let selection, let provider,
              let message = messages.first(where: { $0.id == messageID }), let binding else {
            throw ConversationHistoryError.contentChanged
        }
        if !visible, message.blocks.contains(where: { $0.truncated && $0.isCopyableText }) { throw ConversationHistoryError.disconnected }
        let token = epoch, copyID = UUID()
        promotePage(containing: messageID)
        copyingMessageID = messageID; copyToken = copyID; copyInProgress = true
        defer { if copyToken == copyID { copyToken = nil; copyingMessageID = nil; copyInProgress = false; drain() } }
        if let pending = requestTask { await pending.value }
        try Task.checkCancellation()
        guard epoch == token, copyToken == copyID else { throw CancellationError() }
        var expanded: [ConversationContentBlock] = []
        for block in message.blocks {
            var text = block.visibleText
            if block.truncated, block.isCopyableText {
                guard var cursor = block.blockCursor else { throw ConversationHistoryError.invalidContinuation }
                var slice = 1, seen = Set<String>()
                while true {
                    try Task.checkCancellation()
                    guard epoch == token, copyToken == copyID else { throw CancellationError() }
                    guard seen.insert(cursor).inserted else { throw ConversationHistoryError.invalidContinuation }
                    let requestCursor = cursor
                    let page = try await readGate.perform { try await provider.readBlock(target: selection.paneID, expectedSessionID: selection.sessionID, blockCursor: requestCursor, maxBytes: 1_048_576) }
                    guard epoch == token, copyToken == copyID, self.binding == binding,
                          messages.first(where: { $0.id == messageID })?.messageRevision == message.messageRevision,
                          page.binding == binding, page.messageID == messageID,
                          page.messageRevision == message.messageRevision, page.blockID == block.id,
                          page.kind == block.kind else { throw ConversationHistoryError.contentChanged }
                    guard page.sliceIndex == slice else { throw ConversationHistoryError.invalidContinuation }
                    text += page.text; slice += 1
                    guard let next = page.nextCursor else { break }
                    cursor = next
                }
            }
            if block.truncated, block.isCopyableText {
                expanded.append(.init(id: block.id, kind: block.kind, text: text, label: block.label, name: block.name))
            } else { expanded.append(block) }
        }
        try Task.checkCancellation()
        guard epoch == token, copyToken == copyID, self.binding == binding,
              messages.first(where: { $0.id == messageID })?.messageRevision == message.messageRevision else { throw ConversationHistoryError.contentChanged }
        return .init(id: message.id, turnID: message.turnID, role: message.role, origin: message.origin,
                     status: message.status, messageRevision: message.messageRevision, parentID: message.parentID,
                     timestamp: message.timestamp, order: message.order, blocks: expanded)
    }
}
