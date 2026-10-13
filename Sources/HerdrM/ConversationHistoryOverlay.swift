import SwiftUI

/// Only the rail, entry button and visible drawer receive pointer events.
/// The terminal beneath keeps its original frame and retained surface identity.
struct ConversationHistoryOverlay: View {
    @ObservedObject var controller: ConversationHistoryController
    var onClose: (() -> Void)? = nil
    var onJump: ((String) -> Void)? = nil
    var canReturnToLive = false
    var onReturnToLive: (() -> Void)? = nil

    var body: some View {
        ConversationOverlayContent(controller: controller, onJump: onJump, canReturnToLive: canReturnToLive, onReturnToLive: onReturnToLive)
            .onChange(of: controller.isPresented) { wasPresented, isPresented in
                if wasPresented && !isPresented { onClose?() }
            }
    }
}

private struct ConversationOverlayContent: View {
    @ObservedObject var controller: ConversationHistoryController
    var onJump: ((String) -> Void)?
    var canReturnToLive: Bool
    var onReturnToLive: (() -> Void)?
    @State private var noticeDismissed = false
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 0) {
                    VStack(spacing: 6) {
                        ConversationTimelineRail(controller: controller, previewWidth: min(320, max(0, geometry.size.width - 76)), onJump: onJump)
                        ProgressView().controlSize(.mini).frame(height: 18)
                            .opacity(controller.isJumping ? 1 : 0)
                            .allowsHitTesting(false).accessibilityHidden(!controller.isJumping)
                        Button { onReturnToLive?() } label: { Image(systemName: "arrow.down.to.line") }
                            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                            .disabled(!canReturnToLive).opacity(canReturnToLive ? 1 : 0.25)
                            .help("Return to live terminal")
                            .accessibilityLabel("Return to live terminal")
                            .accessibilityIdentifier("history.returnToLive")
                        Button { controller.open() } label: { Image(systemName: "text.bubble") }
                            .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                            .keyboardShortcut("h", modifiers: [.command, .shift])
                            .help("Read full conversation (⇧⌘H)")
                            .accessibilityLabel("Read full conversation")
                            .accessibilityIdentifier("history.open")
                    }
                    .frame(width: 36).padding(.vertical, 12)
                    Spacer(minLength: 0)
                }
                if controller.isPresented {
                    ConversationHistoryDrawer(controller: controller)
                        .frame(width: min(460, max(0, geometry.size.width - 24)), height: geometry.size.height)
                        .shadow(color: .black.opacity(0.18), radius: 12, x: -3)
                }
                if let notice = controller.jumpNotice, !noticeDismissed {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Terminal jump unavailable").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Button { noticeDismissed = true } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).accessibilityLabel("Dismiss notice")
                        }
                        Text(LocalizedStringKey(notice.message)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(10).frame(width: min(320, max(0, geometry.size.width - 76)), alignment: .leading)
                    .background(Theme.historyPreviewBackground, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.sidebarBorder))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, 40).padding(.bottom, 40)
                    .accessibilityIdentifier("history.jumpNotice")
                }
            }
            .onChange(of: controller.jumpNotice?.message) { _, _ in noticeDismissed = false }
        }
    }
}
