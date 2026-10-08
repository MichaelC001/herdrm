import Foundation
import XCTest
@testable import HerdrKit

private func agent(_ paneID: String, tab: String? = "w1:t1", workspace: String = "w1") -> AgentInfo {
    AgentInfo(
        terminalID: "term-\(paneID)", agentKindRaw: "pi", name: nil, customTitle: nil,
        terminalTitle: nil, terminalTitleStripped: nil, agentStatusRaw: "idle",
        workspaceID: workspace, tabID: tab ?? "", paneID: paneID,
        focused: false, cwd: nil, revision: 0, tokens: nil
    )
}

private func shell(_ paneID: String, tab: String? = "w1:t1", workspace: String = "w1") -> PaneInfo {
    PaneInfo(
        paneID: paneID, terminalID: "term-\(paneID)", workspaceID: workspace, tabID: tab,
        agentKindRaw: nil, agentStatusRaw: "unknown", terminalTitle: nil, cwd: nil, revision: 0
    )
}

private func tab(_ tabID: String, workspace: String = "w1") -> TabInfo {
    TabInfo(tabID: tabID, workspaceID: workspace, number: 1, label: tabID, focused: false, paneCount: 1, agentStatusRaw: nil)
}

private func workspace(_ id: String) -> WorkspaceInfo {
    WorkspaceInfo(workspaceID: id, number: 1, label: id, focused: false, paneCount: nil, tabCount: nil, activeTabID: nil, agentStatusRaw: nil)
}

final class SidebarTreeTests: XCTestCase {
    func testPaneOrdinalIsBase36AfterTheP() {
        XCTAssertEqual(SidebarTree.paneOrdinal("w1A:p1"), 1)
        XCTAssertEqual(SidebarTree.paneOrdinal("w1A:p9"), 9)
        XCTAssertEqual(SidebarTree.paneOrdinal("w1A:pA"), 10)
        XCTAssertEqual(SidebarTree.paneOrdinal("w1A:pZ"), 35)
        XCTAssertEqual(SidebarTree.paneOrdinal("w1A:p10"), 36)
        XCTAssertNil(SidebarTree.paneOrdinal("nonsense"))
        XCTAssertNil(SidebarTree.paneOrdinal("w1:p"))
    }

    func testUnparsableIdsSortAfterParsableOnes() {
        XCTAssertFalse(SidebarTree.paneOrder("w1:p10", "w1:p9"))   // 36 > 9
        XCTAssertTrue(SidebarTree.paneOrder("w1:p9", "w1:p10"))
        XCTAssertTrue(SidebarTree.paneOrder("w1:pZ", "junk"))
        XCTAssertFalse(SidebarTree.paneOrder("junk", "w1:pZ"))
        XCTAssertTrue(SidebarTree.paneOrder("junk-a", "junk-b"))    // string fallback
    }

    func testOldestPaneIsMainAndTheRestAreChildrenByOrdinal() {
        let groups = SidebarTree.build(
            agents: [agent("w1:p7"), agent("w1:p1")],
            terminalPanes: [shell("w1:p4")],
            tabs: [tab("w1:t1")],
            workspaces: [workspace("w1")]
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].workspaceID, "w1")
        XCTAssertEqual(groups[0].tabs.count, 1)
        let main = groups[0].tabs[0].main
        XCTAssertEqual(main.leaf.paneID, "w1:p1")
        guard case .agent = main.leaf else { return XCTFail("main should be the agent") }
        XCTAssertEqual(main.children.map(\.leaf.paneID), ["w1:p4", "w1:p7"])
        guard case .terminal = main.children[0].leaf else { return XCTFail("p4 should be a terminal leaf") }
        XCTAssertTrue(main.children.allSatisfy { $0.children.isEmpty })
    }

    func testWhenTheOldestCloses_theNextOldestIsMain() {
        let groups = SidebarTree.build(
            agents: [agent("w1:p7")],
            terminalPanes: [shell("w1:p4")],
            tabs: [tab("w1:t1")],
            workspaces: [workspace("w1")]
        )
        let main = groups[0].tabs[0].main
        XCTAssertEqual(main.leaf.paneID, "w1:p4")
        guard case .terminal = main.leaf else { return XCTFail("main should now be the shell") }
        XCTAssertEqual(main.children.map(\.leaf.paneID), ["w1:p7"])
    }

    func testTabsFollowSnapshotOrder_andUntabbedPanesComeLast() {
        let groups = SidebarTree.build(
            agents: [agent("w1:p1", tab: "w1:t1"), agent("w1:p2", tab: "w1:t2")],
            terminalPanes: [shell("w1:p3", tab: nil)],
            tabs: [tab("w1:t2"), tab("w1:t1")],   // snapshot order: t2 first
            workspaces: [workspace("w1")]
        )
        let tabs = groups[0].tabs
        XCTAssertEqual(tabs.map(\.tabID), ["w1:t2", "w1:t1", nil])
        XCTAssertEqual(tabs.map(\.main.leaf.paneID), ["w1:p2", "w1:p1", "w1:p3"])
        XCTAssertTrue(tabs[2].main.children.isEmpty)
    }

    func testSpacesFollowWorkspaceOrder_andUnknownWorkspacesTrail() {
        let groups = SidebarTree.build(
            agents: [agent("w9:p1", tab: "w9:t1", workspace: "w9"), agent("w2:p1", tab: "w2:t1", workspace: "w2")],
            terminalPanes: [shell("w5:p1", tab: "w5:t1", workspace: "w5")],
            tabs: [tab("w9:t1", workspace: "w9"), tab("w2:t1", workspace: "w2")],
            workspaces: [workspace("w2"), workspace("w9")]
        )
        XCTAssertEqual(groups.map(\.workspaceID), ["w2", "w9", "w5"])
        XCTAssertEqual(groups[2].tabs[0].main.leaf.paneID, "w5:p1")
    }

    func testEveryPaneAppearsExactlyOnce() {
        let groups = SidebarTree.build(
            agents: [agent("w1:p1"), agent("w1:p5", tab: "w1:t2")],
            terminalPanes: [shell("w1:p2"), shell("w1:p3", tab: "w1:t2"), shell("w1:p4", tab: nil)],
            tabs: [tab("w1:t1"), tab("w1:t2")],
            workspaces: [workspace("w1")]
        )
        var seen: [String] = []
        for group in groups {
            for tabGroup in group.tabs {
                seen.append(tabGroup.main.leaf.paneID)
                seen.append(contentsOf: tabGroup.main.children.map(\.leaf.paneID))
            }
        }
        XCTAssertEqual(seen.sorted(), ["w1:p1", "w1:p2", "w1:p3", "w1:p4", "w1:p5"])
        XCTAssertEqual(Set(seen).count, seen.count)
    }

    func testEmptyInputGivesEmptyTree() {
        XCTAssertTrue(SidebarTree.build(agents: [], terminalPanes: [], tabs: [], workspaces: [workspace("w1")]).isEmpty)
    }
}
