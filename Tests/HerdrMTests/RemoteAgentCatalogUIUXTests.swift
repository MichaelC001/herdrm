import XCTest
import HerdrKit
@testable import herdrm

@MainActor
final class RemoteAgentCatalogUIUXTests: XCTestCase {
    private let remote = Device(name: "test-server", kind: .ssh(target: "test.invalid"))

    func testOpeningNewAgentShowsOnlyTheDetectedRemoteKinds() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 0, device: remote, sheets: true, pinnedHeaders: false)
        sidebar.model.sessions[remote.id]?.agentCatalog = .loaded(kinds: ["codex"])

        try sidebar.chooseFromSpaceMenu("Space 1", String(localized: "New Agent…"))

        XCTAssertTrue(sidebar.sheetButtonNames.contains("codex"), "\(sidebar.sheetButtonNames)")
        XCTAssertFalse(sidebar.sheetButtonNames.contains("claude"), "\(sidebar.sheetButtonNames)")
        XCTAssertFalse(sidebar.sheetButtonNames.contains("gemini"), "\(sidebar.sheetButtonNames)")
    }

    func testEmptyRemoteCatalogExplainsThatNoCLIWasFound() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 0, device: remote, sheets: true, pinnedHeaders: false)
        sidebar.model.sessions[remote.id]?.agentCatalog = .loaded(kinds: [])

        try sidebar.chooseFromSpaceMenu("Space 1", String(localized: "New Agent…"))

        XCTAssertTrue(sidebar.sheetTexts.contains(String(localized: "No supported agent CLI was found on this server.")), "\(sidebar.sheetTexts)")
    }
}
