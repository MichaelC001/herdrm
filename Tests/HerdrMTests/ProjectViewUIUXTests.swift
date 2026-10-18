import AppKit
import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

/// Hosts the real `ProjectView` with an injected snapshot and reads it back the way VoiceOver does.
@MainActor
final class ProjectViewUIUXTests: XCTestCase {
    private let devbox = Device(name: "devbox", kind: .ssh(target: "dev@devbox"))
    private let root = "/home/dev/acme-app"

    private func server(
        _ signature: String, framework: String, port: Int, role: ServiceRole = .frontend, hot: Bool = true,
        publicBind: Bool = false, hidden: Bool = false
    ) -> DevServer {
        DevServer(
            signature: signature, role: role, framework: framework, bind: publicBind ? "0.0.0.0" : "127.0.0.1",
            port: port, isPublicBind: publicBind, pids: [4101], ownerPID: 4101, cwdRelative: "frontend",
            unit: hot ? "acme-dev-fe.service" : nil, logPath: hot ? "/tmp/acme-frontend-3100.log" : nil,
            hotReload: hot,
            urls: [ProjectURL(label: "http://localhost:\(port)", url: "http://localhost:\(port)", source: .detected, loopbackOnHost: !publicBind)],
            isHidden: hidden)
    }

    private func container(
        _ id: String, name: String, service: String?, state: String = "running", health: String? = "healthy",
        image: String = "nginx:1.27",
        ports: [PublishedPort] = [PublishedPort(hostIP: "0.0.0.0", hostPort: 8080, containerPort: 80, proto: "tcp")],
        statusText: String = "Up 2 hours"
    ) -> ContainerRow {
        ContainerRow(
            id: id, name: name, image: image, service: service, state: state, statusText: statusText,
            health: health, ports: ports, urls: [])
    }

    private func snapshot(
        extraServers: [DevServer] = [], compose: [ComposeGroup]? = nil, attached: [ContainerRow] = [],
        suggested: [ContainerRow] = []
    ) -> ProjectSnapshot {
        let web = container("c1", name: "acme-web-1", service: "web")
        let groups = compose ?? [
            ComposeGroup(name: "acme", workingDir: root, configFiles: ["\(root)/compose.yaml"], match: .name, running: 1, total: 1, containers: [web])
        ]
        return ProjectSnapshot(
            identity: ProjectIdentity(deviceID: devbox.id, root: root, worktreeRoots: [root]),
            probedAt: Date(), partial: false,
            host: HostHealth(
                hostname: "devbox", cpuCount: 8, load1: 0.7, memUsedFraction: 0.42,
                dockerServerVersion: "27.3.1", hotLanes: LaneCount(up: 1, total: 1), dockerLanes: LaneCount(up: 1, total: 1)),
            devServers: [server("next-server@frontend", framework: "Next.js", port: 3100)] + extraServers,
            otherListeners: [server("python3@scratch", framework: "python3", port: 9000, role: .other, hot: false)],
            compose: groups,
            otherCompose: [], attachedContainers: attached, suggestedContainers: suggested,
            vms: [VMRow(provider: .lima, vmID: "acme-vm", name: "acme-vm", state: "running", ip: "192.168.5.15", match: .declared)],
            otherVMs: [], files: ["compose.yaml"], envEntries: [], warnings: [], staleOverrides: [])
    }

    private func host(_ model: AppModel, width: CGFloat = 760) -> (NSWindow, NSHostingView<AnyView>) {
        let view = NSHostingView(rootView: AnyView(ProjectView(model: model, polling: false).frame(width: width, height: 900)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "ProjectViewHarness \(UUID().uuidString)"
        window.contentView = view
        window.orderFrontRegardless()
        return (window, view)
    }

    private func settle(_ seconds: TimeInterval = 0.4) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            NSApp?.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
        }
    }

    private func elements(in window: NSWindow) -> [AccessibilityProbe.Element] {
        AccessibilityProbe.elements(in: window)
    }

    private func texts(_ elements: [AccessibilityProbe.Element]) -> Set<String> {
        Set(elements.flatMap { [$0.value, $0.name].compactMap { $0 } })
    }

    private func element(_ elements: [AccessibilityProbe.Element], id: String) -> AccessibilityProbe.Element? {
        elements.first { $0.identifier == id }
    }

    private func model(entry: ProjectInspectorModel.Entry?, device: Device? = nil) throws -> (AppModel, SpaceRef) {
        let device = device ?? devbox
        let model = AppModel()
        model.devices = [device]
        var state = DeviceSessionState()
        state.workspaces = [try JSONDecoder().decode(
            WorkspaceInfo.self,
            from: JSONSerialization.data(withJSONObject: ["workspace_id": "w1", "number": 1, "label": "acme"]))]
        model.sessions[device.id] = state
        let space = SpaceRef(deviceID: device.id, workspaceID: "w1")
        model.selectedSpace = space
        model.detailMode = .project
        if let entry {
            model.projects._setEntryForTesting(space: space, key: "\(device.id.uuidString):\(root)", entry: entry)
        }
        return (model, space)
    }

    func testRendersSectionsBadgesAndRefresh() throws {
        let entry = ProjectInspectorModel.Entry(snapshot: snapshot(), state: .live, lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, _) = try model(entry: entry)
        let (window, _) = host(model)
        defer { window.close() }
        settle()

        let elements = AccessibilityProbe.elements(in: window)
        let texts = Set(elements.flatMap { [$0.value, $0.name].compactMap { $0 } })
        for expected in ["Hot reload", "Docker", "Hosts & VMs", "Other listeners", "loopback only", "matched by name"] {
            XCTAssertTrue(texts.contains(expected), "missing \(expected) in \(texts.sorted())")
        }
        let refresh = try XCTUnwrap(elements.first { $0.role == "AXButton" && $0.name == "Refresh" }, "no Refresh button")
        XCTAssertEqual(refresh.isEnabled, true)
    }

    func testNoSpaceShowsEmptyState() throws {
        let (model, _) = try model(entry: nil)
        model.selectedSpace = nil
        let (window, _) = host(model)
        defer { window.close() }
        settle()
        let texts = texts(elements(in: window))
        XCTAssertTrue(texts.contains("No Space selected"), "\(texts.sorted())")
        XCTAssertFalse(texts.contains("Hot reload"))
    }

    func testFailedProbeKeepsStaleSnapshotUnderBanner() throws {
        let entry = ProjectInspectorModel.Entry(snapshot: snapshot(), state: .failed("ssh timed out"), lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, _) = try model(entry: entry)
        let (window, _) = host(model)
        defer { window.close() }
        settle()
        let texts = texts(elements(in: window))
        XCTAssertTrue(texts.contains("ssh timed out"), "\(texts.sorted())")
        XCTAssertTrue(texts.contains("Hot reload"), "stale snapshot must stay visible")
    }

    func testHiddenRowsLeaveTheListsAndSitInACollapsedDisclosure() throws {
        var snap = snapshot()
        var hiddenDev = server("vite@web", framework: "vite-hidden-fw", port: 5173)
        hiddenDev.isHidden = true
        var hiddenOther = server("redis@", framework: "redis-hidden-fw", port: 6379, role: .other, hot: false)
        hiddenOther.isHidden = true
        snap.devServers.append(hiddenDev)
        snap.otherListeners.append(hiddenOther)
        let entry = ProjectInspectorModel.Entry(snapshot: snap, state: .live, lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, _) = try model(entry: entry)
        let (window, _) = host(model)
        defer { window.close() }
        settle()

        let texts = texts(elements(in: window))
        XCTAssertTrue(texts.contains("Hidden (2)"), "no Hidden disclosure in \(texts.sorted())")
        XCTAssertFalse(texts.contains("vite-hidden-fw"), "hidden dev server is still listed")
        XCTAssertFalse(texts.contains("redis-hidden-fw"), "hidden listener is still listed")
        XCTAssertTrue(texts.contains("Next.js"), "visible server must stay")
        XCTAssertTrue(texts.contains("Other listeners"), "the visible listener keeps its section")
    }

    func testSummaryStripCounts() throws {
        let hidden = server("vite@web", framework: "vite-hidden-fw", port: 5173, hidden: true)
        let entry = ProjectInspectorModel.Entry(snapshot: snapshot(extraServers: [hidden]), state: .live, lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, _) = try model(entry: entry)
        let (window, _) = host(model)
        defer { window.close() }
        settle()
        let all = elements(in: window)
        let strip = try XCTUnwrap(element(all, id: "project.summary"), "no summary strip")
        let label = try XCTUnwrap(strip.name)
        for part in ["Dev servers 1", "Containers 1/1", "VMs 1", "Hosts 1"] {
            XCTAssertTrue(label.contains(part), "\(part) missing in \(label)")
        }
        XCTAssertFalse(label.contains("2"), "hidden server leaked into the count: \(label)")
    }

    func testDevServerRowShowsTagsAndMoreMenu() throws {
        let entry = ProjectInspectorModel.Entry(snapshot: snapshot(), state: .live, lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, _) = try model(entry: entry)
        let (window, _) = host(model)
        defer { window.close() }
        settle()
        let all = elements(in: window)
        let shown = texts(all)
        for expected in ["hot reload", "acme-dev-fe.service", "acme-frontend-3100.log", "Frontend"] {
            XCTAssertTrue(shown.contains(expected), "missing \(expected) in \(shown.sorted())")
        }
        XCTAssertNotNil(all.first { $0.name == "More" }, "no More menu on the dev server row")
        XCTAssertNil(all.first { $0.role == "AXButton" && $0.name == "Hide" }, "Hide must live in the menu, not inline")
    }
}
