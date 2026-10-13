import HerdrKit
import XCTest
@testable import herdrm

/// The history control belongs to the card being activated, independent of
/// the currently selected terminal and of the row's drag/select surface.
@MainActor
final class SidebarAgentHistoryUIUXTests: XCTestCase {
    func testPointerOpensHistoryForAnUnselectedClaudeCard() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20)
        sidebar.selectFirstAgent()
        sidebar.scroll(.offset(520))
        let target = try XCTUnwrap(sidebar.model.visibleAgents.first { $0.agent.paneID == "pane-1" })
        XCTAssertNotEqual(sidebar.model.selectedPane, target.ref)

        try sidebar.clickAgentHistoryButton(for: target)

        XCTAssertEqual(sidebar.model.selectedPane, target.ref)
        XCTAssertTrue(sidebar.model.conversationHistory.isPresented, "the native row drag host must not intercept the history button")
        XCTAssertEqual(sidebar.model.conversationHistory.state, .unavailable("no_binding"))
    }

    func testVoiceOverOpensTheExactClaudeCodeCardWithoutABinding() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20, agentKinds: ["claude", "claude-code", "codex"])
        sidebar.selectFirstAgent()
        let target = try XCTUnwrap(sidebar.model.visibleAgents.first { $0.agent.paneID == "pane-1" })
        let ids = sidebar.agentHistoryButtons.compactMap(\.identifier)
        XCTAssertEqual(Set(ids).count, ids.count, "each agent's history control has a unique identifier")
        XCTAssertTrue(sidebar.agentHistoryButtons.allSatisfy { $0.name == String(localized: "Read full conversation") })

        try sidebar.pressAgentHistoryButton(for: target)

        XCTAssertEqual(sidebar.model.selectedPane, target.ref)
        XCTAssertTrue(sidebar.model.conversationHistory.isPresented)
        XCTAssertEqual(sidebar.model.conversationHistory.state, .unavailable("no_binding"))
    }

    func testOtherAgentsHaveNoHistoryControlAndCannotOpenHistory() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20, terminals: 2, agentKinds: ["claude", "codex", "shell"])
        sidebar.selectFirstAgent()
        let selected = sidebar.model.selectedPane
        let other = try XCTUnwrap(sidebar.model.visibleAgents.first { $0.agent.paneID == "pane-1" })
        let shell = try XCTUnwrap(sidebar.model.visibleAgents.first { $0.agent.paneID == "pane-2" })
        let ids = Set(sidebar.agentHistoryButtons.compactMap(\.identifier))
        XCTAssertFalse(ids.contains("sidebar.agent.history.\(other.id)"))
        XCTAssertFalse(ids.contains("sidebar.agent.history.\(shell.id)"))

        sidebar.model.openConversationHistory(for: other.ref)
        XCTAssertEqual(sidebar.model.selectedPane, selected)
        XCTAssertFalse(sidebar.model.conversationHistory.isPresented)
        sidebar.model.openConversationHistory(for: PaneRef(deviceID: other.device.id, paneID: "removed-pane"))
        XCTAssertEqual(sidebar.model.selectedPane, selected)
        XCTAssertFalse(sidebar.model.conversationHistory.isPresented)
    }

    func testHistoryControlPreservesTaggedAndUntaggedCardHeights() throws {
        let variants: [[String: String]?] = [nil, ["claude_usage": "5h 7% 3h21m · 7d 2% 6d18h"]]
        for tokens in variants {
            let claude = try SidebarHarness(spaces: 14, agents: 20, agentTokens: tokens)
            let other = try SidebarHarness(spaces: 14, agents: 20, agentTokens: tokens, agentKinds: Array(repeating: "codex", count: 20))
            XCTAssertEqual(claude.listHeight, other.listHeight, accuracy: 1, "a footer overlay must not add a row")
            XCTAssertEqual(claude.listWidth, other.listWidth, accuracy: 1)
        }
    }
}
