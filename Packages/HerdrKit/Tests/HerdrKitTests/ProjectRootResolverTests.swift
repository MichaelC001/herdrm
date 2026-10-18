import Foundation
import XCTest
@testable import HerdrKit

final class ProjectRootResolverTests: XCTestCase {
    private let home = "/home/dev"

    func testWorktreeResolvesToMainRoot() {
        let roots = [
            ProbeRoot(
                cwd: "/home/dev/acme-app/frontend",
                toplevel: "/home/dev/acme-app",
                commonDir: "/home/dev/acme-app/.git"
            ),
            ProbeRoot(
                cwd: "/home/dev/acme-app/.claude/worktrees/conntest",
                toplevel: "/home/dev/acme-app/.claude/worktrees/conntest",
                commonDir: "/home/dev/acme-app/.git"
            ),
        ]
        let resolved = ProjectRootResolver.resolve(roots: roots, focusedCwd: nil, home: home, override: nil)
        XCTAssertEqual(resolved?.root, "/home/dev/acme-app")
        XCTAssertEqual(resolved?.worktreeRoots.contains("/home/dev/acme-app"), true)
        XCTAssertEqual(resolved?.worktreeRoots.contains("/home/dev/acme-app/.claude/worktrees/conntest"), true)
    }

    func testMostFrequentMainRootWinsTieToFocused() {
        let roots = [
            ProbeRoot(cwd: "/home/dev/alpha/src", toplevel: "/home/dev/alpha", commonDir: "/home/dev/alpha/.git"),
            ProbeRoot(cwd: "/home/dev/beta/src", toplevel: "/home/dev/beta", commonDir: "/home/dev/beta/.git"),
        ]
        let resolved = ProjectRootResolver.resolve(
            roots: roots, focusedCwd: "/home/dev/beta/src", home: home, override: nil
        )
        XCTAssertEqual(resolved?.root, "/home/dev/beta")
    }

    func testNonGitUsesCommonAncestorUnlessHomeOrSlash() {
        let sibling = [
            ProbeRoot(cwd: "/srv/x/a"),
            ProbeRoot(cwd: "/srv/x/b"),
        ]
        XCTAssertEqual(
            ProjectRootResolver.resolve(roots: sibling, focusedCwd: nil, home: home, override: nil)?.root,
            "/srv/x"
        )

        let underHome = [
            ProbeRoot(cwd: "/home/dev/a"),
            ProbeRoot(cwd: "/home/dev/b"),
        ]
        XCTAssertEqual(
            ProjectRootResolver.resolve(roots: underHome, focusedCwd: "/home/dev/b", home: home, override: nil)?.root,
            "/home/dev/b"
        )

        let slashOnly = [
            ProbeRoot(cwd: "/a"),
            ProbeRoot(cwd: "/b"),
        ]
        XCTAssertEqual(
            ProjectRootResolver.resolve(roots: slashOnly, focusedCwd: "/b", home: home, override: nil)?.root,
            "/b"
        )
    }

    func testOverrideWins() {
        let roots = [ProbeRoot(cwd: "/home/dev/acme-app/frontend", toplevel: "/home/dev/acme-app")]
        let resolved = ProjectRootResolver.resolve(roots: roots, focusedCwd: nil, home: home, override: "/opt/other")
        XCTAssertEqual(resolved?.root, "/opt/other")
        XCTAssertEqual(resolved?.worktreeRoots, ["/opt/other"])
    }

    func testIdentityTokensStripVersions() {
        func tokens(_ root: String) -> [String] {
            ProjectIdentity(deviceID: UUID(), root: root, worktreeRoots: [root]).tokens
        }
        XCTAssertEqual(tokens("/home/dev/acme-app"), ["acme", "app"])
        XCTAssertEqual(tokens("/home/dev/foo-v2"), ["foo"])
        XCTAssertEqual(tokens("/home/dev/bar_2024"), ["bar"])
    }
}
