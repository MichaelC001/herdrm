import SwiftUI

/// Only the rail, navigation controls and visible drawer receive pointer events.
/// The rail uses a reserved leading column; opening the drawer keeps the retained
/// terminal's frame and surface identity stable.
struct ConversationHistoryOverlay: View {
    static let gutterWidth: CGFloat = 36
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
            let railViewport = ConversationRailViewport(height: geometry.size.height)
            ZStack(alignment: .topTrailing) {
                JumpCover(active: controller.isJumping)
                HStack(spacing: 0) {
                    VStack(spacing: 6) {
                        ConversationTimelineRail(controller: controller, previewWidth: min(320, max(0, geometry.size.width - 76)), onJump: onJump)
                            .frame(height: railViewport.height)
                        ProgressView().controlSize(.mini).frame(height: 18)
                            .opacity(controller.isJumping ? 1 : 0)
                            .allowsHitTesting(false).accessibilityHidden(!controller.isJumping)
                        Button { onReturnToLive?() } label: { Image(systemName: "arrow.down.to.line") }
                            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                            .disabled(!canReturnToLive).opacity(canReturnToLive ? 1 : 0.25)
                            .help("Return to live terminal")
                            .accessibilityLabel("Return to live terminal")
                            .accessibilityIdentifier("history.returnToLive")
                    }
                    .frame(width: ConversationHistoryOverlay.gutterWidth)
                    .padding(.top, railViewport.topInset)
                    .padding(.bottom, 12)
                    .frame(maxHeight: .infinity, alignment: .top)
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

/// Hides the terminal while a jump pages the agent's own history (fullscreen Claude
/// redraws every page), so only the landing shows. It fades in late enough that a
/// jump within herdr's scrollback, which lands at once, never flashes it.
private struct JumpCover: View {
    let active: Bool
    var body: some View {
        ZStack {
            Theme.terminalBackground.opacity(0.94)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finding the prompt…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
        .opacity(active ? 1 : 0)
        .animation(active ? .easeIn(duration: 0.12).delay(0.15) : .easeOut(duration: 0.1), value: active)
        .allowsHitTesting(false)
        .accessibilityHidden(!active)
        .accessibilityIdentifier("history.jumpCover")
    }
}
