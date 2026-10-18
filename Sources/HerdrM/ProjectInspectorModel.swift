import Foundation
import HerdrKit

/// What the view knows about a Space when it asks for a probe.
struct ProjectContext: Equatable {
    var device: Device
    var workspaceLabel: String
    var cwds: [String]
    var focusedCwd: String?
}

/// Probes a Space's device, classifies the result into a `ProjectSnapshot` and caches it per
/// project key, so two Spaces on one project share a snapshot.
@MainActor
final class ProjectInspectorModel: ObservableObject {
    enum State: Equatable { case idle, probing, live, failed(String) }

    struct Entry: Equatable {
        var snapshot: ProjectSnapshot?
        var state: State
        var lastProbe: Date?
        var rawProbe: ProjectProbe?
        var localVMs: ProjectProbe?
    }

    @Published private(set) var entries: [String: Entry] = [:]
    @Published private(set) var keyBySpace: [SpaceRef: String] = [:]

    private let runner: ProjectProbeRunning
    private let store: ProjectStore
    private let localDevice: Device
    private let now: () -> Date
    private var inFlight: [UUID: Int] = [:]
    private var contexts: [SpaceRef: ProjectContext] = [:]

    init(
        runner: ProjectProbeRunning = DeviceProjectProbeRunner(), store: ProjectStore = ProjectStore(),
        localDevice: Device = .local, now: @escaping () -> Date = Date.init
    ) {
        self.runner = runner
        self.store = store
        self.localDevice = localDevice
        self.now = now
    }

    // MARK: - Reading

    func entry(for space: SpaceRef) -> Entry? {
        keyBySpace[space].flatMap { entries[$0] }
    }

    func identity(for space: SpaceRef) -> ProjectIdentity? {
        entry(for: space)?.snapshot?.identity
    }

    // MARK: - Probing

    /// Seconds to wait before the next tick: 15 while healthy, 2 doubling to 60 after failures.
    nonisolated static func pollDelay(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 15 }
        return min(60, 2 * pow(2, Double(min(failures - 1, 10))))
    }

    /// Probe now, then every 15 s while the caller's task lives; backs off after failures.
    func run(space: SpaceRef, context: ProjectContext) async {
        var failures = 0
        while !Task.isCancelled {
            if inFlight[context.device.id, default: 0] == 0 {
                failures = await probe(space: space, context: context) ? 0 : failures + 1
            }
            do { try await Task.sleep(for: .seconds(Self.pollDelay(failures: failures))) } catch { return }
        }
    }

    /// One probe. Returns false when the probe failed. A result for a Space whose project key
    /// changed during the probe (see `setRoot`) is dropped.
    @discardableResult
    func probe(space: SpaceRef, context: ProjectContext) async -> Bool {
        contexts[space] = context
        let device = context.device
        let startKey = settledKey(space)
        let overrideRoot = store.spaceRoot(deviceID: device.id, workspaceLabel: context.workspaceLabel)

        guard ProjectProbeScript.isSupported(device) else {
            fail(
                space: space, key: startKey ?? Self.pendingKey(space),
                message: String(localized: "Project details need a shell (tailcat and Windows devices are not supported)"))
            return false
        }

        if let key = startKey ?? overrideRoot.map({ Self.key(device: device, root: $0) }), entries[key]?.snapshot == nil {
            update(key: key) { $0.state = .probing }
            keyBySpace[space] = keyBySpace[space] ?? key
        }

        inFlight[device.id, default: 0] += 1
        defer { inFlight[device.id, default: 1] -= 1 }

        let local = device.isLocal
        let sections = local ? ProjectProbeScript.allSections : ProjectProbeScript.allSections.filter { $0 != "vms" }
        let runner = self.runner
        let localDevice = self.localDevice
        let cwds = Self.unique(context.cwds)

        let main: ProjectProbe
        var localVMs: ProjectProbe?
        do {
            async let mainText = runner.run(device: device, sections: sections, cwds: cwds)
            async let vmText: String? = local ? nil : (try? await runner.run(device: localDevice, sections: ["host", "vms"], cwds: []))
            main = ProjectProbeParser.parse(try await mainText)
            localVMs = await vmText.map(ProjectProbeParser.parse)
        } catch {
            guard settledKey(space) == startKey else { return true }
            fail(space: space, key: startKey ?? Self.pendingKey(space), message: error.localizedDescription)
            return false
        }
        if local { localVMs = main }
        guard settledKey(space) == startKey else { return true }

        let home = homeDirectory(for: device, probe: main)
        guard let resolved = ProjectRootResolver.resolve(
            roots: main.roots, focusedCwd: context.focusedCwd, home: home, override: overrideRoot)
        else {
            fail(
                space: space, key: startKey ?? Self.pendingKey(space),
                message: String(localized: "No project directory found for this Space"))
            return false
        }

        let identity = ProjectIdentity(deviceID: device.id, root: resolved.root, worktreeRoots: resolved.worktreeRoots)
        let overrides = store.overrides(for: identity.key)
        let stamp = now()
        let snapshot = await Task.detached {
            ProjectClassifier.classify(
                probe: main, localVMs: localVMs, identity: identity, device: device, overrides: overrides, now: stamp)
        }.value
        guard settledKey(space) == startKey else { return true }

        if let old = keyBySpace[space], old != identity.key, Self.isPending(old) { entries[old] = nil }
        keyBySpace[space] = identity.key
        entries[identity.key] = Entry(snapshot: snapshot, state: .live, lastProbe: stamp, rawProbe: main, localVMs: localVMs)
        return true
    }

    // MARK: - Mutations (re-classify from the cached probe, no network)

    func setURLOverride(space: SpaceRef, signature: String, url: String?) {
        mutate(space) { $0.services[signature, default: ServiceOverride()].url = url }
    }

    func setHidden(space: SpaceRef, signature: String, hidden: Bool) {
        mutate(space) { $0.services[signature, default: ServiceOverride()].hidden = hidden }
    }

    func attachCompose(space: SpaceRef, name: String) {
        mutate(space) {
            $0.detachedCompose.removeAll { $0 == name }
            if !$0.attachedCompose.contains(name) { $0.attachedCompose.append(name) }
        }
    }

    func detachCompose(space: SpaceRef, name: String) {
        mutate(space) {
            $0.attachedCompose.removeAll { $0 == name }
            if !$0.detachedCompose.contains(name) { $0.detachedCompose.append(name) }
        }
    }

    func attachContainer(space: SpaceRef, name: String) {
        mutate(space) { if !$0.attachedContainers.contains(name) { $0.attachedContainers.append(name) } }
    }

    func dismissSuggestion(space: SpaceRef, name: String) {
        mutate(space) { if !$0.dismissedSuggestions.contains(name) { $0.dismissedSuggestions.append(name) } }
    }

    func attachVM(space: SpaceRef, vm: VMRow) {
        mutate(space) {
            $0.attachedVMs.removeAll { $0.provider == vm.provider && $0.id == vm.vmID }
            $0.attachedVMs.append(AttachedVM(provider: vm.provider, id: vm.vmID, name: vm.name))
        }
    }

    /// `id` is a probed VM id or the provider-qualified `VMRow.id`.
    func detachVM(space: SpaceRef, id: String) {
        mutate(space) { $0.attachedVMs.removeAll { $0.id == id || "\($0.provider.rawValue):\($0.id)" == id } }
    }

    func linkDevice(space: SpaceRef, device: Device, root: String) {
        mutate(space) {
            $0.linkedDevices.removeAll { $0.deviceID == device.id }
            $0.linkedDevices.append(LinkedDevice(deviceID: device.id, root: root))
        }
    }

    func unlinkDevice(space: SpaceRef, deviceID: UUID) {
        mutate(space) { $0.linkedDevices.removeAll { $0.deviceID == deviceID } }
    }

    /// Pins (or with nil clears) the project root of a Space, moves the Space to that project's
    /// entry at once and re-probes. Any probe already running for the old key is discarded.
    @discardableResult
    func setRoot(space: SpaceRef, context: ProjectContext, root: String?) -> Task<Void, Never>? {
        store.setSpaceRoot(deviceID: context.device.id, workspaceLabel: context.workspaceLabel, root: root)
        keyBySpace[space] = root.map { Self.key(device: context.device, root: $0) }
        return Task { [weak self] in await self?.probe(space: space, context: context) }
    }

    // MARK: - Internals

    private func mutate(_ space: SpaceRef, _ change: (inout ProjectOverrides) -> Void) {
        guard let key = keyBySpace[space], !Self.isPending(key) else { return }
        store.update(key: key, change)
        reclassify(space: space, key: key)
    }

    private func reclassify(space: SpaceRef, key: String) {
        guard var entry = entries[key], let probe = entry.rawProbe, let identity = entry.snapshot?.identity,
              let device = contexts[space]?.device
        else { return }
        entry.snapshot = ProjectClassifier.classify(
            probe: probe, localVMs: entry.localVMs, identity: identity, device: device,
            overrides: store.overrides(for: key), now: entry.lastProbe ?? now())
        entries[key] = entry
    }

    private func fail(space: SpaceRef, key: String, message: String) {
        update(key: key) { $0.state = .failed(message) }
        if keyBySpace[space] == nil { keyBySpace[space] = key }
    }

    private func update(key: String, _ change: (inout Entry) -> Void) {
        var entry = entries[key] ?? Entry(snapshot: nil, state: .idle, lastProbe: nil, rawProbe: nil, localVMs: nil)
        change(&entry)
        entries[key] = entry
    }

    /// The Space's key, or nil while it only has a placeholder entry.
    private func settledKey(_ space: SpaceRef) -> String? {
        keyBySpace[space].flatMap { Self.isPending($0) ? nil : $0 }
    }

    /// Where a Space's state lives before its project root is known.
    private static func pendingKey(_ space: SpaceRef) -> String { "pending:\(space.deviceID.uuidString):\(space.workspaceID)" }
    private static func isPending(_ key: String) -> Bool { key.hasPrefix("pending:") }
    private static func key(device: Device, root: String) -> String {
        ProjectIdentity(deviceID: device.id, root: root, worktreeRoots: [root]).key
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Local: the real home. Remote: the `/home/<user>` or `/Users/<user>` prefix of a probed cwd,
    /// else `/home/<ssh user>`.
    private func homeDirectory(for device: Device, probe: ProjectProbe) -> String {
        if device.isLocal { return NSHomeDirectory() }
        for root in probe.roots {
            let parts = root.cwd.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0] == "home" || parts[0] == "Users" { return "/\(parts[0])/\(parts[1])" }
        }
        if let target = device.sshTarget, let user = target.split(separator: "@").first, target.contains("@") {
            return "/home/\(user)"
        }
        return "/root"
    }
}
