import Foundation
import Darwin
import XCTest
@testable import HerdrKit

final class ClaudeHistoryProviderTests: XCTestCase {
    func testFixtureSocketUsesReadOnlyMethodsAndExactIdentityForEveryWindow() async throws {
        let socket = try HistoryFixtureSocket(supported: true)
        defer { socket.stop() }
        let service = HerdrService(device: .init(name: "fixture", kind: .local, socketPath: socket.path), autoStartLocalServer: false)
        _ = try await service.connect()
        let provider = ClaudeHistoryProvider(service: service)
        for window in [ConversationWindow.latest, .before(cursor: "b"), .after(cursor: "a"), .around(messageID: "m"), .search(query: "q"), .turns(cursor: "t"), .changes(cursor: "c")] {
            let page = try await provider.read(target: "w:p", expectedSessionID: "s", window: window, limits: .init())
            XCTAssertEqual(page.binding?.sessionID, "s")
        }
        let block = try await provider.readBlock(target: "w:p", expectedSessionID: "s", blockCursor: "bc", maxBytes: 1_048_576)
        XCTAssertEqual(block.text, "🌍\n")
        await service.disconnect()
        let requests = socket.requests
        XCTAssertEqual(requests.count, 9)
        XCTAssertEqual(requests.first?["method"] as? String, "ping")
        XCTAssertTrue(requests.dropFirst().allSatisfy { ["agent.conversation.read", "agent.conversation.block.read"].contains($0["method"] as? String ?? "") })
        for request in requests.dropFirst() {
            let params = try XCTUnwrap(request["params"] as? [String: Any])
            XCTAssertEqual(params["target"] as? String, "w:p")
            XCTAssertEqual(params["expected_session_id"] as? String, "s")
            XCTAssertNil(params["path"])
        }
    }
    func testOldServerRemainsConnectedWhileHistoryIsUnavailable() async throws {
        let socket = try HistoryFixtureSocket(supported: false)
        defer { socket.stop() }
        let service = HerdrService(device: .init(name: "fixture", kind: .local, socketPath: socket.path), autoStartLocalServer: false)
        _ = try await service.connect()
        do {
            _ = try await ClaudeHistoryProvider(service: service).read(target: "w:p", expectedSessionID: "s", window: .latest, limits: .init())
            XCTFail("old server should not receive a history RPC")
        } catch { XCTAssertEqual(error as? ConversationHistoryError, .unsupportedServer) }
        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.agents.count, 0)
        XCTAssertEqual(socket.requests.compactMap { $0["method"] as? String }, ["ping", "session.snapshot"])
        await service.disconnect()
    }
    func testJumpUsesExactIdentityAndScrollIsViewportOnly() async throws {
        let socket = try HistoryFixtureSocket(supported: true, jumpSupported: true)
        defer { socket.stop() }
        let service = HerdrService(device: .init(name: "fixture", kind: .local, socketPath: socket.path), autoStartLocalServer: false)
        _ = try await service.connect()
        let jump = try await ClaudeHistoryProvider(service: service).jump(target: "w:p", expectedSessionID: "s", expectedGeneration: "g", messageID: "m", messageRevision: "mr")
        XCTAssertEqual(jump.messageID, "m"); XCTAssertEqual(jump.sourceRow, 17)
        try await service.scrollPane(paneID: "w:p", offsetFromBottom: 9)
        try await service.scrollToBottom(paneID: "w:p")
        await service.disconnect()
        let requests = socket.requests
        XCTAssertEqual(requests.compactMap { $0["method"] as? String }, ["ping", "agent.conversation.jump", "pane.scroll", "pane.scroll"])
        let params = try XCTUnwrap(requests[1]["params"] as? [String: Any])
        XCTAssertEqual(params["expected_generation"] as? String, "g")
        XCTAssertEqual(params["expected_session_id"] as? String, "s")
        XCTAssertEqual(params["message_id"] as? String, "m")
        XCTAssertEqual(params["message_revision"] as? String, "mr")
        XCTAssertEqual(params["target"] as? String, "w:p"); XCTAssertNil(params["path"])
        XCTAssertEqual((requests[2]["params"] as? [String: Any])?["offset_from_bottom"] as? Int, 9)
        XCTAssertEqual((requests[3]["params"] as? [String: Any])?["offset_from_bottom"] as? Int, 0)
        XCTAssertTrue(requests.allSatisfy { !["pane.send_input", "agent.send", "pane.write"].contains($0["method"] as? String ?? "") })
    }
    func testMissingJumpCapabilityPreservesOrdinaryHistory() async throws {
        let socket = try HistoryFixtureSocket(supported: true, jumpSupported: false)
        defer { socket.stop() }
        let service = HerdrService(device: .init(name: "fixture", kind: .local, socketPath: socket.path), autoStartLocalServer: false)
        _ = try await service.connect()
        let provider = ClaudeHistoryProvider(service: service)
        do {
            _ = try await provider.jump(target: "w:p", expectedSessionID: "s", expectedGeneration: "g", messageID: "m", messageRevision: "mr")
            XCTFail("unadvertised jump should not be sent")
        } catch { XCTAssertEqual(error as? ConversationJumpNotice, .unsupportedServer) }
        let page = try await provider.read(target: "w:p", expectedSessionID: "s", window: .latest, limits: .init())
        XCTAssertEqual(page.binding?.sessionID, "s")
        XCTAssertEqual(socket.requests.compactMap { $0["method"] as? String }, ["ping", "agent.conversation.read"])
        await service.disconnect()
    }
}

/// Synthetic private socket only; never opens the user's daemon or reads a transcript.
private final class HistoryFixtureSocket: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var recorded: [[String: Any]] = []
    private let listener: Int32
    private var stopped = false
    var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return recorded }
    init(supported: Bool, jumpSupported: Bool = false) throws {
        path = "/tmp/hhist-\(UUID().uuidString.prefix(8)).sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw HerdrError.connectionFailed("fixture socket") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let status = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard status == 0, listen(listener, 8) == 0 else { close(listener); throw HerdrError.connectionFailed("fixture bind") }
        let listening = listener
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
                let method = request["method"] as? String ?? ""
                let result: [String: Any]
                switch method {
                case "ping":
                    result = supported ? ["type": "pong", "version": "fixture", "protocol": 17, "capabilities": ["agent_conversation_read": true, "agent_conversation_block_read": true, "agent_conversation_jump": jumpSupported]] : ["type": "pong", "version": "fixture", "protocol": 17]
                case "agent.conversation.jump": result = ["type": "agent_conversation_jump", "binding": ["provider": "claude", "session_id": "s", "generation": "g"], "message_id": "m", "message_revision": "mr", "content_seq": 42, "source_row": 17, "offset_from_bottom": 9]
                case "pane.scroll": result = ["type": "pane_scrolled"]
                case "session.snapshot": result = ["type": "session_snapshot", "snapshot": ["agents": [], "workspaces": []]]
                case "agent.conversation.block.read": result = ["type": "agent_conversation_block", "binding": ["provider": "claude", "session_id": "s", "generation": "g"], "revision": "1", "message_id": "m", "message_revision": "mr", "block_id": "b", "kind": "text", "text": "🌍\n", "slice_index": 1]
                default: result = ["type": "agent_conversation", "binding": ["provider": "claude", "session_id": "s", "generation": "g"], "revision": "1", "availability": "ready"]
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
