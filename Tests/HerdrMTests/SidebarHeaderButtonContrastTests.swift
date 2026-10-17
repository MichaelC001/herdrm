import AppKit
import XCTest
@testable import herdrm

/// The New Space / New Agent / New Terminal buttons are as visible as the
/// section title beside them. In ghost gray they were under 2.2:1 on the
/// sidebar and disappeared whenever something bright sat behind the window.
@MainActor
final class SidebarHeaderButtonContrastTests: XCTestCase {
    func testHeaderButtonIsAsVisibleAsItsTitleInDarkMode() throws {
        try assertButtonMatchesTitle(.darkAqua)
    }

    func testHeaderButtonIsAsVisibleAsItsTitleInLightMode() throws {
        try assertButtonMatchesTitle(.aqua)
    }

    private func assertButtonMatchesTitle(_ appearance: NSAppearance.Name) throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20, appearance: appearance)
        let ink = try sidebar.headerInk()
        XCTAssertGreaterThan(ink.title, 2, "known-yes: the title renders")
        XCTAssertGreaterThanOrEqual(ink.button, ink.title * 0.95, "button \(ink.button):1, title \(ink.title):1")
    }
}
