import HerdrKit
import SwiftUI

/// Geometry has bounded draw cost even when every one of 5,000 turns is indexed.
struct ConversationRailGeometry {
    struct Mark: Equatable {
        let indices: Range<Int>
        let y: CGFloat
        let isSelected: Bool
    }
    let count: Int
    let height: CGFloat
    var zoomedIndex: Int? = nil
    // A short conversation stays a compact stack instead of stretching the
    // ticks over the full terminal. Long conversations still fit the viewport.
    var span: CGFloat { min(max(0, height - 20), CGFloat(max(0, count - 1)) * 6) }
    var inset: CGFloat { max(10, (height - span) / 2) }

    func position(of index: Int) -> CGFloat {
        guard count > 1 else { return height / 2 }
        let index = CGFloat(min(max(index, 0), count - 1))
        let points = mappingPoints
        for pair in zip(points, points.dropFirst()) where index <= pair.1.index {
            let distance = pair.1.index - pair.0.index
            return distance > 0 ? pair.0.y + (index - pair.0.index) / distance * (pair.1.y - pair.0.y) : pair.0.y
        }
        return points.last?.y ?? inset
    }

    func index(at y: CGFloat) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1, span > 0 else { return 0 }
        let points = mappingPoints
        for pair in zip(points, points.dropFirst()) where y <= pair.1.y {
            let distance = pair.1.y - pair.0.y
            let index = distance > 0 ? pair.0.index + (y - pair.0.y) / distance * (pair.1.index - pair.0.index) : pair.0.index
            return min(count - 1, max(0, Int(index.rounded())))
        }
        return count - 1
    }

    func marks(selectedIndex: Int?) -> [Mark] {
        guard count > 0 else { return [] }
        if let focus = zoomedIndex, count > 1, span > 0 {
            let focus = min(max(focus, 0), count - 1)
            let lower = max(0, focus - 6), upper = min(count, focus + 7)
            return clustered(0..<lower, selectedIndex: selectedIndex)
                + (lower..<upper).map { index in
                    Mark(indices: index..<(index + 1), y: position(of: index), isSelected: index == selectedIndex)
                }
                + clustered(upper..<count, selectedIndex: selectedIndex)
        }
        let capacity = max(1, Int(span / 4) + 1)
        let clusterSize = max(1, Int(ceil(Double(count) / Double(capacity))))
        return stride(from: 0, to: count, by: clusterSize).map { start in
            let end = min(count, start + clusterSize)
            return Mark(indices: start..<end, y: position(of: (start + end - 1) / 2),
                        isSelected: selectedIndex.map { (start..<end).contains($0) } ?? false)
        }
    }

    private struct Point { let index: CGFloat; let y: CGFloat }
    private var mappingPoints: [Point] {
        guard let focusedIndex = zoomedIndex, count > 1, span > 0 else {
            return [Point(index: 0, y: inset), Point(index: CGFloat(max(0, count - 1)), y: inset + span)]
        }
        let focus = min(max(focusedIndex, 0), count - 1)
        let lower = max(0, focus - 6), upper = min(count - 1, focus + 6)
        let center = inset + CGFloat(focus) / CGFloat(count - 1) * span
        let spacing = max(span / CGFloat(count - 1), min(24, max(12, span / CGFloat(count - 1) * 2.4)))
        // Keep the hovered mark stationary. Near an edge, magnification is
        // naturally stronger on the side with room; the inverse stays ordered.
        let beforeGap = lower > 0 ? min(4, (center - inset) / 2) : 0
        let afterGap = upper < count - 1 ? min(4, (inset + span - center) / 2) : 0
        let start = max(inset + beforeGap, center - CGFloat(focus - lower) * spacing)
        let end = min(inset + span - afterGap, center + CGFloat(upper - focus) * spacing)
        var points: [Point] = []
        for point in [Point(index: 0, y: inset), Point(index: CGFloat(lower), y: start),
                      Point(index: CGFloat(focus), y: center), Point(index: CGFloat(upper), y: end),
                      Point(index: CGFloat(count - 1), y: inset + span)] {
            if points.last?.index != point.index { points.append(point) }
        }
        return points
    }

    private func clustered(_ range: Range<Int>, selectedIndex: Int?) -> [Mark] {
        guard !range.isEmpty else { return [] }
        let drawableSpan = max(0, position(of: range.upperBound - 1) - position(of: range.lowerBound))
        let capacity = max(1, Int(drawableSpan / 4) + 1)
        let size = max(1, Int(ceil(Double(range.count) / Double(capacity))))
        return stride(from: range.lowerBound, to: range.upperBound, by: size).map { start in
            let end = min(range.upperBound, start + size)
            return Mark(indices: start..<end, y: position(of: (start + end - 1) / 2),
                        isSelected: selectedIndex.map { (start..<end).contains($0) } ?? false)
        }
    }

    static func adjacent(_ current: Int?, delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(count - 1, max(0, (current ?? (delta > 0 ? -1 : count)) + delta))
    }

    static func markWidth(indices: Range<Int>, selected: Bool, previewIndex: Int?) -> CGFloat {
        let resting: CGFloat = selected ? 26 : (indices.count > 1 ? 9 : 7)
        guard let previewIndex else { return resting }
        let distance = indices.contains(previewIndex) ? 0 : min(abs(indices.lowerBound - previewIndex), abs(indices.upperBound - 1 - previewIndex))
        let widths: [CGFloat] = [30, 24, 20, 16, 12, 9, 7]
        return max(resting, widths[min(distance, widths.count - 1)])
    }
}

enum ConversationRailSelection {
    static func index(messageID: String?, turns: [ConversationTurn], messages: [ConversationMessage]) -> Int? {
        guard let messageID else { return nil }
        if let direct = turns.firstIndex(where: { $0.messageID == messageID }) { return direct }
        guard let turnID = messages.first(where: { $0.id == messageID })?.turnID else { return nil }
        return turns.firstIndex { $0.id == turnID }
    }
}

struct ConversationRailPreview {
    let title: String
    let body: String

    init(turn: ConversationTurn, messages: [ConversationMessage]) {
        let lines = turn.preview.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        title = String((lines.first.map(String.init) ?? "").prefix(80))
        let remainder = lines.count > 1 ? String(lines[1]) : ""
        if !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = String(remainder.prefix(200))
        } else if let reply = messages.first(where: { $0.turnID == turn.id && $0.role == "assistant" }),
                  let text = reply.blocks.first(where: { $0.kind == "text" || $0.kind == "code" })?.text {
            body = String(text.prefix(200))
        } else { body = "" }
    }
}

struct ConversationTimelineRail: View {
    @ObservedObject var controller: ConversationHistoryController
    var previewWidth: CGFloat = 320
    var onJump: ((String) -> Void)? = nil
    @State private var previewIndex: Int?
    @State private var hoverAnchorIndex: Int?
    @State private var isHovered = false
    @State private var previewHeight: CGFloat = 148
    @FocusState private var railFocused: Bool

    private var selectedIndex: Int? {
        ConversationRailSelection.index(messageID: controller.selectedMessageID, turns: controller.turns, messages: controller.messages)
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = ConversationRailGeometry(count: controller.turns.count, height: proxy.size.height,
                                                     zoomedIndex: hoverAnchorIndex ?? previewIndex)
            Canvas { context, size in
                for mark in geometry.marks(selectedIndex: selectedIndex) {
                    let hovered = previewIndex.map { mark.indices.contains($0) } ?? false
                    let width = ConversationRailGeometry.markWidth(indices: mark.indices, selected: mark.isSelected, previewIndex: previewIndex)
                    let rect = CGRect(x: (size.width - width) / 2, y: mark.y - 1, width: width, height: 2)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1),
                                 with: .color(mark.isSelected || hovered ? Theme.text : Theme.textGhost.opacity(0.7)))
                }
            }
            .overlay {
                let resting = ConversationRailGeometry(count: controller.turns.count, height: proxy.size.height)
                ConversationRailPointerSurface(
                    activeRange: controller.turns.isEmpty ? nil : (resting.inset - 10)...(resting.inset + resting.span + 10),
                    onHover: { updatePointer($0, height: proxy.size.height) },
                    onClick: { selectPointer($0, height: proxy.size.height) }
                )
            }
            .focusable(!controller.turns.isEmpty)
            .focused($railFocused)
            .focusEffectDisabled()
            .onChange(of: railFocused) { _, focused in
                previewIndex = focused ? (selectedIndex ?? controller.turns.indices.last) : nil
            }
            .onKeyPress(.downArrow) { navigate(1); return .handled }
            .onKeyPress(.upArrow) { navigate(-1); return .handled }
            .onKeyPress(.return) { openPreview(); return .handled }
            .onKeyPress(.space) { openPreview(); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Conversation timeline")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Use arrow keys to preview a turn and Return to jump to it in the terminal.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: navigate(1)
                case .decrement: navigate(-1)
                @unknown default: break
                }
            }
            .accessibilityAction(named: Text("Jump to message")) { openPreview() }
            .accessibilityIdentifier("history.timeline")
            .overlay(alignment: .topLeading) {
                if let index = previewIndex, controller.turns.indices.contains(index), previewWidth >= 100 {
                    let turn = controller.turns[index]
                    let preview = ConversationRailPreview(turn: turn, messages: controller.messages)
                    VStack(alignment: .leading, spacing: 5) {
                        if preview.title.isEmpty {
                            Text("Turn \(turn.ordinal)").font(.system(size: 13, weight: .semibold))
                        } else {
                            Text(verbatim: preview.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        }
                        if !preview.body.isEmpty {
                            Text(verbatim: preview.body).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(3)
                        }
                        HStack(spacing: 8) {
                            Text("Turn \(turn.ordinal)")
                            if let timestamp = turn.timestamp { Text(verbatim: timestamp).lineLimit(1) }
                        }
                        .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                    }
                    .foregroundStyle(Theme.text)
                    .padding(10)
                    .frame(width: previewWidth, alignment: .leading)
                    .background(Theme.historyPreviewBackground, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.sidebarBorder))
                    .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                    .background(GeometryReader { card in Color.clear.preference(key: ConversationPreviewHeightKey.self, value: card.size.height) })
                    .onPreferenceChange(ConversationPreviewHeightKey.self) { previewHeight = $0 }
                    .offset(x: 40, y: max(0, min(geometry.position(of: index) - 24, proxy.size.height - previewHeight)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                } else if isHovered, controller.turns.isEmpty, previewWidth >= 100 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Conversation timeline").font(.system(size: 13, weight: .semibold))
                        Text(unavailableText).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(4)
                    }
                    .padding(10).frame(width: previewWidth, alignment: .leading)
                    .background(Theme.historyPreviewBackground, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.sidebarBorder))
                    .offset(x: 40, y: max(0, proxy.size.height - 150))
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        }
        .frame(width: 36)
        .onChange(of: controller.turns.count) { _, count in
            if let index = previewIndex, index >= count { previewIndex = count > 0 ? count - 1 : nil }
        }
    }

    private var unavailableText: String {
        switch controller.state {
        case .loading, .idle: return String(localized: "Loading saved messages…")
        case .unavailable(let code), .failed(let code): return ConversationHistoryNotice.text(for: code)
        case .ready: return String(localized: "No sent messages in this conversation yet.")
        }
    }

    private var accessibilityValue: String {
        if let index = previewIndex ?? selectedIndex, controller.turns.indices.contains(index) {
            let turn = controller.turns[index]
            return String(localized: "Turn \(turn.ordinal): \(String(turn.preview.prefix(160)))")
        }
        return String(localized: "\(controller.turns.count) turns")
    }

    private func navigate(_ delta: Int) {
        previewIndex = ConversationRailGeometry.adjacent(previewIndex ?? selectedIndex, delta: delta, count: controller.turns.count)
    }
    private func updatePointer(_ point: CGPoint?, height: CGFloat) {
        guard let point else {
            isHovered = false; hoverAnchorIndex = nil
            if !railFocused { previewIndex = nil }
            return
        }
        isHovered = true
        let resting = ConversationRailGeometry(count: controller.turns.count, height: height)
        guard point.y >= resting.inset - 10, point.y <= resting.inset + resting.span + 10 else {
            hoverAnchorIndex = nil
            if !railFocused { previewIndex = nil }
            return
        }
        if hoverAnchorIndex == nil { hoverAnchorIndex = resting.index(at: point.y) }
        let zoomed = ConversationRailGeometry(count: controller.turns.count, height: height, zoomedIndex: hoverAnchorIndex)
        previewIndex = zoomed.index(at: point.y)
    }
    private func selectPointer(_ point: CGPoint, height: CGFloat) {
        let geometry = ConversationRailGeometry(count: controller.turns.count, height: height, zoomedIndex: hoverAnchorIndex ?? previewIndex)
        guard let index = geometry.index(at: point.y), controller.turns.indices.contains(index) else { return }
        previewIndex = index
        onJump?(controller.turns[index].id)
    }
    private func openPreview() {
        if let index = previewIndex ?? selectedIndex ?? controller.turns.indices.last, controller.turns.indices.contains(index) {
            onJump?(controller.turns[index].id)
        }
    }
}

private struct ConversationPreviewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 148
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
