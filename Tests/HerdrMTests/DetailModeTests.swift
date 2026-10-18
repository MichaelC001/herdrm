import HerdrKit
import XCTest
@testable import herdrm

@MainActor
final class DetailModeTests: XCTestCase {
    func testFileManagerShimMapsToDetailMode() {
        let model = AppModel()
        model.isFileManagerActive = true
        XCTAssertEqual(model.detailMode, .files)
        XCTAssertTrue(model.isDetailCovered)
        model.isFileManagerActive = false
        XCTAssertEqual(model.detailMode, .terminal)
        XCTAssertFalse(model.isDetailCovered)
    }

    func testOpenProjectCoversTheTerminalAndSelectingAnAgentUncoversIt() {
        let model = AppModel()
        model.openProject(nil)
        XCTAssertEqual(model.detailMode, .project)
        XCTAssertFalse(model.isFileManagerActive)
        XCTAssertNil(model.statsDevice)
        model.selectAgent(PaneRef(deviceID: Device.local.id, paneID: "w1:p1"))
        XCTAssertEqual(model.detailMode, .terminal)
    }

    func testOpenProjectSelectsTheGivenSpaceAndClearsTheShell() {
        let model = AppModel()
        let space = SpaceRef(deviceID: Device.local.id, workspaceID: "ws-1")
        model.selectedShellID = UUID()
        model.openProject(space)
        XCTAssertEqual(model.selectedSpace, space)
        XCTAssertNil(model.selectedShellID)
        XCTAssertEqual(model.detailMode, .project)
    }

    func testProjectModeHidesTheClaudeHistory() {
        let model = AppModel()
        model.openProject(nil)
        XCTAssertFalse(model.isClaudeHistorySelected)
    }
}
