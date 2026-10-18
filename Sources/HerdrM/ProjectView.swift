import HerdrKit
import SwiftUI

/// What the polling task depends on; a change restarts the loop (and so probes at once).
struct ProjectTaskKey: Equatable {
    var space: SpaceRef?
    var context: ProjectContext?
    var active: Bool
}

/// The per-Space "Project" pane that covers the terminal in `DetailMode.project`.
/// Read-only apart from the small override controls: URLs, hiding, attaching and the root.
struct ProjectView: View {
    @ObservedObject var model: AppModel
    /// Off in tests that inject a snapshot and must not probe.
    var polling = true
    @State private var windowVisible = false

    private var taskKey: ProjectTaskKey {
        let space = model.selectedSpace
        return ProjectTaskKey(
            space: space, context: space.flatMap { model.projectContext(for: $0) },
            active: polling && model.detailMode == .project && windowVisible)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.contentBackground)
            .background(WindowVisibilityReader(isVisible: $windowVisible))
            .task(id: taskKey) {
                let key = taskKey
                guard key.active, let space = key.space, let context = key.context else { return }
                await model.projects.run(space: space, context: context)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let space = model.selectedSpace {
            if let context = model.projectContext(for: space) {
                ProjectPanel(model: model, projects: model.projects, space: space, context: context)
            } else {
                ContentUnavailableView(
                    "Space not available", systemImage: "shippingbox",
                    description: Text("This Space is not reachable right now."))
            }
        } else {
            ContentUnavailableView(
                "No Space selected", systemImage: "shippingbox",
                description: Text("Select a Space to see its project."))
        }
    }
}

/// The pane for one Space: header, state handling and the sections.
private struct ProjectPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var projects: ProjectInspectorModel
    let space: SpaceRef
    let context: ProjectContext

    @State private var expanded: Set<String> = ["hot", "docker", "hosts", "links", "files"]
    @State private var refreshing = false
    @State private var changingRoot = false
    @State private var rootText = ""

    private var entry: ProjectInspectorModel.Entry? { projects.entry(for: space) }
    private var snapshot: ProjectSnapshot? { entry?.snapshot }
    private var isProbing: Bool { refreshing || entry?.state == .probing }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if !ProjectProbeScript.isSupported(context.device) {
                ContentUnavailableView(
                    "Project details unavailable", systemImage: "shippingbox",
                    description: Text("Project details need a shell, so tailcat and Windows devices are not supported."))
            } else if let snapshot {
                loaded(snapshot)
            } else {
                empty
            }
        }
        .alert("Change project root", isPresented: $changingRoot) {
            TextField("Absolute path on \(context.device.name)", text: $rootText)
            Button("Change") { applyRoot(rootText) }
            Button("Use Automatic Root") { projects.setRoot(space: space, context: context, root: nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pin the folder this Space's project lives in.")
        }
    }

    // MARK: - States

    @ViewBuilder
    private var empty: some View {
        if case .failed(let message) = entry?.state {
            ContentUnavailableView {
                Label("No project found", systemImage: "shippingbox")
            } description: {
                Text(verbatim: message)
            } actions: {
                Button("Refresh", action: refresh)
                Button("Change root…", action: beginChangingRoot)
            }
        } else if context.cwds.isEmpty {
            ContentUnavailableView(
                "No panes yet", systemImage: "terminal",
                description: Text("Open a terminal or agent in this Space to find its project."))
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Inspecting project…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loaded(_ snapshot: ProjectSnapshot) -> some View {
        VStack(spacing: 0) {
            if case .failed(let message) = entry?.state { errorBanner(message) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    hotReloadSection(snapshot)
                    dockerSection(snapshot)
                    hostsSection(snapshot)
                    linksSection(snapshot)
                    filesSection(snapshot)
                    otherListenersSection(snapshot)
                    warnings(snapshot)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            Text(verbatim: message).foregroundStyle(Theme.text).lineLimit(2)
            Text("Showing the last result.").foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Theme.warning.opacity(0.12))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: snapshot?.identity.name ?? context.workspaceLabel)
                .font(.system(size: ProjectRowMetrics.textSize, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            DeviceChip(device: context.device)
            if let root = snapshot?.identity.root {
                Text(verbatim: (root as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if snapshot?.partial == true { ProjectTag("partial", tint: Theme.warning) }
            Spacer(minLength: 8)
            if let probed = entry?.lastProbe { updatedLabel(probed) }
            rootPicker
            Button(action: refresh) {
                if isProbing {
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.textSecondary)
            .disabled(isProbing)
            .help("Refresh")
            .accessibilityLabel("Refresh")
            optionsMenu
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    private func updatedLabel(_ date: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            let ago = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: max(timeline.date, date))
            Text("Updated \(ago)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
    }

    /// Other git roots the Space's panes sit in, when there are several to pick between.
    @ViewBuilder
    private var rootPicker: some View {
        let roots = candidateRoots
        if roots.count > 1 {
            Menu {
                ForEach(roots, id: \.self) { root in
                    Button {
                        projects.setRoot(space: space, context: context, root: root)
                    } label: {
                        if root == snapshot?.identity.root { Label(root, systemImage: "checkmark") } else { Text(verbatim: root) }
                    }
                }
            } label: {
                Image(systemName: "folder")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Switch project root")
            .accessibilityLabel("Project root")
        }
    }

    private var candidateRoots: [String] {
        var seen = Set<String>()
        return (entry?.rawProbe?.roots ?? []).compactMap(\.toplevel).filter { seen.insert($0).inserted }
    }

    private var optionsMenu: some View {
        Menu {
            Button("Change root…", action: beginChangingRoot)
            Menu("Link host…") {
                let hosts = model.devices.filter { $0.sshTarget != nil && $0.id != context.device.id }
                if hosts.isEmpty || snapshot == nil {
                    Text("No other SSH hosts")
                } else {
                    ForEach(hosts) { host in
                        Button(host.name) {
                            if let root = snapshot?.identity.root {
                                projects.linkDevice(space: space, device: host, root: root)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Reset overrides", role: .destructive) { projects.resetOverrides(space: space) }
                .disabled(snapshot == nil)
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Project options")
        .accessibilityLabel("Project options")
    }

    // MARK: - Actions

    private func refresh() {
        refreshing = true
        Task {
            _ = await projects.probe(space: space, context: context)
            refreshing = false
        }
    }

    private func beginChangingRoot() {
        rootText = snapshot?.identity.root ?? ""
        changingRoot = true
    }

    private func applyRoot(_ text: String) {
        var path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("~"), context.device.isLocal { path = (path as NSString).expandingTildeInPath }
        guard path.hasPrefix("/") else { return }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        projects.setRoot(space: space, context: context, root: path)
    }

    // MARK: - Sections

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func section<Content: View>(
        _ id: String, _ title: LocalizedStringKey, count: Int? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        let body = content()
        return DisclosureGroup(isExpanded: binding(id)) {
            VStack(alignment: .leading, spacing: 0) { body }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                SheetSectionLabel(title)
                if let count, count > 0 {
                    Text(verbatim: "\(count)").font(.system(size: 10.5)).foregroundStyle(Theme.textGhost)
                }
            }
        }
    }

    private func note(_ text: LocalizedStringKey, tint: Color = Theme.textTertiary) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(tint)
            .frame(minHeight: ProjectRowMetrics.rowHeight, alignment: .leading)
    }

    private func devServerRow(_ server: DevServer, canSetURL: Bool) -> some View {
        DevServerRow(
            server: server,
            overrideURL: server.urls.first { $0.source == .override }?.url,
            onSetURL: canSetURL
                ? { projects.setURLOverride(space: space, signature: server.signature, url: $0) } : nil,
            onToggleHidden: {
                projects.setHidden(space: space, signature: server.signature, hidden: !server.isHidden)
            })
    }

    private func hotReloadSection(_ snapshot: ProjectSnapshot) -> some View {
        section("hot", "Hot reload", count: snapshot.devServers.count) {
            if snapshot.devServers.isEmpty { note("No dev servers are running for this project.") }
            ForEach(snapshot.devServers) { devServerRow($0, canSetURL: true) }
            if !snapshot.staleOverrides.isEmpty {
                note("URL overrides without a running server: \(snapshot.staleOverrides.joined(separator: ", "))")
            }
        }
    }

    private func containerRow(_ container: ContainerRow, suggested: Bool = false) -> some View {
        ContainerRowView(
            container: container,
            onAttach: suggested ? { projects.attachContainer(space: space, name: container.name) } : nil,
            onDismiss: suggested ? { projects.dismissSuggestion(space: space, name: container.name) } : nil)
    }

    private func composeRow(_ group: ComposeGroup, attached: Bool) -> some View {
        ComposeGroupRow(
            group: group, isAttached: attached,
            onToggle: {
                if attached {
                    projects.detachCompose(space: space, name: group.name)
                } else {
                    projects.attachCompose(space: space, name: group.name)
                }
            },
            containers: {
                ForEach(group.containers) { containerRow($0) }
            })
    }

    private func dockerSection(_ snapshot: ProjectSnapshot) -> some View {
        let isEmpty = snapshot.compose.isEmpty && snapshot.attachedContainers.isEmpty
            && snapshot.suggestedContainers.isEmpty
        return section("docker", "Docker", count: snapshot.compose.count + snapshot.attachedContainers.count) {
            if let error = snapshot.host.dockerError {
                note("Docker is not reachable: \(error)", tint: Theme.warning)
            } else if isEmpty {
                note("No Docker containers belong to this project.")
            }
            ForEach(snapshot.compose) { composeRow($0, attached: true) }
            ForEach(snapshot.attachedContainers) { containerRow($0) }
            if !snapshot.suggestedContainers.isEmpty {
                note("Suggested containers").padding(.top, 6)
                ForEach(snapshot.suggestedContainers) { containerRow($0, suggested: true) }
            }
            if !snapshot.otherCompose.isEmpty {
                DisclosureGroup(isExpanded: binding("otherCompose")) {
                    ForEach(snapshot.otherCompose) { composeRow($0, attached: false) }
                } label: {
                    SheetSectionLabel("Other Compose projects")
                }
                .padding(.top, 6)
            }
        }
    }

    private func hostsSection(_ snapshot: ProjectSnapshot) -> some View {
        section("hosts", "Hosts & VMs", count: snapshot.vms.count) {
            HostHealthRow(host: snapshot.host)
            ForEach(snapshot.vms) { vm in
                VMRowView(
                    vm: vm,
                    onAttach: vm.match == .suggested ? { projects.attachVM(space: space, vm: vm) } : nil,
                    onDetach: vm.match == .attached ? { projects.detachVM(space: space, id: vm.id) } : nil)
            }
            if !snapshot.otherVMs.isEmpty {
                Menu("Attach VM…") {
                    ForEach(snapshot.otherVMs) { vm in
                        Button("\(vm.name) (\(vm.provider.rawValue))") { projects.attachVM(space: space, vm: vm) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .frame(minHeight: ProjectRowMetrics.rowHeight)
            }
        }
    }

    private func linksSection(_ snapshot: ProjectSnapshot) -> some View {
        let all = snapshot.devServers.flatMap(\.urls)
            + (snapshot.compose.flatMap(\.containers) + snapshot.attachedContainers).flatMap(\.urls)
        var seen = Set<String>()
        let urls = all.filter { seen.insert($0.url).inserted }
        return Group {
            if !urls.isEmpty {
                section("links", "Links", count: urls.count) {
                    ForEach(urls, id: \.url) { url in
                        HStack(spacing: 8) {
                            ProjectURLButtons(urls: [url])
                            Spacer()
                        }
                        .frame(minHeight: ProjectRowMetrics.rowHeight)
                    }
                }
            }
        }
    }

    private func filesSection(_ snapshot: ProjectSnapshot) -> some View {
        // Env values can be secrets: only the variable names are shown, grouped by file.
        let byFile = Dictionary(grouping: snapshot.envEntries, by: \.file)
        return Group {
            if !snapshot.files.isEmpty || !byFile.isEmpty {
                section("files", "Project files", count: snapshot.files.count) {
                    ForEach(snapshot.files, id: \.self) { file in
                        Text(verbatim: file)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(minHeight: ProjectRowMetrics.rowHeight, alignment: .leading)
                    }
                    ForEach(byFile.keys.sorted(), id: \.self) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: file)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                            Text(verbatim: (byFile[file] ?? []).map(\.key).joined(separator: ", "))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func otherListenersSection(_ snapshot: ProjectSnapshot) -> some View {
        Group {
            if !snapshot.otherListeners.isEmpty {
                section("other", "Other listeners", count: snapshot.otherListeners.count) {
                    ForEach(snapshot.otherListeners) { devServerRow($0, canSetURL: false) }
                }
            }
        }
    }

    @ViewBuilder
    private func warnings(_ snapshot: ProjectSnapshot) -> some View {
        if !snapshot.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(snapshot.warnings, id: \.self) { warning in
                    Text(verbatim: warning).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }
}
