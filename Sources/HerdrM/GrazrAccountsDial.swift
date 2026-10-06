import HerdrKit
import SwiftUI

/// The Accounts sheet's dial: grazr's rotation as a clock. One equal slice per
/// account in the order they come round, starting at 12 with the active one
/// and running clockwise: the account grazr moves to next, then the rest by
/// when they refill. Inside a slice time runs clockwise too, from all left to
/// nothing: the hand stands in the active account's slice at what it has
/// used, the tick is where grazr swaps, and the next account is marked.
struct GrazrAccountsDial: View {
    let report: GrazrReport
    let window: GrazrDialWindow
    let now: Date

    private let ringRadius: CGFloat = 104
    private let ringWidth: CGFloat = 14

    private var rotation: [GrazrAccount] { report.dialOrder(now: now) }
    private var active: GrazrAccount? { report.accounts.first { $0.id == report.active } }
    private var next: GrazrAccount? { report.predictedNext(now: now) }

    var body: some View {
        VStack(spacing: 14) {
            if rotation.isEmpty {
                Text("No account is listed in ACCOUNTS, so grazr has nothing to rotate through.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 40)
            } else {
                dial
                    .frame(width: (ringRadius + 40) * 2, height: (ringRadius + 40) * 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilitySummary)
            }
            legend
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Dial

    private var dial: some View {
        let count = rotation.count
        return ZStack {
            ForEach(Array(rotation.enumerated()), id: \.element.id) { index, account in
                slice(account, index: index, count: count)
            }
            ForEach(Array(rotation.enumerated()), id: \.element.id) { index, account in
                badge(index: index, account: account)
                    .offset(offset(at: middle(index, count), radius: ringRadius + 26))
            }
            centre
                .frame(width: (ringRadius - ringWidth) * 1.55)
        }
    }

    /// Where a slice starts and ends, as fractions of the turn from 12 o'clock.
    private func bounds(_ index: Int, _ count: Int) -> (start: Double, end: Double) {
        let span = 1 / Double(count)
        let gap = count > 1 ? min(0.014, span * 0.1) : 0
        return (Double(index) * span + gap / 2, Double(index + 1) * span - gap / 2)
    }

    private func middle(_ index: Int, _ count: Int) -> Double {
        let (start, end) = bounds(index, count)
        return (start + end) / 2
    }

    @ViewBuilder
    private func slice(_ account: GrazrAccount, index: Int, count: Int) -> some View {
        let (start, end) = bounds(index, count)
        let length = end - start
        let reading = account.window(window)
        let left = reading?.left(now: now)
        let threshold = reading.flatMap(report.threshold(for:))
        let isActive = account.id == report.active
        // Dimmed where grazr would not move in now: blocked, or below a
        // threshold in a window the dial may not be showing.
        let usable = isActive || (report.block(for: account, now: now) == nil && report.hasHeadroom(account, now: now))
        // Clockwise from all left at the slice's start to nothing at its end.
        let hand = start + Double(100 - (left ?? 100)) / 100 * length

        RingArc(start: start, end: end, radius: ringRadius)
            .stroke(Theme.textGhost.opacity(0.28), style: StrokeStyle(lineWidth: ringWidth, lineCap: .butt))
        if let left, left > 0 {
            RingArc(start: hand, end: end, radius: ringRadius)
                .stroke(
                    GrazrStyle.tint(left: left, threshold: threshold).opacity(usable ? 1 : 0.3),
                    style: StrokeStyle(lineWidth: ringWidth, lineCap: .butt)
                )
        }
        if let threshold {
            RadialTick(at: start + Double(100 - threshold) / 100 * length, from: ringRadius - ringWidth / 2 - 3, to: ringRadius + ringWidth / 2 + 3)
                .stroke(Theme.textSecondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        if account.id == next?.id {
            RingArc(start: start, end: end, radius: ringRadius + ringWidth / 2 + 5)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
        if isActive {
            // A needle across the ring, clear of the centre text wherever the slice is.
            RadialTick(at: hand, from: ringRadius - ringWidth / 2 - 7, to: ringRadius + ringWidth / 2 + 6)
                .stroke(Theme.statsAccount, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            Circle()
                .fill(Theme.statsAccount)
                .frame(width: 7, height: 7)
                .offset(offset(at: hand, radius: ringRadius - ringWidth / 2 - 7))
        }
    }

    private func badge(index: Int, account: GrazrAccount) -> some View {
        let isActive = account.id == report.active
        let isNext = account.id == next?.id
        return Text("\(index + 1)")
            .font(.system(size: 10.5, weight: .bold).monospacedDigit())
            .foregroundStyle(isActive ? Color.white : isNext ? Theme.accent : Theme.textSecondary)
            .frame(width: 18, height: 18)
            .background(
                Circle().fill(isActive ? Theme.statsAccount : Theme.itemWashSelected)
            )
            .overlay(Circle().stroke(isNext ? Theme.accent : .clear, lineWidth: 1.5))
            .help(account.name)
    }

    private var centre: some View {
        VStack(spacing: 3) {
            if let active {
                Text(active.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.statsAccount)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let left = active.window(window)?.left(now: now) {
                    Text("\(left)% left")
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundStyle(GrazrStyle.tint(left: left, threshold: active.window(window).flatMap(report.threshold(for:))))
                } else {
                    Text("No reading yet")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(swapText(for: active))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("Not logged in")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            Group {
                if let next {
                    Text("next ▸")
                        .foregroundStyle(Theme.accent)
                    Text(next.name)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.accent)
                    if let refill = futureRefill(of: next) {
                        Text("refills \(GrazrStyle.time(refill, now: now))")
                            .foregroundStyle(Theme.textTertiary)
                    }
                } else {
                    Text("nothing to swap to")
                        .foregroundStyle(Theme.textTertiary)
                    if let refill = report.nextHeadroom(now: now) {
                        Text(refill.account.name)
                            .foregroundStyle(Theme.textSecondary)
                        Text("refills \(GrazrStyle.time(refill.at, now: now))")
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.top, 2)
        }
        .multilineTextAlignment(.center)
    }

    private func swapText(for account: GrazrAccount) -> String {
        if let eta = report.swapEstimate(for: account, now: now) {
            return eta <= now
                ? String(localized: "below the threshold, swaps next turn")
                : String(localized: "swaps ~\(GrazrStyle.time(eta, now: now))")
        }
        let used = account.windows.contains { report.threshold(for: $0) != nil && $0.isOpen(now: now) && $0.remaining < 100 }
        return used ? String(localized: "refills before it runs out") : String(localized: "no pace yet")
    }

    /// When an account that is spent now is full again, if that is later.
    private func futureRefill(of account: GrazrAccount) -> Date? {
        report.availableAt(account, now: now).flatMap { $0 > now ? $0 : nil }
    }

    private var nextText: String {
        if let next {
            guard let refill = futureRefill(of: next) else { return String(localized: "next ▸ \(next.name)") }
            return String(localized: "next ▸ \(next.name), refills \(GrazrStyle.time(refill, now: now))")
        }
        if let refill = report.nextHeadroom(now: now) {
            return String(localized: "nothing to swap to · \(refill.account.name) refills \(GrazrStyle.time(refill.at, now: now))")
        }
        return String(localized: "nothing to swap to")
    }

    private var accessibilitySummary: String {
        guard let active else { return nextText }
        let left = (active.window(window)?.left(now: now)).map { String(localized: "\($0)% left") }
            ?? String(localized: "no reading yet")
        return [active.name, left, swapText(for: active), nextText].joined(separator: ", ")
    }

    // MARK: - Legend

    private var legend: some View {
        let unlisted = report.sortedAccounts.filter { account in !rotation.contains { $0.id == account.id } }
        return VStack(spacing: 0) {
            ForEach(Array(rotation.enumerated()), id: \.element.id) { index, account in
                legendRow(number: index + 1, account: account)
            }
            ForEach(unlisted) { account in
                legendRow(number: nil, account: account)
            }
        }
        .padding(.horizontal, 4)
    }

    private func legendRow(number: Int?, account: GrazrAccount) -> some View {
        let isActive = account.id == report.active
        let left = account.window(window)?.left(now: now)
        let (status, color) = status(of: account)
        return HStack(spacing: 8) {
            Text(number.map { "\($0)" } ?? "–")
                .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 14, alignment: .trailing)
            Circle()
                .fill(isActive ? Theme.statsAccount : .clear)
                .overlay(Circle().stroke(isActive ? .clear : Theme.textGhost, lineWidth: 1.2))
                .frame(width: 8, height: 8)
            Text(account.name)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Theme.statsAccount : Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(left.map { "\($0)%" } ?? "–")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(left.map { GrazrStyle.tint(left: $0, threshold: account.window(window).flatMap(report.threshold(for:))) } ?? Theme.textTertiary)
                .frame(width: 40, alignment: .trailing)
            Text(status)
                .font(.system(size: 11, weight: account.id == next?.id ? .semibold : .regular))
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private func status(of account: GrazrAccount) -> (String, Color) {
        if account.id == report.active {
            let eta = report.swapEstimate(for: account, now: now).flatMap { $0 > now ? $0 : nil }
            return (eta.map { String(localized: "active · ~\(GrazrStyle.time($0, now: now))") } ?? String(localized: "active"), Theme.statsAccount)
        }
        if let block = report.block(for: account, now: now) {
            return (String(localized: "blocked: \(block.reason)"), Theme.danger)
        }
        if account.id == next?.id {
            guard let refill = futureRefill(of: account) else { return (String(localized: "NEXT ▸"), Theme.accent) }
            return (String(localized: "NEXT · refills \(GrazrStyle.time(refill, now: now))"), Theme.accent)
        }
        if !report.isListed(account) { return (String(localized: "not in ACCOUNTS"), Theme.textTertiary) }
        if account.windows.isEmpty { return (String(localized: "no reading yet"), Theme.textTertiary) }
        let low = account.windows.filter { window in
            guard let threshold = report.threshold(for: window), window.isOpen(now: now) else { return false }
            return window.remaining < threshold
        }
        if let refill = low.compactMap(\.resetsAt).max() {
            return (String(localized: "spent · resets \(GrazrStyle.time(refill, now: now))"), Theme.textTertiary)
        }
        return (String(localized: "ready"), Theme.textSecondary)
    }

    private func offset(at fraction: Double, radius: CGFloat) -> CGSize {
        let angle = fraction * 2 * .pi - .pi / 2
        return CGSize(width: cos(angle) * radius, height: sin(angle) * radius)
    }
}

/// An arc of a ring centred in its frame, between two fractions of a turn
/// measured clockwise from 12 o'clock.
private struct RingArc: Shape {
    let start: Double
    let end: Double
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard end > start else { return path }
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let steps = max(2, Int((end - start) * 180))
        for step in 0...steps {
            let angle = (start + (end - start) * Double(step) / Double(steps)) * 2 * .pi - .pi / 2
            let point = CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}

/// A line along a radius, at a fraction of a turn clockwise from 12 o'clock.
private struct RadialTick: Shape {
    let at: Double
    let from: CGFloat
    let to: CGFloat

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let angle = at * 2 * .pi - .pi / 2
        var path = Path()
        path.move(to: CGPoint(x: centre.x + cos(angle) * from, y: centre.y + sin(angle) * from))
        path.addLine(to: CGPoint(x: centre.x + cos(angle) * to, y: centre.y + sin(angle) * to))
        return path
    }
}

/// How the Accounts cards and dial colour a reading and say a time.
enum GrazrStyle {
    static func tint(left: Int, threshold: Int?) -> Color {
        if left <= 2 { return Theme.danger }
        if let threshold, left < threshold { return Theme.warning }
        return Theme.success
    }

    /// "14:00" today, "Thu 14:00" on another day.
    static func time(_ date: Date, now: Date) -> String {
        let format = Calendar.current.isDate(date, inSameDayAs: now)
            ? Date.FormatStyle().hour().minute()
            : Date.FormatStyle().weekday(.abbreviated).hour().minute()
        return date.formatted(format)
    }
}
