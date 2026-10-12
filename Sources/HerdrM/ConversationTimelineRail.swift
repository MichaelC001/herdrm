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
    let inset: CGFloat = 10
    var span: CGFloat { max(0, height - 2 * inset) }

    func position(of index: Int) -> CGFloat {
        guard count > 1 else { return height / 2 }
        return inset + CGFloat(min(max(index, 0), count - 1)) / CGFloat(count - 1) * span
    }

    func index(at y: CGFloat) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1, span > 0 else { return 0 }
        return min(count - 1, max(0, Int(((y - inset) / span * CGFloat(count - 1)).rounded())))
    }

    func marks(selectedIndex: Int?) -> [Mark] {
        guard count > 0 else { return [] }
        let capacity = max(1, Int(span / 4) + 1)
        let clusterSize = max(1, Int(ceil(Double(count) / Double(capacity))))
        return stride(from: 0, to: count, by: clusterSize).map { start in
            let end = min(count, start + clusterSize)
            return Mark(indices: start..<end, y: position(of: (start + end - 1) / 2),
                        isSelected: selectedIndex.map { (start..<end).contains($0) } ?? false)
        }
    }

    static func adjacent(_ current: Int?, delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(count - 1, max(0, (current ?? (delta > 0 ? -1 : count)) + delta))
    }
}

struct ConversationTimelineRail: View {
    @ObservedObject var controller: ConversationHistoryController
    var previewWidth: CGFloat = 280
    @State private var previewIndex: Int?
    @FocusState private var railFocused: Bool

    private var selectedIndex: Int? {
        controller.turns.firstIndex { $0.messageID == controller.selectedMessageID }
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = ConversationRailGeometry(count: controller.turns.count, height: proxy.size.height)
            Canvas { context, size in
                for mark in geometry.marks(selectedIndex: selectedIndex) {
                    let width: CGFloat = mark.isSelected ? 14 : (mark.indices.count > 1 ? 10 : 7)
                    let rect = CGRect(x: (size.width - width) / 2, y: mark.y - 1, width: width, height: 2)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(mark.isSelected ? Theme.accent : Theme.textTertiary))
                }
                if let index = previewIndex, controller.turns.indices.contains(index) {
                    context.fill(Path(ellipseIn: CGRect(x: 9, y: geometry.position(of: index) - 3, width: 6, height: 6)), with: .color(Theme.accent))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): previewIndex = geometry.index(at: point.y)
                case .ended: if !railFocused { previewIndex = nil }
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                if let index = geometry.index(at: value.location.y), controller.turns.indices.contains(index) {
                    controller.open(turnID: controller.turns[index].id)
                }
            })
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
            .accessibilityHint("Use arrow keys to preview a turn and Return to open it. All turns are available in History.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: navigate(1)
                case .decrement: navigate(-1)
                @unknown default: break
                }
            }
            .accessibilityAction(named: Text("Open turn")) { openPreview() }
            .accessibilityIdentifier("history.timeline")
            .overlay(alignment: .topLeading) {
                if let index = previewIndex, controller.turns.indices.contains(index), previewWidth >= 100 {
                    let turn = controller.turns[index]
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Turn \(turn.ordinal)").font(.system(size: 11, weight: .semibold))
                        if let timestamp = turn.timestamp {
                            Text(timestamp).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                        }
                        Text(verbatim: String(turn.preview.prefix(160)))
                            .font(.system(size: 12)).lineLimit(5)
                    }
                    .foregroundStyle(Theme.text)
                    .padding(10)
                    .frame(width: previewWidth, alignment: .leading)
                    .background(Theme.contentBackground, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.sidebarBorder))
                    .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                    .offset(x: 28, y: max(0, min(geometry.position(of: index) - 24, proxy.size.height - 160)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
        .frame(width: 24)
        .onChange(of: controller.turns.count) { _, count in
            if let index = previewIndex, index >= count { previewIndex = count > 0 ? count - 1 : nil }
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
    private func openPreview() {
        if let index = previewIndex ?? selectedIndex ?? controller.turns.indices.last, controller.turns.indices.contains(index) {
            controller.open(turnID: controller.turns[index].id)
        }
    }
}
