import XCTest
import HerdrKit
@testable import herdrm

private actor HistoryFixtureProvider: ConversationHistoryProviding {
    struct Step: Sendable {
        var page: ConversationPage?
        var error: ConversationHistoryError?
        var delay: Double = 0
    }
    private var steps: [Step]
    private var blocks: [BlockPage]
    private(set) var windows: [ConversationWindow] = []
    private(set) var sessions: [String] = []
    private(set) var blockReads = 0
    private var activeReads = 0
    private(set) var maximumConcurrentReads = 0
    init(_ pages: [ConversationPage] = [], steps: [Step]? = nil, blocks: [BlockPage] = []) {
        self.steps = steps ?? pages.map { Step(page: $0) }
        self.blocks = blocks
    }
    func read(target: String, expectedSessionID: String, window: ConversationWindow, limits: ConversationLimits) async throws -> ConversationPage {
        activeReads += 1; maximumConcurrentReads = max(maximumConcurrentReads, activeReads)
        defer { activeReads -= 1 }
        windows.append(window); sessions.append(expectedSessionID)
        guard !steps.isEmpty else { throw ConversationHistoryError.disconnected }
        let step = steps.removeFirst()
        if step.delay > 0 {
            // Intentionally ignores Task cancellation to exercise stale-result rejection.
            await withCheckedContinuation { continuation in DispatchQueue.global().asyncAfter(deadline: .now() + step.delay) { continuation.resume() } }
        }
        if let error = step.error { throw error }
        return step.page!
    }
    func readBlock(target: String, expectedSessionID: String, blockCursor: String, maxBytes: Int) async throws -> BlockPage {
        blockReads += 1
        guard !blocks.isEmpty else { throw ConversationHistoryError.invalidContinuation }
        return blocks.removeFirst()
    }
}

private actor HistoryFixtureClock {
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    private(set) var delays: [TimeInterval] = []
    func sleep(_ delay: TimeInterval) async throws {
        let id = UUID()
        delays.append(delay)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    func advanceWhenSleeping() async throws {
        let deadline = Date().addingTimeInterval(3)
        while waiters.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard !waiters.isEmpty else { throw ConversationHistoryError.disconnected }
        waiters.removeFirst().1.resume()
    }
    func waitForSleepCount(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(3)
        while delays.count < count, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard delays.count >= count else { throw ConversationHistoryError.disconnected }
    }
}

@MainActor
final class ConversationHistoryControllerTests: XCTestCase {
    private let device = UUID()
    private func ref(_ id: String = "s") -> AgentSessionRef { .init(source: "herdr:claude", agent: "claude", kind: "id", value: id) }
    private func binding(_ id: String = "s", generation: String = "g") -> ConversationBinding { .init(provider: "claude", sessionID: id, generation: generation) }
    private func message(_ id: String, order: Int = 1, text: String = "synthetic", revision: String = "mr") -> ConversationMessage {
        .init(id: id, turnID: "t-\(id)", role: "user", origin: "human", messageRevision: revision, order: order, blocks: [.init(id: "b-\(id)", kind: "text", text: text)])
    }
    private func page(_ messages: [ConversationMessage], session: String = "s", revision: String = "1", before: String? = nil, changes: String? = "c", turns: [ConversationTurn] = []) -> ConversationPage {
        .init(binding: binding(session), revision: revision, messages: messages, turns: turns, beforeCursor: before, changesCursor: changes)
    }
    private func selected(_ provider: HistoryFixtureProvider) -> ConversationHistoryController {
        let c = ConversationHistoryController()
        c.select(deviceID: device, paneID: "w:p", session: ref(), provider: provider)
        c.setVisible(true)
        return c
    }
    private func settled(_ c: ConversationHistoryController, where predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate(), "fixture request did not settle: \(c.state)")
    }
    func testTransientSourceStatesAutomaticallyRecoverForSameVisibleSession() async throws {
        let reasons = ["no_binding", "not_recorded", "source_missing", "access_denied"]
        let unavailable = reasons.map { ConversationPage(availability: $0) }
        let p = HistoryFixtureProvider(unavailable + [page([message("first-recorded")])])
        let clock = HistoryFixtureClock()
        let c = ConversationHistoryController(pollingSleep: { try await clock.sleep($0) }); defer { c.stop() }
        c.select(deviceID: device, paneID: "w:p", session: ref(), provider: p); c.setVisible(true)
        for reason in reasons {
            try await settled(c) { c.state == .unavailable(reason) }
            XCTAssertTrue(c.messages.isEmpty)
            try await clock.advanceWhenSleeping()
        }
        try await settled(c) { c.messages.first?.id == "first-recorded" && c.state == .ready }
        let sessions = await p.sessions; XCTAssertEqual(sessions, Array(repeating: "s", count: 5))
        let windows = await p.windows; XCTAssertEqual(windows, Array(repeating: .latest, count: 5))
        let delays = await clock.delays
        XCTAssertTrue(delays.allSatisfy { $0 >= 3 && $0 <= 30 })
        XCTAssertTrue(delays.contains { $0 > 3 }, "transient failures must use bounded backoff")
    }
    func testUnsupportedServerAndSchemaStayQuietUntilExplicitRetry() async throws {
        for reason in ["unsupported_server", "unsupported_schema"] {
            let first = reason == "unsupported_server" ? HistoryFixtureProvider.Step(error: .unsupportedServer) : .init(page: .init(availability: reason))
            let p = HistoryFixtureProvider(steps: [first, .init(page: page([message("available")]))])
            let clock = HistoryFixtureClock()
            let c = ConversationHistoryController(pollingSleep: { try await clock.sleep($0) })
            c.select(deviceID: device, paneID: "w:p", session: ref(), provider: p); c.setVisible(true)
            try await settled(c) { c.state == .unavailable(reason) }
            try await clock.advanceWhenSleeping(); try await clock.waitForSleepCount(2)
            let windows = await p.windows; XCTAssertEqual(windows, [.latest])
            c.refresh(); try await settled(c) { c.state == .ready }
            c.stop()
        }
    }
    func testSamePaneAcrossDevicesDoesNotReuseContent() async throws {
        let p = HistoryFixtureProvider([page([message("first")]), page([message("second")])])
        let c = selected(p); defer { c.stop() }
        try await settled(c) { c.messages.first?.id == "first" }
        c.select(deviceID: UUID(), paneID: "w:p", session: ref(), provider: p)
        try await settled(c) { c.messages.first?.id == "second" }
        XCTAssertEqual(c.messages.count, 1)
    }
    func testSessionReplacementRejectsLateOldResponse() async throws {
        let p = HistoryFixtureProvider(steps: [.init(page: page([message("old")]), delay: 0.1), .init(page: page([message("new")], session: "new"))])
        let c = selected(p); defer { c.stop() }
        try await Task.sleep(for: .milliseconds(10))
        c.select(deviceID: device, paneID: "w:p", session: ref("new"), provider: p)
        try await settled(c) { c.messages.first?.id == "new" }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(c.messages.map(\.id), ["new"])
    }
    func testSameSelectionPreservesDrawerAndSearchAndDoesNotRefetch() async throws {
        let p = HistoryFixtureProvider([page([message("m")])]); let c = selected(p); defer { c.stop() }
        try await settled(c) { c.state == .ready }
        c.open(); c.searchQuery = "typed query"
        c.select(deviceID: device, paneID: "w:p", session: ref(), provider: p); c.setVisible(true)
        XCTAssertTrue(c.isPresented); XCTAssertEqual(c.searchQuery, "typed query")
        let count = await p.windows.count; XCTAssertEqual(count, 1)
    }
    func testMissingBindingAndHiddenControllerMakeNoReads() async throws {
        let p = HistoryFixtureProvider(); let c = ConversationHistoryController(); defer { c.stop() }
        c.select(deviceID: device, paneID: "w:p", session: nil, provider: p); c.setVisible(true)
        XCTAssertEqual(c.state, .unavailable("no_binding"))
        let windows = await p.windows; XCTAssertTrue(windows.isEmpty)
    }
    func testMissingBindingStatusRefreshPreservesOpenDrawer() {
        let p = HistoryFixtureProvider(); let c = ConversationHistoryController(); defer { c.stop() }
        c.select(deviceID: device, paneID: "w:p", session: nil, provider: p); c.setVisible(true); c.open()
        c.searchQuery = "typed"
        c.select(deviceID: device, paneID: "w:p", session: nil, provider: p)
        XCTAssertTrue(c.isPresented); XCTAssertEqual(c.searchQuery, "typed")
        XCTAssertEqual(c.state, .unavailable("no_binding"))
    }
    func testVisibilityCancellationKeepsAtMostOneTransportReadInFlight() async throws {
        let p = HistoryFixtureProvider(steps: [.init(page: page([message("stale")]), delay: 0.1), .init(page: page([message("current")]))])
        let c = selected(p); defer { c.stop() }
        try await Task.sleep(for: .milliseconds(10))
        c.setVisible(false); c.setVisible(true)
        try await settled(c) { c.messages.first?.id == "current" }
        let maximum = await p.maximumConcurrentReads; XCTAssertEqual(maximum, 1)
    }
    func testFullTurnIndexLoadsBeyondCachedContent() async throws {
        let first = ConversationPage(binding: binding(), revision: "1", messages: [message("latest")], turns: [.init(id: "t1", messageID: "ancient", ordinal: 1)], turnsCursor: "turns-2", changesCursor: "c")
        let indexPage = ConversationPage(binding: binding(), revision: "1", turns: [.init(id: "t2", messageID: "middle", ordinal: 2), .init(id: "t3", messageID: "latest", ordinal: 3)])
        let p = HistoryFixtureProvider([first, indexPage, page([message("ancient", order: 0)])])
        let c = selected(p); defer { c.stop() }
        try await settled(c) { c.turns.count == 3 }
        XCTAssertEqual(c.messages.count, 1)
        c.open(turnID: "t1"); try await settled(c) { c.messages.contains { $0.id == "ancient" } }
        XCTAssertEqual(c.selectedMessageID, "ancient")
        let windows = await p.windows; XCTAssertEqual(windows, [.latest, .turns(cursor: "turns-2"), .around(messageID: "ancient")])
    }
    func testChangeUpsertsReplaceOlderMessagesAndTombstonesRemoveTurns() async throws {
        let index = ConversationTurn(id: "t-m", messageID: "m", preview: "old", ordinal: 1)
        let first = page([message("m"), message("n", order: 2)], turns: [index])
        let changes = ConversationPage(binding: binding(), revision: "2", upserts: [message("m", text: "revised", revision: "mr2"), message("p", order: 3)], changesCursor: "c2", removedMessageIDs: ["n"])
        let p = HistoryFixtureProvider([first, changes]); let c = selected(p); defer { c.stop() }
        try await settled(c) { c.state == .ready }; c.selectMessage("m"); c.refresh()
        try await settled(c) { c.messages.contains { $0.id == "p" } }
        XCTAssertEqual(c.messages.map(\.id), ["m", "p"]); XCTAssertEqual(c.messages.first?.visibleText, "revised")
        XCTAssertTrue(c.hasNewMessages); XCTAssertEqual(c.selectedMessageID, "m")
        let windows = await p.windows; XCTAssertEqual(windows, [.latest, .changes(cursor: "c")])
    }
    func testOlderPagingAndOutsideLoadedSearch() async throws {
        let search = ConversationPage(binding: binding(), revision: "1", messages: [message("ancient", order: 0)], matchMessageIDs: ["ancient"])
        let p = HistoryFixtureProvider([page([message("new")], before: "b"), page([message("old", order: 0)]), search])
        let c = selected(p); defer { c.stop() }; try await settled(c) { c.canLoadOlder }
        c.loadOlder(); try await settled(c) { c.messages.count == 2 && !c.isLoadingOlder }
        c.search("ancient"); try await settled(c) { c.matchedMessageIDs == ["ancient"] }
        let windows = await p.windows; XCTAssertEqual(windows, [.latest, .before(cursor: "b"), .search(query: "ancient")])
    }
    func testExpiredCursorReloadsAndSourceUnavailableClearsCache() async throws {
        let p = HistoryFixtureProvider(steps: [.init(page: page([message("old")])), .init(error: .cursorExpired), .init(page: page([message("new")])), .init(page: .init(availability: "source_missing"))])
        let c = selected(p); defer { c.stop() }; try await settled(c) { c.state == .ready }
        c.refresh(); try await settled(c) { c.messages.first?.id == "new" }
        c.refresh(); try await settled(c) { c.state == .unavailable("source_missing") }
        XCTAssertTrue(c.messages.isEmpty)
    }
    func testDisconnectKeepsCacheAndReconnectReloads() async throws {
        let p = HistoryFixtureProvider(steps: [.init(page: page([message("m")])), .init(error: .disconnected), .init(page: page([message("m")]))])
        let c = selected(p); defer { c.stop() }; try await settled(c) { c.state == .ready }
        c.refresh(); try await settled(c) { c.state == .unavailable("disconnected") }
        c.setVisible(false); XCTAssertEqual(c.messages.map(\.id), ["m"])
        c.setVisible(true); try await settled(c) { c.state == .ready }
    }
    func testCopyReconstructsUnicodeAndWhitespaceWithoutSliceSeparators() async throws {
        let m = ConversationMessage(id: "m", messageRevision: "mr", blocks: [.init(id: "b", kind: "text", text: "α\n", blockCursor: "b1", truncated: true), .init(id: "a", kind: "attachment", label: "attachment.png")])
        let p = HistoryFixtureProvider([page([m])], blocks: [BlockPage(binding: binding(), revision: "1", messageID: "m", messageRevision: "mr", blockID: "b", kind: "text", text: "🌍  β\n", sliceIndex: 1)])
        let c = selected(p); defer { c.stop() }; try await settled(c) { c.state == .ready }
        let copied = try await c.copyText(messageID: "m")
        XCTAssertEqual(copied, "α\n🌍  β\n\n\nattachment.png"); XCTAssertFalse(c.copyInProgress)
    }
    func testCopyRejectsDifferentMessageRevision() async throws {
        let m = ConversationMessage(id: "m", messageRevision: "mr", blocks: [.init(id: "b", kind: "text", text: "part", blockCursor: "b1", truncated: true)])
        let p = HistoryFixtureProvider([page([m])], blocks: [BlockPage(binding: binding(), revision: "2", messageID: "m", messageRevision: "new", blockID: "b", kind: "text", text: "wrong", sliceIndex: 1)])
        let c = selected(p); defer { c.stop() }; try await settled(c) { c.state == .ready }
        do { _ = try await c.copyText(messageID: "m"); XCTFail("partial copy should fail") }
        catch { XCTAssertEqual(error as? ConversationHistoryError, .contentChanged) }
        XCTAssertFalse(c.copyInProgress)
    }
    func testCompleteMessageExpandsTypedBlocksWithoutGrowingCache() async throws {
        let m = ConversationMessage(id: "m", role: "assistant", messageRevision: "mr", blocks: [.init(id: "b", kind: "code", text: "let x = ", blockCursor: "b1", truncated: true)])
        let p = HistoryFixtureProvider([page([m])], blocks: [BlockPage(binding: binding(), revision: "1", messageID: "m", messageRevision: "mr", blockID: "b", kind: "code", text: "🌍\n", sliceIndex: 1)])
        let c = selected(p); defer { c.stop() }; try await settled(c) { c.state == .ready }
        let complete = try await c.completeMessage(messageID: "m")
        XCTAssertEqual(complete.blocks.first?.kind, "code"); XCTAssertEqual(complete.visibleText, "let x = 🌍\n")
        XCTAssertEqual(complete.role, "assistant"); XCTAssertFalse(try XCTUnwrap(complete.blocks.first).truncated)
        XCTAssertNil(complete.blocks.first?.blockCursor)
        XCTAssertEqual(c.messages.first, m, "expanded content must stay out of bounded pages")
    }
    func testCompleteMessageRejectsRevisionChange() async throws {
        let m = ConversationMessage(id: "m", messageRevision: "mr", blocks: [.init(id: "b", kind: "text", text: "part", blockCursor: "b1", truncated: true)])
        let p = HistoryFixtureProvider([page([m])], blocks: [BlockPage(binding: binding(), revision: "2", messageID: "m", messageRevision: "changed", blockID: "b", kind: "text", text: "wrong", sliceIndex: 1)])
        let c = selected(p); defer { c.stop() }; try await settled(c) { c.state == .ready }
        do { _ = try await c.completeMessage(messageID: "m"); XCTFail("mixed revision must fail") }
        catch { XCTAssertEqual(error as? ConversationHistoryError, .contentChanged) }
    }
    func testNewerPagingFlagTracksAroundAndAfterCursor() async throws {
        let around = ConversationPage(binding: binding(), revision: "1", messages: [message("old", order: 0)], afterCursor: "next")
        let p = HistoryFixtureProvider([page([message("new")]), around, page([message("middle")])])
        let c = selected(p); defer { c.stop() }; try await settled(c) { c.state == .ready }
        XCTAssertFalse(c.canLoadNewer)
        c.selectMessage("old"); try await settled(c) { c.canLoadNewer }
        c.loadNewer(); XCTAssertTrue(c.isLoadingNewer)
        try await settled(c) { !c.canLoadNewer && !c.isLoadingNewer }
        let windows = await p.windows; XCTAssertEqual(windows, [.latest, .around(messageID: "old"), .after(cursor: "next")])
    }
    func testEvictedPagesRemainRecoverableInBothDirections() async throws {
        func navigationPage(_ order: Int) -> ConversationPage {
            .init(binding: binding(), revision: "1", messages: [message("m\(order)", order: order)],
                  beforeCursor: order > 0 ? "before-\(order)" : nil,
                  afterCursor: order < 10 ? "after-\(order)" : nil, changesCursor: "c")
        }
        let pages = [navigationPage(10)] + (0..<10).reversed().map(navigationPage) + (1...10).map(navigationPage) + [navigationPage(9)]
        let p = HistoryFixtureProvider(pages); let c = selected(p); defer { c.stop() }
        try await settled(c) { c.messages.contains { $0.id == "m10" } }
        for order in (0..<10).reversed() {
            c.loadOlder(); try await settled(c) { c.messages.contains { $0.id == "m\(order)" } && !c.isLoadingOlder }
            c.selectMessage("m\(order)")
        }
        XCTAssertFalse(c.messages.contains { $0.id == "m10" }, "latest body should have been evicted")
        XCTAssertTrue(c.canLoadNewer); XCTAssertFalse(c.canLoadOlder)
        for order in 1...10 {
            c.loadNewer(); try await settled(c) { c.messages.contains { $0.id == "m\(order)" } && !c.isLoadingNewer }
            c.selectMessage("m\(order)")
        }
        XCTAssertFalse(c.canLoadNewer); XCTAssertTrue(c.canLoadOlder)
        c.loadOlder(); try await settled(c) { !c.isLoadingOlder && c.canLoadNewer }
        let windows = await p.windows
        XCTAssertEqual(windows, [.latest] + (1...10).reversed().map { .before(cursor: "before-\($0)") } + (0..<10).map { .after(cursor: "after-\($0)") } + [.before(cursor: "before-10")])
        XCTAssertLessThanOrEqual(c.messages.count, 8)
    }
    func testNonChangeRevisionCannotSuppressSearchRefresh() async throws {
        let searchOne = ConversationPage(binding: binding(), revision: "1", matchMessageIDs: ["m1"])
        let aroundTwo = page([message("m2", order: 2)], revision: "2")
        let changesTwo = ConversationPage(binding: binding(), revision: "2", upserts: [message("m3", order: 3)], changesCursor: "c2")
        let searchTwo = ConversationPage(binding: binding(), revision: "2", matchMessageIDs: ["m1", "m3"])
        let p = HistoryFixtureProvider([page([message("m1")]), searchOne, aroundTwo, changesTwo, searchTwo])
        let c = selected(p); defer { c.stop() }; try await settled(c) { c.state == .ready }
        c.search("needle"); try await settled(c) { c.matchedMessageIDs == ["m1"] }
        c.selectMessage("m2"); try await settled(c) { c.messages.contains { $0.id == "m2" } }
        c.refresh(); try await settled(c) { c.matchedMessageIDs == ["m1", "m3"] }
        let windows = await p.windows
        XCTAssertEqual(windows, [.latest, .search(query: "needle"), .around(messageID: "m2"), .changes(cursor: "c"), .search(query: "needle")])
    }
    func testLatestNavigationPreservesUnappliedChangeCursorAndSearchRevision() async throws {
        let searchOne = ConversationPage(binding: binding(), revision: "1", matchMessageIDs: ["m1"])
        let latestTwo = ConversationPage(binding: binding(), revision: "2", messages: [message("m2", order: 2)], changesCursor: "c2")
        let changesTwo = ConversationPage(binding: binding(), revision: "2", upserts: [message("m1", text: "edited", revision: "mr2")], changesCursor: "c2")
        let searchTwo = ConversationPage(binding: binding(), revision: "2", matchMessageIDs: ["m1", "m2"])
        let p = HistoryFixtureProvider([page([message("m1")]), searchOne, latestTwo, changesTwo, searchTwo])
        let c = selected(p); defer { c.stop() }; try await settled(c) { c.state == .ready }
        c.search("needle"); try await settled(c) { c.matchedMessageIDs == ["m1"] }
        c.showLatest(); try await settled(c) { c.selectedMessageID == "m2" }
        c.refresh(); try await settled(c) { c.matchedMessageIDs == ["m1", "m2"] }
        XCTAssertEqual(c.messages.first(where: { $0.id == "m1" })?.visibleText, "edited")
        let windows = await p.windows
        XCTAssertEqual(windows, [.latest, .search(query: "needle"), .latest, .changes(cursor: "c"), .search(query: "needle")])
    }
    func testSelectingRetainedBodyRestoresItsOwnNavigationAnchors() async throws {
        let latest = ConversationPage(binding: binding(), revision: "1", messages: [message("m2", order: 2)], beforeCursor: "b2", changesCursor: "c")
        let older = ConversationPage(binding: binding(), revision: "1", messages: [message("m1", order: 1)], beforeCursor: "b1", afterCursor: "a1")
        let p = HistoryFixtureProvider([latest, older, latest]); let c = selected(p); defer { c.stop() }
        try await settled(c) { c.state == .ready }
        c.loadOlder(); try await settled(c) { c.messages.count == 2 && !c.isLoadingOlder }
        c.selectMessage("m2"); XCTAssertFalse(c.canLoadNewer)
        c.selectMessage("m1"); XCTAssertTrue(c.canLoadNewer)
        c.loadNewer(); try await settled(c) { !c.isLoadingNewer && !c.canLoadNewer }
        let windows = await p.windows; XCTAssertEqual(windows, [.latest, .before(cursor: "b2"), .after(cursor: "a1")])
    }
    func testSelectedBodySurvivesMoreThanEightBackgroundPages() async throws {
        let updates = (1...12).map { order in
            ConversationPage(binding: binding(), revision: "\(order + 1)", upserts: [message("m\(order)", order: order)], changesCursor: "c\(order)")
        }
        let p = HistoryFixtureProvider([page([message("anchor", text: "reader anchor")])] + updates)
        let c = selected(p); defer { c.stop() }; try await settled(c) { c.state == .ready }
        c.selectMessage("anchor")
        for order in 1...12 {
            c.refresh(); try await settled(c) { c.messages.contains { $0.id == "m\(order)" } }
            XCTAssertEqual(c.selectedMessageID, "anchor")
            XCTAssertTrue(c.messages.contains { $0.id == "anchor" })
        }
        let copied = try await c.copyText(messageID: "anchor")
        XCTAssertEqual(copied, "reader anchor"); XCTAssertEqual(c.messages.count, 8)
    }
    func testCopyPinsCachedBodyWhilePendingBackgroundInsertCompletes() async throws {
        let initial = page([message("m0", order: 0, text: "copy anchor")])
        let steps = [.init(page: initial)] + (1...8).map { order in
            HistoryFixtureProvider.Step(page: ConversationPage(binding: binding(), revision: "\(order + 1)", upserts: [message("m\(order)", order: order)], changesCursor: "c\(order)"), delay: order == 8 ? 0.05 : 0)
        }
        let p = HistoryFixtureProvider(steps: steps); let c = selected(p); defer { c.stop() }
        try await settled(c) { c.state == .ready }
        for order in 1...7 { c.refresh(); try await settled(c) { c.messages.contains { $0.id == "m\(order)" } } }
        c.refresh()
        let copyTask = Task { try await c.copyText(messageID: "m0") }
        let text = try await copyTask.value
        XCTAssertEqual(text, "copy anchor")
        XCTAssertTrue(c.messages.contains { $0.id == "m0" }); XCTAssertEqual(c.messages.count, 8)
    }
    func testCompletenessNoticesReflectAcceptedSourceAndReset() async throws {
        let unsupported = ConversationPage(binding: binding(), revision: "1", completeness: "partial_unsupported_records", messages: [message("m")], changesCursor: "c")
        let trailing = ConversationPage(binding: binding(), revision: "2", completeness: "partial_trailing_record", changesCursor: "c2")
        let p = HistoryFixtureProvider([unsupported, trailing, .init(availability: "source_missing")])
        let c = ConversationHistoryController(); defer { c.stop() }
        XCTAssertEqual(c.completeness, "source_available")
        c.select(deviceID: device, paneID: "w:p", session: ref(), provider: p); c.setVisible(true)
        try await settled(c) { c.completeness == "partial_unsupported_records" }
        c.refresh(); try await settled(c) { c.completeness == "partial_trailing_record" }
        c.refresh(); try await settled(c) { c.state == .unavailable("source_missing") }
        XCTAssertEqual(c.completeness, "source_available")
    }
    func testContentCacheIsBoundedToEightPages() async throws {
        let pages = (0..<10).map { page([message("m\($0)", order: $0)], before: "b\($0)") }
        let p = HistoryFixtureProvider(pages); let c = selected(p); defer { c.stop() }
        try await settled(c) { c.state == .ready }
        for index in 1..<10 {
            c.loadOlder(); try await settled(c) { c.messages.contains { $0.id == "m\(index)" } && !c.isLoadingOlder }
        }
        XCTAssertEqual(c.messages.count, 8)
    }
}
