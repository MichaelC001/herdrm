import XCTest
@testable import HerdrKit

final class GrazrTimelineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_876_000)
    private let day: TimeInterval = 86_400
    private let thresholds = ["REMAINING_SESSION": "15", "REMAINING_WEEKLY": "15"]

    private func window(_ group: String, _ remaining: Int, scope: String? = nil, resetsIn hours: Double?) -> GrazrWindow {
        GrazrWindow(
            kind: group, scope: scope, group: group, remaining: remaining,
            resetsAt: hours.map { now.addingTimeInterval($0 * 3600) }
        )
    }

    private func seconds(_ date: Date?) -> Double { date.map { $0.timeIntervalSince(now) } ?? .nan }

    private func assertContiguous(_ timeline: GrazrTimeline, to end: Date, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(timeline.stretches.first?.from, now, file: file, line: line)
        for (earlier, later) in zip(timeline.stretches, timeline.stretches.dropFirst()) {
            XCTAssertEqual(later.from, earlier.to, file: file, line: line)
            XCTAssertLessThan(earlier.from, earlier.to, "no zero-length stretch", file: file, line: line)
        }
        XCTAssertEqual(timeline.stretches.last?.to, end, file: file, line: line)
    }

    func testWithNoPaceTheActiveRunsToTheHorizon() {
        let a = GrazrAccount(id: "a", name: "a", windows: [window("weekly", 60, resetsIn: 100)])
        let report = GrazrReport(active: "a", accounts: [a], order: ["a"], settings: thresholds)

        let timeline = report.timeline(now: now, horizon: day)

        XCTAssertEqual(timeline.stretches, [
            .init(account: a, from: now, to: now.addingTimeInterval(day), leftAtStart: 60, leftAtEnd: 60),
        ])
        XCTAssertEqual(timeline.events, [])
    }

    func testItSwapsToTheFirstListedAccountWithHeadroomWhenTheActiveRunsLow() {
        // 50% used in the 2.5 h since the 5-hour window opened: 20% an hour,
        // so the 50% left reaches the 15% threshold after 1.75 h.
        let a = GrazrAccount(id: "a", name: "a", windows: [
            window("session", 50, resetsIn: 2.5), window("weekly", 90, resetsIn: 100),
        ], updated: now.timeIntervalSince1970)
        let spent = GrazrAccount(id: "s", name: "s", windows: [window("weekly", 0, resetsIn: 60)])
        let b = GrazrAccount(id: "b", name: "b")
        let report = GrazrReport(active: "a", accounts: [a, spent, b], order: ["a", "s", "b"], settings: thresholds)

        let timeline = report.timeline(now: now, horizon: day)

        XCTAssertEqual(timeline.stretches.map(\.account?.id), ["a", "b"])
        XCTAssertEqual(seconds(timeline.stretches[0].to), 1.75 * 3600, accuracy: 1)
        XCTAssertEqual(timeline.stretches[0].leftAtStart, 50)
        XCTAssertEqual(timeline.stretches[0].leftAtEnd, 15)
        assertContiguous(timeline, to: now.addingTimeInterval(day))
        guard case .swap(let at, let to) = timeline.events.first(where: { if case .swap = $0 { return true }; return false }) else {
            return XCTFail("no swap")
        }
        XCTAssertEqual(seconds(at), 1.75 * 3600, accuracy: 1)
        XCTAssertEqual(to.id, "b")
        XCTAssertTrue(timeline.events.contains { event in
            if case .refill(let at, let account, "session") = event { return account.id == "a" && abs(seconds(at) - 2.5 * 3600) < 1 }
            return false
        }, "the 5-hour reset inside the horizon is an event")
    }

    func testWhenNothingHasHeadroomTheActiveRunsDryThenAGapUntilTheSoonestRefill() {
        // 70% used in 1.5 h: the 30% left is gone after 30 / (70 / 1.5) h.
        let a = GrazrAccount(id: "a", name: "a", windows: [window("session", 30, resetsIn: 3.5)], updated: now.timeIntervalSince1970)
        let b = GrazrAccount(id: "b", name: "b", windows: [window("session", 0, resetsIn: 4)])
        let report = GrazrReport(active: "a", accounts: [a, b], order: ["a", "b"], settings: thresholds)

        let timeline = report.timeline(now: now, horizon: day)

        let dry = 30 / (70 / 1.5) * 3600
        XCTAssertEqual(timeline.stretches.prefix(3).map(\.account?.id), ["a", nil, "a"])
        XCTAssertEqual(seconds(timeline.stretches[0].to), dry, accuracy: 1)
        XCTAssertNil(timeline.stretches[1].account)
        XCTAssertEqual(seconds(timeline.stretches[1].to), 3.5 * 3600, accuracy: 1, "a's own window refills first")
        assertContiguous(timeline, to: now.addingTimeInterval(day))
    }

    func testAWeeklyResetInsideTheHorizonIsARefill() {
        let a = GrazrAccount(id: "a", name: "a", windows: [window("weekly", 60, resetsIn: 30)])
        let report = GrazrReport(active: "a", accounts: [a], order: ["a"], settings: thresholds)

        let timeline = report.timeline(now: now, horizon: 7 * day)

        XCTAssertEqual(timeline.events, [.refill(at: now.addingTimeInterval(30 * 3600), account: a, group: "weekly")])
    }

    func testABlockedAccountIsNeverPicked() {
        // a is already below its threshold, so grazr moves at once; b is blocked.
        let a = GrazrAccount(id: "a", name: "a", windows: [window("session", 10, resetsIn: 4)], updated: now.timeIntervalSince1970)
        let b = GrazrAccount(id: "b", name: "b")
        let c = GrazrAccount(id: "c", name: "c")
        let report = GrazrReport(
            active: "a", accounts: [a, b, c], order: ["a", "b", "c"], settings: thresholds,
            blocked: ["b": GrazrBlock(reason: "authentication_failed")]
        )

        let timeline = report.timeline(now: now, horizon: day)

        XCTAssertEqual(timeline.stretches.map(\.account?.id), ["c"])
        XCTAssertEqual(timeline.events.first, .swap(at: now, to: c))
    }

    func testWithNoActiveAccountItStartsOnTheFirstWithHeadroom() {
        let spent = GrazrAccount(id: "s", name: "s", windows: [window("weekly", 0, resetsIn: 60)])
        let b = GrazrAccount(id: "b", name: "b")
        let report = GrazrReport(active: nil, accounts: [spent, b], order: ["s", "b"], settings: thresholds)

        XCTAssertEqual(report.timeline(now: now, horizon: day).stretches.map(\.account?.id), ["b"])
    }

    func testAWindowWithNoResetTimeNeitherHangsNorDrains() {
        let a = GrazrAccount(id: "a", name: "a", windows: [
            window("session", 50, resetsIn: 2.5), window("weekly", 40, resetsIn: nil),
        ], updated: now.timeIntervalSince1970)
        let b = GrazrAccount(id: "b", name: "b")
        let report = GrazrReport(active: "a", accounts: [a, b], order: ["a", "b"], settings: thresholds)

        let timeline = report.timeline(now: now, horizon: day)

        XCTAssertEqual(timeline.stretches.map(\.account?.id), ["a", "b"])
        XCTAssertEqual(seconds(timeline.stretches[0].to), 1.75 * 3600, accuracy: 1)
    }

    func testAnAccountAtExactlyItsThresholdIsNotPickedBack() {
        // a crosses 15% and b has room; when b runs down, a still sits at 15%:
        // the projection must not hand back to a at the same instant.
        // Weekly windows that reset beyond the horizon: 84% used in the 18 h
        // since a's week opened. Without the strict rule the projection would
        // hand a and b back and forth at one instant and stop short.
        let a = GrazrAccount(id: "a", name: "a", windows: [window("weekly", 16, resetsIn: 150)], updated: now.timeIntervalSince1970)
        let b = GrazrAccount(id: "b", name: "b", windows: [window("weekly", 100, resetsIn: 160)])
        let report = GrazrReport(active: "a", accounts: [a, b], order: ["a", "b"], settings: thresholds)

        let timeline = report.timeline(now: now, horizon: day)

        XCTAssertEqual(timeline.stretches.map(\.account?.id), ["a", "b", nil])
        assertContiguous(timeline, to: now.addingTimeInterval(day))
    }

    func testStretchesAreBounded() {
        // 84% gone in the first second of a 5-hour window: the accounts take
        // turns every second, and a gap waits out each reset.
        let a = GrazrAccount(id: "a", name: "a", windows: [window("session", 16, resetsIn: 5 - 1 / 3600.0)], updated: now.timeIntervalSince1970)
        let b = GrazrAccount(id: "b", name: "b", windows: [window("session", 100, resetsIn: 5)])
        let report = GrazrReport(active: "a", accounts: [a, b], order: ["a", "b"], settings: thresholds)

        let timeline = report.timeline(now: now, horizon: 60 * day)

        XCTAssertEqual(timeline.stretches.count, GrazrTimeline.maximumStretches)
    }
}
