import XCTest
@testable import HerdrKit

final class ConversationHistoryTests: XCTestCase {
    func testSparseEnvelopeDefaultsAndUnknownBlockRemainInert() throws {
        let data = Data(#"{"type":"agent_conversation","availability":"ready","binding":{"provider":"claude","session_id":"s","generation":"g"},"messages":[{"id":"m","blocks":[{"id":"b","kind":"future","text":"<script>inert</script>"}]}]}"#.utf8)
        let page = try JSONDecoder().decode(ConversationPage.self, from: data)
        XCTAssertEqual(page.binding?.sessionID, "s")
        XCTAssertEqual(page.messages.first?.role, "unknown")
        XCTAssertEqual(page.messages.first?.visibleText, "<script>inert</script>")
        XCTAssertEqual(page.upserts, [])
        XCTAssertNil(page.beforeCursor)
        XCTAssertFalse(try XCTUnwrap(page.messages.first?.blocks.first).truncated)
    }
    func testWireKeysAndEveryReadWindow() throws {
        let windows: [ConversationWindow] = [.latest, .before(cursor: "b"), .after(cursor: "a"), .around(messageID: "m"), .search(query: "unicode 🌍", cursor: nil), .turns(cursor: "t"), .changes(cursor: "c")]
        let kinds = ["latest", "before", "after", "around", "search", "turns", "changes"]
        for (window, kind) in zip(windows, kinds) {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(window.json)) as? [String: Any])
            XCTAssertEqual(object["kind"] as? String, kind)
            XCTAssertNil(object["path"])
        }
        let binding = ConversationBinding(provider: "claude", sessionID: "s", generation: "g")
        let block = BlockPage(binding: binding, revision: "1", messageID: "m", messageRevision: "mr", blockID: "b", kind: "text", text: "🌍\n", sliceIndex: 1)
        XCTAssertEqual(try JSONDecoder().decode(BlockPage.self, from: JSONEncoder().encode(block)), block)
        let wire = String(decoding: try JSONEncoder().encode(block), as: UTF8.self)
        XCTAssertTrue(wire.contains("message_revision")); XCTAssertTrue(wire.contains("slice_index"))
    }
    func testOldAndSupportedPingCapabilityDecoding() throws {
        let old = try JSONDecoder().decode(PingResult.self, from: Data(#"{"version":"x","protocol":17}"#.utf8))
        XCTAssertNil(old.capabilities)
        let current = try JSONDecoder().decode(PingResult.self, from: Data(#"{"version":"x","protocol":17,"capabilities":{"live_handoff":true,"agent_conversation_read":true,"agent_conversation_block_read":true}}"#.utf8))
        XCTAssertEqual(current.capabilities?.agentConversationRead, true)
        XCTAssertEqual(current.capabilities?.agentConversationBlockRead, true)
    }
    func testLimitsAndTypedErrors() {
        XCTAssertEqual(ConversationLimits(limit: 999, maxBytes: Int.max), .init(limit: 200, maxBytes: 1_048_576))
        XCTAssertEqual(ConversationHistoryError.map(HerdrError.rpc(code: "cursor_expired", message: "synthetic")) as? ConversationHistoryError, .cursorExpired)
        XCTAssertEqual(ConversationHistoryError.map(HerdrError.rpc(code: "session_changed", message: "synthetic")) as? ConversationHistoryError, .sessionChanged)
        XCTAssertEqual(ConversationHistoryError.map(HerdrError.rpc(code: "unknown_method", message: "synthetic")) as? ConversationHistoryError, .unsupportedServer)
    }
}
