import Foundation

/// grazr's rotation laid out over time, as the Accounts clock draws it: which
/// account carries the work in each stretch, where nothing can run, and when
/// windows refill. A projection at the active account's current pace, picking
/// the way grazr does today (the first listed account with headroom). Parked
/// accounts are taken not to drain: other machines' use is not visible here.
public struct GrazrTimeline: Sendable, Equatable {
    public struct Stretch: Sendable, Equatable {
        /// Nil for a gap: no account has headroom.
        public let account: GrazrAccount?
        public let from: Date
        public let to: Date
        /// The tightest watched window's percent left at `from` and at `to`.
        public let leftAtStart: Int?
        public let leftAtEnd: Int?
    }

    public enum Event: Sendable, Equatable {
        /// grazr moves to `to`, or back to it after a gap.
        case swap(at: Date, to: GrazrAccount)
        /// A window of `account` resets; `group` is "session" or "weekly".
        case refill(at: Date, account: GrazrAccount, group: String)

        public var at: Date {
            switch self {
            case .swap(let at, _), .refill(let at, _, _): return at
            }
        }
    }

    /// Contiguous, from now to now + horizon.
    public let stretches: [Stretch]
    /// In time order.
    public let events: [Event]

    /// A pathological pace must not run the projection away.
    public static let maximumStretches = 200
}

/// One window as the projection carries it forward.
struct ProjectedWindow: Equatable {
    let group: String
    let scope: String?
    var remaining: Double
    var resetsAt: Date?
    let length: TimeInterval?

    init(_ window: GrazrWindow) {
        group = window.group
        scope = window.scope
        remaining = Double(window.remaining)
        resetsAt = window.resetsAt
        length = window.length
    }

    /// The window as it stands at `time`: past its reset it is full again. A
    /// 5-hour window starts over at the first use after that (taken to be
    /// `time`); a weekly one keeps its weekly cadence.
    func settled(at time: Date) -> ProjectedWindow {
        guard let reset = resetsAt, reset <= time else { return self }
        var window = self
        window.remaining = 100
        if let length {
            if group == "session" {
                window.resetsAt = time.addingTimeInterval(length)
            } else {
                let periods = (time.timeIntervalSince(reset) / length).rounded(.down) + 1
                window.resetsAt = reset.addingTimeInterval(periods * length)
            }
        } else {
            window.resetsAt = nil
        }
        return window
    }
}

extension GrazrReport {
    /// grazr's rotation projected from `now` to `now + horizon`.
    public func timeline(now: Date, horizon: TimeInterval) -> GrazrTimeline {
        let end = now.addingTimeInterval(horizon)
        let rates = burnRates(now: now)
        var windows: [String: [ProjectedWindow]] = [:]
        for account in rotation {
            windows[account.id] = account.windows.map(ProjectedWindow.init)
        }
        var stretches: [GrazrTimeline.Stretch] = []
        var events: [GrazrTimeline.Event] = []
        var time = now
        var running = rotation.first { $0.id == active } ?? pick(at: now, windows: windows, leaving: nil)
        // Zero-length hand-overs add no stretch, so the steps need a bound of their own.
        var steps = 0

        while time < end, stretches.count < GrazrTimeline.maximumStretches, steps < 4 * GrazrTimeline.maximumStretches {
            steps += 1
            guard let account = running else {
                let until = min(soonestHeadroom(at: time, windows: windows) ?? end, end)
                if until > time {
                    stretches.append(.init(account: nil, from: time, to: until, leftAtStart: nil, leftAtEnd: nil))
                }
                time = until
                guard time < end, let next = pick(at: time, windows: windows, leaving: nil) else { break }
                events.append(.swap(at: time, to: next))
                running = next
                continue
            }
            let current = (windows[account.id] ?? []).map { $0.settled(at: time) }
            let swapAt = min(runOut(current, from: time, until: end, rates: rates, toEmpty: false) ?? end, end)
            let next = swapAt < end ? pick(at: swapAt, windows: windows, leaving: account) : nil
            // With nowhere to go grazr stays, and the account runs until it is empty.
            let stop = next == nil && swapAt < end
                ? min(runOut(current, from: time, until: end, rates: rates, toEmpty: true) ?? end, end)
                : swapAt
            let (after, refills) = advance(current, from: time, to: stop, rates: rates)
            windows[account.id] = after
            events += refills.map { .refill(at: $0.at, account: account, group: $0.group) }
            if stop > time {
                stretches.append(.init(
                    account: account, from: time, to: stop,
                    leftAtStart: leastLeft(current, at: time), leftAtEnd: leastLeft(after, at: stop)
                ))
            }
            time = stop
            guard time < end else { break }
            if let next {
                events.append(.swap(at: time, to: next))
            }
            running = next
        }
        // Parked accounts refill on schedule too.
        for account in rotation {
            for window in account.windows {
                guard let reset = window.resetsAt, reset > now, reset < end else { continue }
                events.append(.refill(at: reset, account: account, group: window.group))
            }
        }
        return GrazrTimeline(stretches: stretches, events: Self.distinct(events))
    }

    /// In time order, with one refill per account, group and minute: a
    /// per-model week resets with the all-models one.
    private static func distinct(_ events: [GrazrTimeline.Event]) -> [GrazrTimeline.Event] {
        var kept: [GrazrTimeline.Event] = []
        for event in events.sorted(by: { $0.at < $1.at }) {
            if case .refill(let at, let account, let group) = event, kept.contains(where: { other in
                guard case .refill(let otherAt, let otherAccount, let otherGroup) = other else { return false }
                return otherAccount.id == account.id && otherGroup == group && abs(otherAt.timeIntervalSince(at)) < 60
            }) {
                continue
            }
            kept.append(event)
        }
        return kept
    }

    /// Percent per second each watched window loses, from the active account's
    /// last reading (as `swapEstimate` measures it), keyed by group and model.
    func burnRates(now: Date) -> [String: Double] {
        guard let current = accounts.first(where: { $0.id == active }),
              let updated = current.updated.map(Date.init(timeIntervalSince1970:))
        else { return [:] }
        var rates: [String: Double] = [:]
        for window in current.windows {
            guard threshold(for: window) != nil, let resetsAt = window.resetsAt,
                  window.isOpen(now: now), let length = window.length
            else { continue }
            let elapsed = length - resetsAt.timeIntervalSince(updated)
            let used = Double(100 - window.remaining)
            guard elapsed > 0, used > 0 else { continue }
            rates[Self.rateKey(window.group, window.scope)] = used / elapsed
        }
        return rates
    }

    private static func rateKey(_ group: String, _ scope: String?) -> String {
        group + "|" + (scope ?? "")
    }

    private func rate(for window: ProjectedWindow, in rates: [String: Double]) -> Double {
        rates[Self.rateKey(window.group, window.scope)] ?? rates[Self.rateKey(window.group, nil)] ?? 0
    }

    private func threshold(group: String) -> Int? {
        switch group {
        case "session": return sessionThreshold
        case "weekly": return weeklyThreshold
        default: return nil
        }
    }

    /// When the first watched window of an account running from `start` falls
    /// below its threshold (or, `toEmpty`, reaches 0), or nil when none does
    /// before `end`. A window that resets first starts over full.
    private func runOut(
        _ windows: [ProjectedWindow], from start: Date, until end: Date,
        rates: [String: Double], toEmpty: Bool
    ) -> Date? {
        windows.compactMap { window -> Date? in
            guard let threshold = threshold(group: window.group) else { return nil }
            let floor = toEmpty ? 0 : Double(threshold)
            let pace = rate(for: window, in: rates)
            var current = window
            var time = start
            while time < end {
                let headroom = current.remaining - floor
                if headroom < 0 { return time }
                guard pace > 0 else { return nil }
                let hit = time.addingTimeInterval(headroom / pace)
                guard let reset = current.resetsAt, reset <= hit else { return hit }
                current = current.settled(at: reset)
                time = reset
            }
            return nil
        }.min()
    }

    /// The windows of an account that ran from `start` to `stop`, and the
    /// resets it went through on the way.
    private func advance(
        _ windows: [ProjectedWindow], from start: Date, to stop: Date, rates: [String: Double]
    ) -> ([ProjectedWindow], [(at: Date, group: String)]) {
        var refills: [(at: Date, group: String)] = []
        let after = windows.map { window -> ProjectedWindow in
            var current = window
            var time = start
            while let reset = current.resetsAt, reset <= stop {
                refills.append((reset, current.group))
                current = current.settled(at: reset)
                time = reset
            }
            current.remaining = max(0, current.remaining - rate(for: current, in: rates) * stop.timeIntervalSince(time))
            return current
        }
        return (after, refills)
    }

    /// The first account in `ACCOUNTS` order, other than the one leaving and
    /// not blocked, with headroom at `time`, as grazr's `next_account` picks.
    private func pick(at time: Date, windows: [String: [ProjectedWindow]], leaving: GrazrAccount?) -> GrazrAccount? {
        rotation.first { account in
            account.id != leaving?.id && block(for: account, now: time) == nil
                && hasProjectedHeadroom(windows[account.id] ?? [], at: time)
        }
    }

    /// Clearly above the threshold: an account that just ran down sits at
    /// it, give or take floating-point dust, and grazr would move off it again
    /// at its next reading. Counting it as spent keeps two such accounts from
    /// handing over to each other forever at the same moment.
    private func hasProjectedHeadroom(_ windows: [ProjectedWindow], at time: Date) -> Bool {
        windows.allSatisfy { window in
            guard let threshold = threshold(group: window.group) else { return true }
            return window.settled(at: time).remaining > Double(threshold) + Self.thresholdTolerance
        }
    }

    /// Percentage points within which a window counts as at its threshold.
    private static let thresholdTolerance = 0.01

    /// The soonest moment any account has headroom again: when the last of
    /// its low windows resets. Nil when none ever does.
    private func soonestHeadroom(at time: Date, windows: [String: [ProjectedWindow]]) -> Date? {
        rotation.filter { block(for: $0, now: time) == nil }.compactMap { account -> Date? in
            let projected = (windows[account.id] ?? []).map { $0.settled(at: time) }
            if hasProjectedHeadroom(projected, at: time) { return time }
            let low = projected.filter { window in
                guard let threshold = threshold(group: window.group) else { return false }
                return window.remaining <= Double(threshold) + Self.thresholdTolerance
            }
            let resets = low.compactMap(\.resetsAt)
            return resets.count == low.count ? resets.max() : nil
        }.min()
    }

    private func leastLeft(_ windows: [ProjectedWindow], at time: Date) -> Int? {
        windows.filter { threshold(group: $0.group) != nil }
            .map { Int($0.settled(at: time).remaining.rounded()) }
            .min()
    }
}
