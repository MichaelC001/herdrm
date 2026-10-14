import Foundation

/// Groups a device's attachable panes the way the sidebar shows them: space,
/// then each tab's main pane, then that pane's children. Built from the
/// snapshot alone, so it holds for any agent CLI and needs no layout fetch.
///
/// The main pane of a tab is the one with the lowest pane ordinal among the
/// panes the tab has right now: herdr numbers panes per workspace in creation
/// order, so this is the pane that has been in the tab longest, the one that
/// got split. When it closes, the next oldest takes over at the next snapshot;
/// nothing is remembered between builds.
public enum SidebarTree {
    /// One attachable pane: an agent, or a bare terminal.
    public enum Leaf: Equatable, Sendable {
        case agent(AgentInfo)
        case terminal(PaneInfo)

        public var paneID: String {
            switch self {
            case .agent(let info): return info.paneID
            case .terminal(let info): return info.paneID
            }
        }

        public var tabID: String? {
            switch self {
            case .agent(let info): return info.tabID.isEmpty ? nil : info.tabID
            case .terminal(let info): return info.tabID
            }
        }

        public var workspaceID: String {
            switch self {
            case .agent(let info): return info.workspaceID
            case .terminal(let info): return info.workspaceID
            }
        }
    }

    public struct PaneNode: Equatable, Sendable {
        public let leaf: Leaf
        /// Non-empty only on a tab's main pane. Ordered by pane ordinal.
        public let children: [PaneNode]

        public init(leaf: Leaf, children: [PaneNode] = []) {
            self.leaf = leaf
            self.children = children
        }
    }

    public struct TabGroup: Equatable, Sendable {
        /// Nil for a pane the snapshot gave no tab; such a pane is its own group.
        public let tabID: String?
        public let main: PaneNode

        public init(tabID: String?, main: PaneNode) {
            self.tabID = tabID
            self.main = main
        }
    }

    public struct SpaceGroup: Equatable, Sendable {
        public let workspaceID: String
        public let tabs: [TabGroup]

        public init(workspaceID: String, tabs: [TabGroup]) {
            self.workspaceID = workspaceID
            self.tabs = tabs
        }
    }

    /// The base36 value after `:p` in a herdr pane id (`w1A:pC` is 12), or nil
    /// when the id is not shaped like one.
    public static func paneOrdinal(_ paneID: String) -> Int? {
        guard let range = paneID.range(of: ":p", options: .backwards) else { return nil }
        let digits = paneID[range.upperBound...]
        guard !digits.isEmpty else { return nil }
        return Int(digits, radix: 36)
    }

    /// Creation order: by ordinal, with ids that do not parse after every one
    /// that does, among themselves by string.
    public static func paneOrder(_ lhs: String, _ rhs: String) -> Bool {
        switch (paneOrdinal(lhs), paneOrdinal(rhs)) {
        case (let l?, let r?): return l < r
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return lhs < rhs
        }
    }

    /// Groups one device's panes. `agents` is the snapshot's agent list and
    /// `terminalPanes` its `ordinaryTerminalPanes`, which already excludes agent
    /// panes, so each pane appears once. Spaces follow `workspaces` order and
    /// tabs follow `tabs` order; panes of a workspace or tab the snapshot does
    /// not list trail the known ones rather than being dropped.
    public static func build(
        agents: [AgentInfo],
        terminalPanes: [PaneInfo],
        tabs: [TabInfo],
        workspaces: [WorkspaceInfo]
    ) -> [SpaceGroup] {
        let leaves = agents.map(Leaf.agent) + terminalPanes.map(Leaf.terminal)
        guard !leaves.isEmpty else { return [] }

        // Tab groups: panes sharing a tab id; a pane without one is its own group.
        var byTab: [String: [Leaf]] = [:]
        var untabbed: [Leaf] = []
        for leaf in leaves {
            if let tabID = leaf.tabID {
                byTab[tabID, default: []].append(leaf)
            } else {
                untabbed.append(leaf)
            }
        }

        func tabGroup(tabID: String?, leaves: [Leaf]) -> TabGroup {
            let ordered = leaves.sorted { paneOrder($0.paneID, $1.paneID) }
            let children = ordered.dropFirst().map { PaneNode(leaf: $0) }
            return TabGroup(tabID: tabID, main: PaneNode(leaf: ordered[0], children: Array(children)))
        }

        let tabRank = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($1.tabID, $0) })
        var groupsByWorkspace: [String: [TabGroup]] = [:]

        // Known tabs in snapshot order, then tabs the snapshot does not list,
        // then untabbed panes, the latter two by their main pane's ordinal.
        let knownTabIDs = byTab.keys.filter { tabRank[$0] != nil }
            .sorted { tabRank[$0]! < tabRank[$1]! }
        let unknownTabIDs = byTab.keys.filter { tabRank[$0] == nil }
        var trailing = unknownTabIDs.map { tabGroup(tabID: $0, leaves: byTab[$0]!) }
            + untabbed.map { tabGroup(tabID: nil, leaves: [$0]) }
        trailing.sort { paneOrder($0.main.leaf.paneID, $1.main.leaf.paneID) }

        for tabID in knownTabIDs {
            let group = tabGroup(tabID: tabID, leaves: byTab[tabID]!)
            groupsByWorkspace[group.main.leaf.workspaceID, default: []].append(group)
        }
        for group in trailing {
            groupsByWorkspace[group.main.leaf.workspaceID, default: []].append(group)
        }

        var result: [SpaceGroup] = []
        for workspace in workspaces {
            if let groups = groupsByWorkspace.removeValue(forKey: workspace.workspaceID) {
                result.append(SpaceGroup(workspaceID: workspace.workspaceID, tabs: groups))
            }
        }
        // Workspaces the snapshot does not list (a change in flight): after the
        // known ones, in a stable order.
        for workspaceID in groupsByWorkspace.keys.sorted() {
            result.append(SpaceGroup(workspaceID: workspaceID, tabs: groupsByWorkspace[workspaceID]!))
        }
        return result
    }
}
