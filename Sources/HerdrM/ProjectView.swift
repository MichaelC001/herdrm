import SwiftUI

/// The per-Space "Project" pane that covers the terminal in `DetailMode.project`.
struct ProjectView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ContentUnavailableView(
            "Project",
            systemImage: "shippingbox",
            description: Text("Coming in the next tasks")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground)
    }
}
