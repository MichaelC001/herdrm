import XCTest
@testable import HerdrKit

final class ClaudeTranscriptIndexTests: XCTestCase {
    private func line(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private func prompt(_ uuid: String, parent: String?, _ text: String, at time: String = "2026-10-13T10:00:00.000Z") -> String {
        line(["type": "user", "uuid": uuid, "parentUuid": parent ?? NSNull(), "timestamp": time,
              "origin": ["kind": "human"], "turnOrigin": "human", "promptSource": "typed",
              "message": ["role": "user", "content": text]])
    }

    private func reply(_ uuid: String, parent: String, id: String, _ content: [[String: Any]]) -> String {
        line(["type": "assistant", "uuid": uuid, "parentUuid": parent, "timestamp": "2026-10-13T10:00:01.000Z",
              "message": ["id": id, "role": "assistant", "content": content]])
    }

    private func toolResult(_ uuid: String, parent: String) -> String {
        line(["type": "user", "uuid": uuid, "parentUuid": parent,
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]]])
    }

    private func index(_ text: String) -> ClaudeTranscriptIndex {
        var index = ClaudeTranscriptIndex(sessionID: "s1", generation: "g1")
        index.ingest(Data(text.utf8))
        return index
    }

    private var conversation: String {
        prompt("u1", parent: nil, "first question")
            + reply("a1", parent: "u1", id: "m1", [["type": "thinking", "thinking": "hidden"]])
            + reply("a2", parent: "a1", id: "m1", [["type": "text", "text": "Looking."]])
            + reply("a3", parent: "a2", id: "m1", [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls -la"]]])
            + toolResult("r1", parent: "a3")
            + reply("a4", parent: "r1", id: "m2", [["type": "text", "text": "Done."]])
            + line(["type": "system", "subtype": "turn_duration", "uuid": "s1", "parentUuid": "a4"])
            + prompt("u2", parent: "s1", "second question")
            + reply("a5", parent: "u2", id: "m3", [["type": "text", "text": "Answer two."]])
    }

    func testMergesSplitAssistantLinesAndHidesToolResultsAndThinking() throws {
        let page = try index(conversation).page(.latest)
        XCTAssertEqual(page.messages.map(\.id), ["u1", "a-m1", "a-m2", "u2", "a-m3"])
        let first = try XCTUnwrap(page.messages.first { $0.id == "a-m1" })
        XCTAssertEqual(first.blocks.map(\.kind), ["text", "tool_use"])
        XCTAssertEqual(first.blocks.last?.name, "Bash")
        XCTAssertEqual(first.blocks.last?.text, "ls -la")
        XCTAssertEqual(first.turnID, "u1")
        XCTAssertEqual(page.messages.last?.turnID, "u2")
        XCTAssertEqual(page.turns.map(\.messageID), ["u1", "u2"])
        XCTAssertEqual(page.turns.map(\.preview), ["first question", "second question"])
        XCTAssertEqual(page.binding, ConversationBinding(provider: "claude", sessionID: "s1", generation: "g1"))
        XCTAssertEqual(page.completeness, "source_available")
    }

    func testChunkBoundariesDoNotMatter() throws {
        let bytes = Array(conversation.utf8)
        var index = ClaudeTranscriptIndex(sessionID: "s1", generation: "g1")
        for chunk in stride(from: 0, to: bytes.count, by: 7) {
            index.ingest(Data(bytes[chunk..<min(chunk + 7, bytes.count)]))
        }
        XCTAssertEqual(try index.page(.latest).messages.map(\.id), ["u1", "a-m1", "a-m2", "u2", "a-m3"])
    }

    func testTrailingPartialLineIsReportedAndCompletedLater() throws {
        var index = ClaudeTranscriptIndex(sessionID: "s1", generation: "g1")
        let text = conversation
        let cut = text.index(text.endIndex, offsetBy: -20)
        index.ingest(Data(text[..<cut].utf8))
        XCTAssertEqual(try index.page(.latest).completeness, "partial_trailing_record")
        XCTAssertEqual(try index.page(.latest).messages.last?.id, "u2")
        index.ingest(Data(text[cut...].utf8))
        XCTAssertEqual(try index.page(.latest).completeness, "source_available")
        XCTAssertEqual(try index.page(.latest).messages.last?.id, "a-m3")
    }

    func testRewindShowsOnlyTheActiveBranchAndReportsTheRemovedMessages() throws {
        var index = self.index(conversation)
        let cursor = try XCTUnwrap(index.page(.latest).changesCursor)
        // Editing the second prompt branches from the turn-duration record.
        index.ingest(Data((prompt("u3", parent: "s1", "second question, edited")
            + reply("a6", parent: "u3", id: "m4", [["type": "text", "text": "Edited answer."]])).utf8))
        let latest = try index.page(.latest)
        XCTAssertEqual(latest.messages.map(\.id), ["u1", "a-m1", "a-m2", "u3", "a-m4"])
        let changes = try index.page(.changes(cursor: cursor))
        XCTAssertEqual(Set(changes.removedMessageIDs), ["u2", "a-m3"])
        XCTAssertEqual(changes.upserts.map(\.id), ["u3", "a-m4"])
        XCTAssertEqual(changes.turns.map(\.messageID), ["u1", "u3"])
    }

    func testChangesCarryOnlyNewAndGrownMessages() throws {
        var index = self.index(conversation)
        let cursor = try XCTUnwrap(index.page(.latest).changesCursor)
        XCTAssertTrue(try index.page(.changes(cursor: cursor)).upserts.isEmpty)
        index.ingest(Data(reply("a7", parent: "a5", id: "m3", [["type": "text", "text": "More."]]).utf8))
        let changes = try index.page(.changes(cursor: cursor))
        XCTAssertEqual(changes.upserts.map(\.id), ["a-m3"])
        XCTAssertEqual(changes.upserts.first?.blocks.compactMap(\.text), ["Answer two.", "More."])
        XCTAssertTrue(changes.turns.isEmpty, "turns did not change")
    }

    func testCompactionContinuesThroughTheLogicalParent() throws {
        var text = conversation
        text += line(["type": "user", "uuid": "c1", "parentUuid": NSNull(), "logicalParentUuid": "a5",
                      "isCompactSummary": true, "message": ["role": "user", "content": "Summary of earlier work."]])
        text += prompt("u4", parent: "c1", "after compaction")
        let page = try index(text).page(.latest)
        XCTAssertEqual(page.messages.map(\.id), ["u1", "a-m1", "a-m2", "u2", "a-m3", "c1", "u4"])
        XCTAssertEqual(page.messages.first { $0.id == "c1" }?.origin, "system")
        XCTAssertEqual(page.turns.map(\.messageID), ["u1", "u2", "u4"])
    }

    func testCompactBoundaryContinuesFromTheRecordWrittenBeforeIt() throws {
        // Claude 2.1.29x: the boundary has no parent and its logical parent points at an
        // attachment written after the summary, so only file order leads back.
        var text = prompt("u1", parent: nil, "before compaction")
            + reply("a1", parent: "u1", id: "m1", [["type": "text", "text": "old reply"]])
        text += line(["type": "ai-title", "aiTitle": "t"])
        text += line(["type": "system", "subtype": "compact_boundary", "uuid": "cb", "parentUuid": NSNull(), "logicalParentUuid": "at"])
        text += line(["type": "user", "uuid": "sum", "parentUuid": "cb", "isCompactSummary": true,
                      "message": ["role": "user", "content": "Summary."]])
        text += line(["type": "attachment", "uuid": "at", "parentUuid": "sum"])
        text += prompt("u2", parent: "at", "after compaction")
        let page = try index(text).page(.latest)
        XCTAssertEqual(page.messages.map(\.id), ["u1", "a-m1", "sum", "u2"])
        XCTAssertEqual(page.turns.map(\.messageID), ["u1", "u2"])
        XCTAssertEqual(page.completeness, "source_available")
    }

    func testClassifiesCommandsShellAndAutomaticMessages() throws {
        var text = prompt("u1", parent: nil, "<command-message>loop</command-message>\n<command-name>/loop</command-name>\n<command-args>5m check</command-args>")
        text += line(["type": "user", "uuid": "b1", "parentUuid": "u1", "message": ["role": "user", "content": "<bash-input>ls</bash-input>"]])
        text += line(["type": "user", "uuid": "b2", "parentUuid": "b1", "turnOrigin": "human",
                      "message": ["role": "user", "content": "<bash-stdout>a\nb</bash-stdout><bash-stderr></bash-stderr>"]])
        text += line(["type": "user", "uuid": "n1", "parentUuid": "b2", "turnOrigin": "task_notification",
                      "origin": ["kind": "task-notification"], "message": ["role": "user", "content": "<task-notification>done</task-notification>"]])
        text += line(["type": "user", "uuid": "t1", "parentUuid": "n1",
                      "message": ["role": "user", "content": "Another Claude session sent a message: <teammate-message teammate_id=\"rev\">done</teammate-message>"]])
        text += line(["type": "user", "uuid": "m1", "parentUuid": "t1", "isMeta": true,
                      "message": ["role": "user", "content": "Base directory for this skill"]])
        let page = try index(text).page(.latest)
        XCTAssertEqual(page.messages.map(\.id), ["u1", "b1", "b2", "n1", "t1"])
        XCTAssertEqual(page.messages[0].blocks.first?.text, "/loop 5m check")
        XCTAssertEqual(page.messages[1].blocks.first?.text, "! ls")
        XCTAssertEqual(page.messages[2].origin, "tool")
        XCTAssertEqual(page.messages[2].blocks.first?.text, "a\nb")
        XCTAssertEqual(page.messages[3].origin, "automatic")
        XCTAssertEqual(page.messages[4].origin, "automatic", "a teammate's message is not a prompt")
        XCTAssertEqual(page.turns.map(\.messageID), ["u1", "b1"])
    }

    func testSidechainAndMalformedLines() throws {
        var text = conversation
        text += line(["type": "user", "uuid": "x1", "parentUuid": "a5", "isSidechain": true,
                      "message": ["role": "user", "content": "subagent prompt"]])
        text += "{not json\n"
        let page = try index(text).page(.latest)
        XCTAssertEqual(page.messages.last?.id, "a-m3")
        XCTAssertEqual(page.completeness, "partial_unsupported_records")
    }

    func testPagingWalksOlderAndNewerWithCursors() throws {
        var text = ""
        var parent: String?
        for n in 0..<10 {
            text += prompt("u\(n)", parent: parent, "question \(n)")
            parent = "u\(n)"
        }
        let index = index(text)
        let latest = try index.page(.latest, limits: .init(limit: 4))
        XCTAssertEqual(latest.messages.map(\.id), ["u6", "u7", "u8", "u9"])
        XCTAssertNil(latest.afterCursor)
        let older = try index.page(.before(cursor: try XCTUnwrap(latest.beforeCursor)), limits: .init(limit: 4))
        XCTAssertEqual(older.messages.map(\.id), ["u2", "u3", "u4", "u5"])
        let oldest = try index.page(.before(cursor: try XCTUnwrap(older.beforeCursor)), limits: .init(limit: 4))
        XCTAssertEqual(oldest.messages.map(\.id), ["u0", "u1"])
        XCTAssertNil(oldest.beforeCursor)
        let newer = try index.page(.after(cursor: try XCTUnwrap(oldest.afterCursor)), limits: .init(limit: 4))
        XCTAssertEqual(newer.messages.map(\.id), ["u2", "u3", "u4", "u5"])
        let around = try index.page(.around(messageID: "u5"), limits: .init(limit: 4))
        XCTAssertEqual(around.messages.map(\.id), ["u3", "u4", "u5", "u6"])
        XCTAssertEqual(around.turns, [], "only latest and turns windows carry the turn index")
    }

    func testCursorsFromAnotherGenerationExpire() {
        let index = index(conversation)
        XCTAssertThrowsError(try index.page(.before(cursor: "other|3"))) {
            XCTAssertEqual($0 as? ConversationHistoryError, .cursorExpired)
        }
        XCTAssertThrowsError(try index.page(.changes(cursor: "g1|999"))) {
            XCTAssertEqual($0 as? ConversationHistoryError, .cursorExpired)
        }
    }

    func testSearchMatchesTextAndToolNames() throws {
        let index = index(conversation)
        XCTAssertEqual(try index.page(.search(query: "ANSWER")).matchMessageIDs, ["a-m3"])
        XCTAssertEqual(try index.page(.search(query: "bash")).matchMessageIDs, ["a-m1"])
        XCTAssertEqual(try index.page(.search(query: "  ")).matchMessageIDs, [])
    }

    func testLongBlocksAreTruncatedAndReadBackInSlices() throws {
        let long = String(repeating: "abcdefghij", count: 3_000)
        let text = prompt("u1", parent: nil, "q") + reply("a1", parent: "u1", id: "m1", [["type": "text", "text": long]])
        let index = index(text)
        let block = try XCTUnwrap(index.page(.latest).messages.last?.blocks.first)
        XCTAssertTrue(block.truncated)
        XCTAssertEqual(block.text?.count, ClaudeTranscriptIndex.inlineCharacters)
        var rebuilt = block.text ?? ""
        var cursor = block.blockCursor
        var slice = 1
        while let next = cursor {
            let page = try index.block(cursor: next, maxBytes: 4_096)
            XCTAssertEqual(page.sliceIndex, slice)
            XCTAssertEqual(page.blockID, block.id)
            rebuilt += page.text
            cursor = page.nextCursor
            slice += 1
        }
        XCTAssertEqual(rebuilt, long)
    }

    func testJumpTargetCountsPromptsSharingTheSameStart() throws {
        var text = prompt("u1", parent: nil, "continue")
        text += prompt("u2", parent: "u1", "something else\nsecond line")
        text += prompt("u3", parent: "u2", "continue")
        let index = index(text)
        let page = try index.page(.latest)
        let third = try XCTUnwrap(page.messages.first { $0.id == "u3" })
        XCTAssertEqual(try index.jumpTarget(messageID: "u3", messageRevision: third.messageRevision),
                       .init(key: "continue", occurrence: 1, occurrences: 2))
        let second = try XCTUnwrap(page.messages.first { $0.id == "u2" })
        XCTAssertEqual(try index.jumpTarget(messageID: "u2", messageRevision: second.messageRevision).key, "something else")
        XCTAssertThrowsError(try index.jumpTarget(messageID: "u3", messageRevision: "stale")) {
            XCTAssertEqual($0 as? ConversationJumpNotice, .messageChanged)
        }
    }
}
