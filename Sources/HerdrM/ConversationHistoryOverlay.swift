import SwiftUI

/// Only the rail, entry button and visible drawer receive pointer events.
/// The terminal beneath keeps its original frame and retained surface identity.
struct ConversationHistoryOverlay: View {
    @ObservedObject var controller: ConversationHistoryController
    var onClose: (() -> Void)? = nil

    var body: some View {
        ConversationOverlayContent(controller: controller)
            .onChange(of: controller.isPresented) { wasPresented, isPresented in
                if wasPresented && !isPresented { onClose?() }
            }
    }
}

private struct ConversationOverlayContent: View {
    @ObservedObject var controller: ConversationHistoryController
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 0) {
                    ConversationTimelineRail(controller: controller, previewWidth: min(280, max(0, geometry.size.width - 60)))
                        .padding(.top, 36)
                    Spacer(minLength: 0)
                }
                if controller.isPresented {
                    ConversationHistoryDrawer(controller: controller)
                        .frame(width: min(460, max(0, geometry.size.width - 24)), height: geometry.size.height)
                        .shadow(color: .black.opacity(0.18), radius: 12, x: -3)
                } else {
                    Button { controller.open() } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 11))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Theme.contentBackground, in: Capsule())
                            .overlay(Capsule().stroke(Theme.sidebarBorder))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .help("Read Claude conversation history")
                    .accessibilityLabel("History")
                    .accessibilityIdentifier("history.open")
                    .padding(8)
                }
            }
        }
    }
}
