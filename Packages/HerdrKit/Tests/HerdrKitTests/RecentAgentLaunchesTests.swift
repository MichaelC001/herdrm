import XCTest
@testable import HerdrKit

final class RecentAgentLaunchesTests: XCTestCase {
    private let local = UUID()
    private let remote = UUID()

    private func launch(_ space: String, _ kind: String = "claude", on device: UUID? = nil,
                        args: [String] = [], at seconds: TimeInterval = 0) -> RecentAgentLaunch {
        RecentAgentLaunch(
            deviceID: device ?? local, kind: kind, spaceLabel: space, directory: "/Users/me/\(space)",
            arguments: args, grazrAccountID: nil, date: Date(timeIntervalSince1970: seconds)
        )
    }

    func testNewestFirst() {
        var list: [RecentAgentLaunch] = []
        list = RecentAgentLaunches.recording(launch("a", at: 1), into: list)
        list = RecentAgentLaunches.recording(launch("b", at: 2), into: list)
        XCTAssertEqual(list.map(\.spaceLabel), ["b", "a"])
    }

    func testRelaunchMovesToTheTopAndKeepsTheLatestArguments() {
        var list = [launch("b", at: 2), launch("a", args: ["--old"], at: 1)]
        list = RecentAgentLaunches.recording(launch("a", args: ["--new"], at: 3), into: list)
        XCTAssertEqual(list.map(\.spaceLabel), ["a", "b"])
        XCTAssertEqual(list.first?.arguments, ["--new"])
    }

    func testSameSpaceOnAnotherDeviceOrKindIsItsOwnEntry() {
        var list = [launch("a")]
        list = RecentAgentLaunches.recording(launch("a", on: remote), into: list)
        list = RecentAgentLaunches.recording(launch("a", "codex"), into: list)
        XCTAssertEqual(list.count, 3)
    }

    func testKeepsTen() {
        var list: [RecentAgentLaunch] = []
        for index in 0..<14 {
            list = RecentAgentLaunches.recording(launch("s\(index)", at: TimeInterval(index)), into: list)
        }
        XCTAssertEqual(list.count, RecentAgentLaunches.limit)
        XCTAssertEqual(list.first?.spaceLabel, "s13")
        XCTAssertEqual(list.last?.spaceLabel, "s4")
    }

    func testRoundTripsThroughDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RecentAgentLaunchesTests"))
        defaults.removePersistentDomain(forName: "RecentAgentLaunchesTests")
        let list = [launch("a", args: ["--dangerously-skip-permissions"])]
        RecentAgentLaunches.save(list, to: defaults)
        XCTAssertEqual(RecentAgentLaunches.load(from: defaults), list)
        defaults.removePersistentDomain(forName: "RecentAgentLaunchesTests")
    }

    func testUnreadableDefaultsLoadEmpty() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RecentAgentLaunchesTests2"))
        defaults.set(Data("nope".utf8), forKey: RecentAgentLaunches.defaultsKey)
        XCTAssertEqual(RecentAgentLaunches.load(from: defaults), [])
        defaults.removePersistentDomain(forName: "RecentAgentLaunchesTests2")
    }
}
