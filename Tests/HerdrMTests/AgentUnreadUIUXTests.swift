import AppKit
import HerdrKit
import XCTest
@testable import herdrm

@MainActor
final class AgentUnreadUIUXTests: XCTestCase {
    func testOpeningUnreadAgentClearsOnlyItsDot() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 2, pinnedHeaders: false)
        let entries = sidebar.model.visibleAgents
        finish(entries[0], in: sidebar.model)
        finish(entries[1], in: sidebar.model)
        XCTAssertTrue(sidebar.model.isUnread(entries[0]))
        XCTAssertTrue(sidebar.model.isUnread(entries[1]))
        try sidebar.clickAgentTitleWithoutSettling("Agent 1")
        XCTAssertFalse(sidebar.model.isUnread(entries[0]))
        XCTAssertTrue(sidebar.model.isUnread(entries[1]), "Opening one agent must not read the other")
    }

    func testClickingAlreadySelectedAgentAcknowledgesItsResult() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 1, pinnedHeaders: false)
        let entry = try XCTUnwrap(sidebar.model.visibleAgents.first)
        sidebar.model.selectAgent(entry.ref)
        finish(entry, in: sidebar.model)
        XCTAssertTrue(sidebar.model.isUnread(entry))
        try sidebar.clickAgentTitleWithoutSettling("Agent 1")
        XCTAssertFalse(sidebar.model.isUnread(entry))
    }

    func testClickingCurrentSpaceAcknowledgesShownAgent() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 1, pinnedHeaders: false)
        let entry = try XCTUnwrap(sidebar.model.visibleAgents.first)
        sidebar.model.selectAgent(entry.ref)
        finish(entry, in: sidebar.model)
        XCTAssertTrue(sidebar.model.isUnread(entry))
        try sidebar.clickSpaceTitle("Space 1")
        XCTAssertFalse(sidebar.model.isUnread(entry))
        XCTAssertEqual(sidebar.model.attention(in: try XCTUnwrap(sidebar.model.visibleSpaces.first)), .none)
    }

    func testVisibleCompletionIsReadButCoveredCompletionStaysUnread() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 1, pinnedHeaders: false)
        let entry = try XCTUnwrap(sidebar.model.visibleAgents.first)
        sidebar.model.selectAgent(entry.ref)
        let id = AppModel.AttachedEntry.agent(entry).id
        let terminal = LineBreakTerminalView(frame: .zero)
        AttachViewRegistry.register(terminal, for: id)
        defer { AttachViewRegistry.unregister(id) }
        sidebar.mountTerminal(terminal, focus: true)
        sidebar.activateWindow()
        XCTAssertTrue(NSApp.isActive && terminal.window?.isKeyWindow == true,
                      "Active app: \(NSApp.isActive), key terminal: \(terminal.window?.isKeyWindow.description ?? "no window")")
        finish(entry, in: sidebar.model)
        XCTAssertFalse(sidebar.model.isUnread(entry))
        sidebar.model.detailMode = .files
        finish(entry, in: sidebar.model)
        XCTAssertTrue(sidebar.model.isUnread(entry), "A file view covers the result")
        sidebar.model.detailMode = .terminal
        XCTAssertFalse(sidebar.model.isUnread(entry))
    }

    private func finish(_ entry: AppModel.AgentEntry, in model: AppModel) {
        let deviceID = entry.device.id
        let agents = model.session(deviceID).agents
        var previous = Dictionary(uniqueKeysWithValues: agents.map { ($0.paneID, $0.status) })
        previous[entry.agent.paneID] = .working
        let next = agents.map { $0.paneID == entry.agent.paneID ? $0.updatingStatus(.done) : $0 }
        model.sessions[deviceID]?.agents = next
        model.updateUnreadAgents(previous: previous, agents: next, deviceID: deviceID)
    }
}
