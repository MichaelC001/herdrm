import XCTest
@testable import HerdrKit

final class AgentSessionRefTests: XCTestCase {
    func testOldSnapshotsRemainDecodable() throws {
        let agent = try JSONDecoder().decode(AgentInfo.self, from: Data(#"{"workspace_id":"w1","tab_id":"t1","pane_id":"w1:p1"}"#.utf8))
        let pane = try JSONDecoder().decode(PaneInfo.self, from: Data(#"{"workspace_id":"w1","pane_id":"w1:p1"}"#.utf8))
        XCTAssertNil(agent.agentSession)
        XCTAssertNil(pane.agentSession)
    }
    func testExactClaudeIdentitySurvivesStatusUpdate() throws {
        let data = Data(#"{"workspace_id":"w1","tab_id":"t1","pane_id":"w1:p1","agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"synthetic-session"}}"#.utf8)
        let agent = try JSONDecoder().decode(AgentInfo.self, from: data)
        XCTAssertEqual(agent.agentSession?.sessionID, "synthetic-session")
        XCTAssertEqual(agent.updatingStatus(.working).agentSession, agent.agentSession)
    }
    func testUnknownReferencesNeverBecomeClaudeSessionIDs() {
        for ref in [AgentSessionRef(source: "other", agent: "claude", kind: "id", value: "id"), AgentSessionRef(source: "herdr:claude", agent: "claude", kind: "path", value: "/tmp/a"), AgentSessionRef(source: "herdr:claude", agent: "codex", kind: "id", value: "id"), AgentSessionRef(source: "herdr:claude", agent: "claude", kind: "id", value: "")] {
            XCTAssertFalse(ref.isClaudeID); XCTAssertNil(ref.sessionID)
        }
    }
}
