import AppKit
import HerdrKit
import SwiftUI

// Row views of the Project pane. They are plain value views: every action is a closure the
// pane wires to `ProjectInspectorModel`, so the rows stay small.

enum ProjectRowMetrics {
    static let rowHeight: CGFloat = 28
    static let textSize: CGFloat = 12.5
}

/// Small rounded tag next to a row title ("loopback only", "matched by name", ...).
struct ProjectTag: View {
    let text: LocalizedStringKey
    var tint: Color = Theme.textSecondary

    init(_ text: LocalizedStringKey, tint: Color = Theme.textSecondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
            .lineLimit(1)
            .fixedSize()
    }
}

/// A tag that shows a verbatim string (a unit or log file name), not a catalog key.
struct ProjectVerbatimTag: View {
    let text: String
    let systemImage: String
    var help: String?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 8.5))
            Text(verbatim: text).font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background(Theme.itemWash, in: RoundedRectangle(cornerRadius: 4))
        .lineLimit(1)
        .help(help ?? text)
    }
}

struct ProjectIconButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.textSecondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
    }
}

// MARK: - URLs

enum ProjectURLActions {
    static func open(_ url: ProjectURL) {
        guard let target = URL(string: url.url) else { return }
        NSWorkspace.shared.open(target)
    }

    static func copy(_ url: ProjectURL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.url, forType: .string)
    }
}

/// The URL chips of one service: open, copy, and (for dev servers) set an override.
struct ProjectURLButtons: View {
    let urls: [ProjectURL]
    /// Non-nil adds a "Set URL…" popover that edits this service's override.
    var onSetURL: ((String?) -> Void)?
    var currentOverride: String?
    @State private var editing = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                Button { ProjectURLActions.open(url) } label: {
                    Text(verbatim: url.label)
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.link)
                .help(url.loopbackOnHost ? "Only reachable from the host itself" : "Open this URL")
                ProjectIconButton(systemImage: "doc.on.doc", label: "Copy URL") { ProjectURLActions.copy(url) }
            }
            if let onSetURL {
                ProjectIconButton(systemImage: "link.badge.plus", label: "Set URL…") { editing = true }
                    .popover(isPresented: $editing, arrowEdge: .bottom) {
                        URLOverridePopover(
                            initial: currentOverride ?? "",
                            onSave: { value in
                                onSetURL(value)
                                editing = false
                            },
                            onCancel: { editing = false })
                    }
            }
        }
    }
}

/// Text field for a URL override. Saving an empty field clears the override.
struct URLOverridePopover: View {
    @State private var text: String
    let onSave: (String?) -> Void
    let onCancel: () -> Void

    init(initial: String, onSave: @escaping (String?) -> Void, onCancel: @escaping () -> Void) {
        _text = State(initialValue: initial)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetSectionLabel("URL override")
            TextField("https://app.example.test", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(save)
            Text("Leave empty to go back to the detected URL.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(trimmed.isEmpty ? nil : trimmed)
    }
}

// MARK: - Dev servers

struct DevServerRow: View {
    let server: DevServer
    let overrideURL: String?
    /// Nil hides the "Set URL…" control (listeners that are not part of the project).
    let onSetURL: ((String?) -> Void)?
    let onToggleHidden: () -> Void

    private var isLoopback: Bool {
        ["127.0.0.1", "::1", "[::1]", "localhost"].contains(server.bind)
    }

    private var roleName: LocalizedStringKey {
        switch server.role {
        case .frontend: "Frontend"
        case .backend: "Backend"
        case .tooling: "Tooling"
        case .other: "Other"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: server.hotReload ? Theme.success : Theme.textTertiary)
            Text(verbatim: server.framework)
                .font(.system(size: ProjectRowMetrics.textSize, weight: .medium))
                .foregroundStyle(server.isHidden ? Theme.textTertiary : Theme.text)
            Text(roleName)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
            Text(verbatim: "\(server.bind):\(server.port)")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            if isLoopback {
                ProjectTag("loopback only")
            } else if server.isPublicBind {
                ProjectTag("public", tint: Theme.warning)
            }
            if let unit = server.unit {
                ProjectVerbatimTag(text: unit, systemImage: "gearshape")
            }
            if let log = server.logPath {
                ProjectVerbatimTag(text: (log as NSString).lastPathComponent, systemImage: "doc.text", help: log)
            }
            Spacer(minLength: 8)
            ProjectURLButtons(urls: server.urls, onSetURL: onSetURL, currentOverride: overrideURL)
            ProjectIconButton(
                systemImage: server.isHidden ? "eye" : "eye.slash",
                label: server.isHidden ? "Unhide" : "Hide", action: onToggleHidden)
        }
        .frame(minHeight: ProjectRowMetrics.rowHeight)
    }
}

// MARK: - Docker

struct ContainerRowView: View {
    let container: ContainerRow
    /// Attach and Dismiss for a suggested container; nil for rows that are already part of the project.
    var onAttach: (() -> Void)?
    var onDismiss: (() -> Void)?

    private var stateColor: Color {
        if container.health == "unhealthy" { return Theme.danger }
        return container.state == "running" ? Theme.success : Theme.textTertiary
    }

    private var portsText: String {
        container.ports.map { "\($0.hostPort)→\($0.containerPort)" }.joined(separator: ", ")
    }

    private var healthTag: (key: LocalizedStringKey, tint: Color)? {
        switch container.health {
        case "healthy": ("healthy", Theme.success)
        case "unhealthy": ("unhealthy", Theme.danger)
        case "starting": ("starting", Theme.warning)
        default: nil
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: stateColor)
            Text(verbatim: container.service ?? container.name)
                .font(.system(size: ProjectRowMetrics.textSize))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(verbatim: container.statusText)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            if let healthTag { ProjectTag(healthTag.key, tint: healthTag.tint) }
            if !portsText.isEmpty {
                Text(verbatim: portsText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            ProjectURLButtons(urls: container.urls)
            if let onAttach { Button("Attach", action: onAttach).controlSize(.small) }
            if let onDismiss { Button("Dismiss", action: onDismiss).controlSize(.small) }
        }
        .frame(minHeight: ProjectRowMetrics.rowHeight)
        .help(container.image)
    }
}

struct ComposeGroupRow<Containers: View>: View {
    let group: ComposeGroup
    /// "Detach" for a group listed under the project, "Attach" for an unrelated one.
    let isAttached: Bool
    let onToggle: () -> Void
    @ViewBuilder let containers: () -> Containers

    private var matchBadge: LocalizedStringKey? {
        switch group.match {
        case .path: "matched by path"
        case .name: "matched by name"
        case .attached: "attached"
        case nil: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Text(verbatim: group.name)
                    .font(.system(size: ProjectRowMetrics.textSize, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text(verbatim: "\(group.running)/\(group.total)")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(group.running == group.total && group.total > 0 ? Theme.success : Theme.textSecondary)
                if let matchBadge { ProjectTag(matchBadge, tint: Theme.accent) }
                Spacer(minLength: 8)
                Button(isAttached ? "Detach" : "Attach", action: onToggle).controlSize(.small)
            }
            .frame(minHeight: ProjectRowMetrics.rowHeight)
            containers().padding(.leading, 16)
        }
    }
}

// MARK: - Host and VMs

struct HostHealthRow: View {
    let host: HostHealth

    private var loadText: String? {
        guard let load = host.load1 else { return nil }
        let value = load.formatted(.number.precision(.fractionLength(2)))
        return host.cpuCount.map { "\(value) / \($0)" } ?? value
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            Text(verbatim: host.hostname ?? "—")
                .font(.system(size: ProjectRowMetrics.textSize, weight: .medium))
                .foregroundStyle(Theme.text)
            if let loadText { metric("Load", loadText) }
            if let mem = host.memUsedFraction { metric("Memory", mem.formatted(.percent.precision(.fractionLength(0)))) }
            if let docker = host.dockerServerVersion { metric("Docker", docker) }
            if host.hotLanes.total > 0 { metric("Hot lanes", "\(host.hotLanes.up)/\(host.hotLanes.total)") }
            if host.dockerLanes.total > 0 { metric("Docker lanes", "\(host.dockerLanes.up)/\(host.dockerLanes.total)") }
            Spacer(minLength: 0)
        }
        .frame(minHeight: ProjectRowMetrics.rowHeight)
    }

    private func metric(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            Text(verbatim: value).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
        }
    }
}

struct VMRowView: View {
    let vm: VMRow
    var onAttach: (() -> Void)?
    var onDetach: (() -> Void)?

    private var matchBadge: LocalizedStringKey? {
        switch vm.match {
        case .attached: "attached"
        case .declared: "declared"
        case .suggested: "suggested"
        case nil: nil
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: vm.state.lowercased() == "running" ? Theme.success : Theme.textTertiary)
            Text(verbatim: vm.name)
                .font(.system(size: ProjectRowMetrics.textSize))
                .foregroundStyle(Theme.text)
            Text(verbatim: vm.provider.rawValue)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
            Text(verbatim: vm.state)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
            if let ip = vm.ip {
                Text(verbatim: ip).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
            }
            if let matchBadge { ProjectTag(matchBadge, tint: Theme.accent) }
            Spacer(minLength: 8)
            if let onAttach { Button("Attach", action: onAttach).controlSize(.small) }
            if let onDetach { Button("Detach", action: onDetach).controlSize(.small) }
        }
        .frame(minHeight: ProjectRowMetrics.rowHeight)
    }
}
