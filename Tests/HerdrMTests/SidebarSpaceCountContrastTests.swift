import AppKit
import XCTest
@testable import herdrm

/// A space row's agent count is as visible as the space's name. In ghost gray
/// the counts disappeared whenever something bright sat behind the window.
@MainActor
final class SidebarSpaceCountContrastTests: XCTestCase {
    func testCountIsAsVisibleAsTheNameInDarkMode() throws {
        try assertCountMatchesName(.darkAqua)
    }

    func testCountIsAsVisibleAsTheNameInLightMode() throws {
        try assertCountMatchesName(.aqua)
    }

    private func assertCountMatchesName(_ appearance: NSAppearance.Name) throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20, appearance: appearance)
        for name in ["Space 2", "All Spaces"] {
            let ink = try sidebar.spaceRowInk(name)
            XCTAssertGreaterThan(ink.name, 2, "known-yes: \(name) renders")
            XCTAssertGreaterThanOrEqual(ink.count, ink.name * 0.95, "\(name): count \(ink.count):1, name \(ink.name):1")
        }
    }
}
