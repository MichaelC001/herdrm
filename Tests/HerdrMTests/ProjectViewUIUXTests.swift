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
        publicBind: Bool = false
    ) -> DevServer {
        DevServer(
            signature: signature, role: role, framework: framework, bind: publicBind ? "0.0.0.0" : "127.0.0.1",
            port: port, isPublicBind: publicBind, pids: [4101], ownerPID: 4101, cwdRelative: "frontend",
            unit: hot ? "acme-dev-fe.service" : nil, logPath: hot ? "/tmp/acme-frontend-3100.log" : nil,
            hotReload: hot,
            urls: [ProjectURL(label: "http://localhost:\(port)", url: "http://localhost:\(port)", source: .detected, loopbackOnHost: !publicBind)],
            isHidden: false)
    }

    private func snapshot() -> ProjectSnapshot {
        let web = ContainerRow(
            id: "c1", name: "acme-web-1", image: "nginx:1.27", service: "web", state: "running",
            statusText: "Up 2 hours", health: "healthy",
            ports: [PublishedPort(hostIP: "0.0.0.0", hostPort: 8080, containerPort: 80, proto: "tcp")], urls: [])
        return ProjectSnapshot(
            identity: ProjectIdentity(deviceID: devbox.id, root: root, worktreeRoots: [root]),
            probedAt: Date(), partial: false,
            host: HostHealth(
                hostname: "devbox", cpuCount: 8, load1: 0.7, memUsedFraction: 0.42,
                dockerServerVersion: "27.3.1", hotLanes: LaneCount(up: 1, total: 1), dockerLanes: LaneCount(up: 1, total: 1)),
            devServers: [server("next-server@frontend", framework: "Next.js", port: 3100)],
            otherListeners: [server("python3@scratch", framework: "python3", port: 9000, role: .other, hot: false)],
            compose: [ComposeGroup(name: "acme", workingDir: root, configFiles: ["\(root)/compose.yaml"], match: .name, running: 1, total: 1, containers: [web])],
            otherCompose: [], attachedContainers: [], suggestedContainers: [],
            vms: [VMRow(provider: .lima, vmID: "acme-vm", name: "acme-vm", state: "running", ip: "192.168.5.15", match: .declared)],
            otherVMs: [], files: ["compose.yaml"], envEntries: [], warnings: [], staleOverrides: [])
    }

    private func host(_ model: AppModel) -> (NSWindow, NSHostingView<AnyView>) {
        let view = NSHostingView(rootView: AnyView(ProjectView(model: model, polling: false).frame(width: 760, height: 900)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
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

    private func model(entry: ProjectInspectorModel.Entry?) throws -> (AppModel, SpaceRef) {
        let model = AppModel()
        model.devices = [devbox]
        var state = DeviceSessionState()
        state.workspaces = [try JSONDecoder().decode(
            WorkspaceInfo.self,
            from: JSONSerialization.data(withJSONObject: ["workspace_id": "w1", "number": 1, "label": "acme"]))]
        model.sessions[devbox.id] = state
        let space = SpaceRef(deviceID: devbox.id, workspaceID: "w1")
        model.selectedSpace = space
        model.detailMode = .project
        if let entry {
            model.projects._setEntryForTesting(space: space, key: "\(devbox.id.uuidString):\(root)", entry: entry)
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
        let texts = Set(AccessibilityProbe.elements(in: window).flatMap { [$0.value, $0.name].compactMap { $0 } })
        XCTAssertTrue(texts.contains("No Space selected"), "\(texts.sorted())")
        XCTAssertFalse(texts.contains("Hot reload"))
    }

    func testFailedProbeKeepsStaleSnapshotUnderBanner() throws {
        let entry = ProjectInspectorModel.Entry(snapshot: snapshot(), state: .failed("ssh timed out"), lastProbe: Date(), rawProbe: nil, localVMs: nil)
        let (model, _) = try model(entry: entry)
        let (window, _) = host(model)
        defer { window.close() }
        settle()
        let texts = Set(AccessibilityProbe.elements(in: window).flatMap { [$0.value, $0.name].compactMap { $0 } })
        XCTAssertTrue(texts.contains("ssh timed out"), "\(texts.sorted())")
        XCTAssertTrue(texts.contains("Hot reload"), "stale snapshot must stay visible")
    }
}
