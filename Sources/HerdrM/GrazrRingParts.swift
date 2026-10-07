import SwiftUI

/// An arc of a ring centred in its frame, between two fractions of a turn
/// measured clockwise from 12 o'clock.
struct RingArc: Shape {
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
struct RadialTick: Shape {
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

/// Where a point a fraction of a turn clockwise from 12 o'clock sits, at
/// `radius` from the centre, as an offset for `.offset`.
func ringOffset(at fraction: Double, radius: CGFloat) -> CGSize {
    let angle = fraction * 2 * .pi - .pi / 2
    return CGSize(width: cos(angle) * radius, height: sin(angle) * radius)
}

/// The popup the dial and the clock show under the pointer.
struct GrazrTipBox<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2, content: content)
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.contentBackground))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.sidebarBorder))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
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
