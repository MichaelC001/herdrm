import Foundation
import Darwin
import XCTest
@testable import HerdrKit

final class ClaudeHistoryProviderTests: XCTestCase {
    private let sessionID = "0b4f6c1e-1111-4222-8333-944455556666"
    private var configDirectory: URL!
    private var transcript: URL!

    override func setUpWithError() throws {
        configDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("hhist-\(UUID().uuidString.prefix(8))")
        let project = configDirectory.appendingPathComponent("projects/-tmp-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        transcript = project.appendingPathComponent("\(sessionID).jsonl")
        // The reader is a child process; it finds the transcript through this.
        setenv("CLAUDE_CONFIG_DIR", configDirectory.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("CLAUDE_CONFIG_DIR")
        try? FileManager.default.removeItem(at: configDirectory)
    }

    private func prompt(_ uuid: String, parent: String?, _ text: String) -> String {
        record(["type": "user", "uuid": uuid, "parentUuid": parent ?? NSNull(), "origin": ["kind": "human"],
                "message": ["role": "user", "content": text]])
    }

    private func reply(_ uuid: String, parent: String, id: String, _ text: String) -> String {
        record(["type": "assistant", "uuid": uuid, "parentUuid": parent,
                "message": ["id": id, "role": "assistant", "content": [["type": "text", "text": text]]]])
    }

    private func record(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
    }

    private func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func provider(store: ClaudeTranscriptStore = .init()) -> ClaudeHistoryProvider {
        let device = Device(name: "fixture", kind: .local, socketPath: "/tmp/none.sock")
        return ClaudeHistoryProvider(store: store, device: device, service: HerdrService(device: device, autoStartLocalServer: false))
    }

    func testReadsTheTranscriptAndFollowsAppendedRecords() async throws {
        try (prompt("u1", parent: nil, "first") + reply("a1", parent: "u1", id: "m1", "one")).write(to: transcript, atomically: true, encoding: .utf8)
        let store = ClaudeTranscriptStore()
        let provider = provider(store: store)
        let latest = try await provider.read(target: "w:p", expectedSessionID: sessionID, window: .latest, limits: .init())
        XCTAssertEqual(latest.availability, "ready")
        XCTAssertEqual(latest.binding?.sessionID, sessionID)
        XCTAssertEqual(latest.messages.map(\.id), ["u1", "a-m1"])
        let cursor = try XCTUnwrap(latest.changesCursor)

        try append(prompt("u2", parent: "a1", "second"))
        var upserts: [String] = []
        for _ in 0..<40 where upserts.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
            upserts = try await provider.read(target: "w:p", expectedSessionID: sessionID, window: .changes(cursor: cursor), limits: .init()).upserts.map(\.id)
        }
        XCTAssertEqual(upserts, ["u2"])
        await store.stopAll()
    }

    func testMissingTranscriptIsReportedNotThrown() async throws {
        let page = try await provider().read(target: "w:p", expectedSessionID: sessionID, window: .latest, limits: .init())
        XCTAssertEqual(page.availability, "source_missing")
    }

    func testUnsupportedDevicesAndSessionIDsNeverStartAReader() async throws {
        let store = ClaudeTranscriptStore()
        let tailcat = Device(name: "tc", kind: .tailcat)
        let snapshot = try await store.snapshot(device: tailcat, sessionID: sessionID)
        guard case .unavailable("unsupported_device") = snapshot else { return XCTFail("\(snapshot)") }
        let local = Device(name: "l", kind: .local)
        let injected = try await store.snapshot(device: local, sessionID: "x'; rm -rf ~; '")
        guard case .unavailable("no_binding") = injected else { return XCTFail("\(injected)") }
    }

    func testJumpSearchesThePaneAndScrollsItsViewportOnly() async throws {
        let text = prompt("u1", parent: nil, "continue") + reply("a1", parent: "u1", id: "m1", "ok")
            + prompt("u2", parent: "a1", "continue") + reply("a2", parent: "u2", id: "m2", "ok again")
        try text.write(to: transcript, atomically: true, encoding: .utf8)
        // Row 30 is Claude quoting the prompt mid-line; rows 10 and 50 are the prompts.
        let socket = try PaneFixtureSocket(matches: [(10, 2), (30, 12), (50, 2)], maxOffset: 200, viewportRows: 40)
        defer { socket.stop() }
        let store = ClaudeTranscriptStore()
        let device = Device(name: "fixture", kind: .local, socketPath: socket.path)
        let service = HerdrService(device: device, autoStartLocalServer: false)
        _ = try await service.connect()
        let provider = ClaudeHistoryProvider(store: store, device: device, service: service)
        let page = try await provider.read(target: "w:p", expectedSessionID: sessionID, window: .latest, limits: .init())
        let second = try XCTUnwrap(page.messages.first { $0.id == "u2" })
        let result = try await provider.jump(target: "w:p", expectedSessionID: sessionID,
                                             expectedGeneration: try XCTUnwrap(page.binding?.generation),
                                             messageID: "u2", messageRevision: second.messageRevision)
        await service.disconnect()
        await store.stopAll()
        XCTAssertEqual(result.sourceRow, 50)
        XCTAssertEqual(result.offsetFromBottom, 151, "row 50 lands one line below the viewport top")
        let methods = socket.requests.compactMap { $0["method"] as? String }
        XCTAssertEqual(methods, ["ping", "pane.copy_motion", "pane.copy_search", "pane.get", "pane.copy_motion", "pane.scroll"])
        let search = try XCTUnwrap(socket.requests.first { $0["method"] as? String == "pane.copy_search" }?["params"] as? [String: Any])
        XCTAssertEqual(search["query"] as? String, "continue")
        XCTAssertEqual(search["content_revision"] as? Int, 42)
        XCTAssertTrue(methods.allSatisfy { !["pane.send_input", "pane.send_text", "pane.send_keys", "agent.prompt"].contains($0) })
    }

    private func fullscreenJump(prompts: [String], jumpTo index: Int, matchAfterPages: Int?, topAtPage: Int = .max)
        async throws -> (Result<ConversationJumpResult, Error>, PageCounter) {
        var text = "", parent: String?
        for (n, prompt) in prompts.enumerated() {
            text += self.prompt("u\(n)", parent: parent, prompt); parent = "u\(n)"
        }
        try text.write(to: transcript, atomically: true, encoding: .utf8)
        let pages = PageCounter()
        // Fullscreen Claude: herdr has no scrollback (max offset 0).
        let socket = try PaneFixtureSocket(matches: [], maxOffset: 0, viewportRows: 40, pages: pages,
                                           matchAfterPages: matchAfterPages, topAtPage: topAtPage)
        defer { socket.stop() }
        let store = ClaudeTranscriptStore()
        let device = Device(name: "fixture", kind: .local, socketPath: socket.path)
        let service = HerdrService(device: device, autoStartLocalServer: false)
        _ = try await service.connect()
        let provider = ClaudeHistoryProvider(store: store, device: device, service: service,
                                             appScroll: { key in pages.press(key); return true },
                                             pageSettle: .milliseconds(60))
        let page = try await provider.read(target: "w:p", expectedSessionID: sessionID, window: .latest, limits: .init())
        let message = try XCTUnwrap(page.messages.first { $0.id == "u\(index)" })
        let outcome: Result<ConversationJumpResult, Error>
        do {
            outcome = .success(try await provider.jump(target: "w:p", expectedSessionID: sessionID,
                                                       expectedGeneration: try XCTUnwrap(page.binding?.generation),
                                                       messageID: message.id, messageRevision: message.messageRevision))
        } catch { outcome = .failure(error) }
        await service.disconnect()
        await store.stopAll()
        return (outcome, pages)
    }

    func testFullscreenJumpPagesClaudesOwnHistoryUntilThePromptShows() async throws {
        let (outcome, pages) = try await fullscreenJump(prompts: ["first", "second"], jumpTo: 0, matchAfterPages: 3)
        let result = try outcome.get()
        XCTAssertTrue(result.scrolledApp)
        XCTAssertEqual(result.offsetFromBottom, 3)
        XCTAssertEqual(result.sourceRow, 12)
        XCTAssertEqual(pages.sent, [.pageUp, .pageUp, .pageUp])
    }

    func testFullscreenJumpReturnsToTheBottomWhenTheTopHasNoMatch() async throws {
        let (outcome, pages) = try await fullscreenJump(prompts: ["first", "second"], jumpTo: 0, matchAfterPages: nil, topAtPage: 4)
        XCTAssertThrowsError(try outcome.get()) { XCTAssertEqual($0 as? ConversationJumpNotice, .notFound) }
        XCTAssertEqual(pages.value, 5, "the fifth page showed the same screen as the fourth: the top")
        XCTAssertEqual(pages.sent.last, .toBottom)
    }

    func testFullscreenJumpOnlyFindsTheNewestOfRepeatedPrompts() async throws {
        let (outcome, pages) = try await fullscreenJump(prompts: ["continue", "other", "continue"], jumpTo: 0, matchAfterPages: 1)
        XCTAssertThrowsError(try outcome.get()) { XCTAssertEqual($0 as? ConversationJumpNotice, .notFound) }
        XCTAssertTrue(pages.sent.isEmpty, "an older repeat cannot be told apart, so nothing is typed")
    }

    func testRowSelectionAccountsForScrolledOutAndQuotedPrompts() throws {
        let target = ClaudeTranscriptIndex.JumpTarget(key: "continue", occurrence: 2, occurrences: 3)
        // Only the two newest prompts are still in the scrollback.
        XCTAssertEqual(try ClaudeHistoryProvider.row(for: target, in: [.init(row: 5, col: 2), .init(row: 9, col: 2)]), 9)
        let oldest = ClaudeTranscriptIndex.JumpTarget(key: "continue", occurrence: 0, occurrences: 3)
        XCTAssertThrowsError(try ClaudeHistoryProvider.row(for: oldest, in: [.init(row: 5, col: 2), .init(row: 9, col: 2)])) {
            XCTAssertEqual($0 as? ConversationJumpNotice, .notFound)
        }
        let single = ClaudeTranscriptIndex.JumpTarget(key: "yes", occurrence: 0, occurrences: 1)
        XCTAssertThrowsError(try ClaudeHistoryProvider.row(for: single, in: [.init(row: 1, col: 2), .init(row: 7, col: 2)])) {
            XCTAssertEqual($0 as? ConversationJumpNotice, .ambiguous, "an older session's prompt in the scrollback")
        }
        XCTAssertThrowsError(try ClaudeHistoryProvider.row(for: single, in: [.init(row: 1, col: 20)])) {
            XCTAssertEqual($0 as? ConversationJumpNotice, .notFound)
        }
    }

    func testPromptRowFindsThePromptAtTheLeftEdgeOnly() {
        let screen = "● Claude said: ❯ first\n\n❯ first question here\n  quoting first"
        XCTAssertEqual(ClaudeHistoryProvider.promptRow(of: "first", in: screen), 2)
        XCTAssertNil(ClaudeHistoryProvider.promptRow(of: "missing", in: screen))
    }

    func testOffsetClampsToTheScrollback() {
        let metrics = PaneScrollMetrics(offsetFromBottom: 0, maxOffsetFromBottom: 100, viewportRows: 40)
        XCTAssertEqual(ClaudeHistoryProvider.offset(showing: 0, metrics: metrics), 100)
        XCTAssertEqual(ClaudeHistoryProvider.offset(showing: 61, metrics: metrics), 40)
        XCTAssertEqual(ClaudeHistoryProvider.offset(showing: 139, metrics: metrics), 0)
    }
}

final class PageCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private(set) var keys: [AppScrollKey] = []
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    var sent: [AppScrollKey] { lock.lock(); defer { lock.unlock() }; return keys }
    func press(_ key: AppScrollKey) {
        lock.lock(); keys.append(key); if key == .pageUp { count += 1 }; lock.unlock()
    }
}

/// Synthetic private socket only; never opens the user's daemon.
private final class PaneFixtureSocket: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var recorded: [[String: Any]] = []
    private let listener: Int32
    private var stopped = false
    var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return recorded }

    /// `pages` counts PageUp presses; with `matchAfterPages` set, the search finds the
    /// prompt (row 12, col 2) only once that many pages were pressed. The visible screen
    /// stops changing at `topAtPage`.
    init(matches: [(row: Int, col: Int)], maxOffset: Int, viewportRows: Int,
         pages: PageCounter? = nil, matchAfterPages: Int? = nil, topAtPage: Int = .max) throws {
        path = "/tmp/hhist-\(UUID().uuidString.prefix(8)).sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw HerdrError.connectionFailed("fixture socket") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let status = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard status == 0, listen(listener, 8) == 0 else { close(listener); throw HerdrError.connectionFailed("fixture bind") }
        let listening = listener
        let ranges = matches.map { ["start": ["row": $0.row, "col": $0.col], "end": ["row": $0.row, "col": $0.col + 8]] }
        Thread.detachNewThread { [weak self] in
            while true {
                let connection = accept(listening, nil, nil)
                guard connection >= 0 else { return }
                defer { close(connection) }
                var noSignal: Int32 = 1
                setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                guard let data = try? SocketRPC.readLine(fd: connection, timeoutSeconds: 2),
                      let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let self else { continue }
                self.lock.lock(); self.recorded.append(request); self.lock.unlock()
                let params = request["params"] as? [String: Any] ?? [:]
                let result: [String: Any]
                switch request["method"] as? String ?? "" {
                case "ping":
                    result = ["type": "pong", "version": "fixture", "protocol": 17]
                case "pane.copy_motion":
                    result = ["type": "pane_copy_motion", "pane_id": "w:p", "cursor": ["row": 0, "col": 0], "content_revision": 42]
                case "pane.copy_search":
                    var found = ranges
                    if let after = matchAfterPages {
                        found = (pages?.value ?? 0) >= after ? [["start": ["row": 12, "col": 2], "end": ["row": 12, "col": 10]]] : []
                    }
                    result = ["type": "pane_copy_search", "pane_id": "w:p", "content_revision": 42, "matches": found, "total": found.count]
                case "pane.read":
                    // 40 rows: history on top, a spinner that never stops at the bottom.
                    let page = min(pages?.value ?? 0, topAtPage)
                    var rows = (0..<40).map { "history page \(page) row \($0)" }
                    if let after = matchAfterPages, page >= after { rows[12] = "❯ first" }
                    rows[39] = "✻ Working… \(UUID().uuidString.prefix(4))"
                    result = ["type": "pane_read", "read": ["text": rows.joined(separator: "\n")]]
                case "pane.get":
                    result = ["type": "pane_info", "pane": ["scroll": ["offset_from_bottom": 0, "max_offset_from_bottom": maxOffset, "viewport_rows": viewportRows]]]
                case "pane.scroll":
                    let offset = params["offset_from_bottom"] as? Int ?? 0
                    result = ["type": "pane_info", "pane": ["scroll": ["offset_from_bottom": offset, "max_offset_from_bottom": maxOffset, "viewport_rows": viewportRows]]]
                default:
                    result = ["type": "unknown"]
                }
                guard var reply = try? JSONSerialization.data(withJSONObject: ["id": request["id"] ?? "fixture", "ok": true, "result": result]) else { continue }
                reply.append(10)
                reply.withUnsafeBytes { bytes in _ = write(connection, bytes.baseAddress!, bytes.count) }
            }
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }; stopped = true
        shutdown(listener, SHUT_RDWR); close(listener); unlink(path)
    }
    deinit { stop() }
}
