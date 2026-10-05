import XCTest
@testable import HerdrKit

final class GrazrAccountsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_876_000) // 2026-10-01 17:33 UTC

    private func window(_ group: String, _ remaining: Int, scope: String? = nil, resetsIn hours: Double) -> GrazrWindow {
        GrazrWindow(
            kind: group, scope: scope, group: group, remaining: remaining,
            resetsAt: now.addingTimeInterval(hours * 3600)
        )
    }

    func testOrdersActiveFirstThenTheConfiguredOrder() {
        let report = GrazrReport(
            active: "c",
            accounts: [
                GrazrAccount(id: "a", name: "a@x"),
                GrazrAccount(id: "z", name: "unlisted@x"),
                GrazrAccount(id: "b", name: "b@x"),
                GrazrAccount(id: "c", name: "c@x"),
            ],
            order: ["b@x", "a@x", "c@x"]
        )

        XCTAssertEqual(report.sortedAccounts.map(\.id), ["c", "b", "a", "z"])
        XCTAssertFalse(report.isListed(report.accounts[1]))
    }

    func testAWindowPastItsResetIsFullAgain() {
        let spent = window("session", 0, resetsIn: -1)
        XCTAssertFalse(spent.isOpen(now: now))
        XCTAssertEqual(spent.left(now: now), 100)

        let open = window("weekly", 14, resetsIn: 30)
        XCTAssertEqual(open.left(now: now), 14)
    }

    func testLeastLeftIgnoresWindowsThatHaveReset() {
        let account = GrazrAccount(id: "a", name: "a", windows: [
            window("session", 0, resetsIn: -2),
            window("weekly", 14, resetsIn: 30),
            window("weekly", 42, scope: "Fable", resetsIn: 30),
        ])
        XCTAssertEqual(account.leastLeft(now: now), 14)
        XCTAssertEqual(account.sortedWindows.map(\.label), ["5h", "Week", "Fable week"])
    }

    func testThresholdsFallBackToGrazrsDefaults() {
        XCTAssertEqual(GrazrReport().sessionThreshold, 15)
        XCTAssertEqual(GrazrReport().weeklyThreshold, 20)
        let report = GrazrReport(settings: ["REMAINING_WEEKLY": "10", "DRY_RUN": "1", "ENABLED": "0"])
        XCTAssertEqual(report.weeklyThreshold, 10)
        XCTAssertTrue(report.dryRun)
        XCTAssertFalse(report.enabled)
    }

    func testALapsedBlockNoLongerApplies() {
        let account = GrazrAccount(id: "a", name: "a")
        let lapsed = GrazrReport(blocked: ["a": GrazrBlock(reason: "rate_limit", until: now.timeIntervalSince1970 - 1)])
        XCTAssertNil(lapsed.block(for: account, now: now))
        let refused = GrazrReport(blocked: ["a": GrazrBlock(reason: "billing_error")])
        XCTAssertEqual(refused.block(for: account, now: now)?.reason, "billing_error")
    }

    func testSwitchTargetsAreEveryUnblockedAccountButTheActiveOne() {
        let report = GrazrReport(
            active: "a",
            accounts: [GrazrAccount(id: "a", name: "a"), GrazrAccount(id: "b", name: "b"), GrazrAccount(id: "c", name: "c")],
            blocked: ["c": GrazrBlock(reason: "authentication_failed")]
        )
        XCTAssertEqual(report.accounts.filter { report.canSwitch(to: $0, now: now) }.map(\.id), ["b"])
    }

    func testOnlyABlockWithoutAnEndNeedsASignIn() {
        let report = GrazrReport(
            accounts: [GrazrAccount(id: "a", name: "a"), GrazrAccount(id: "b", name: "b"), GrazrAccount(id: "c", name: "c")],
            blocked: [
                "a": GrazrBlock(reason: "authentication_failed"),
                "b": GrazrBlock(reason: "rate_limit", until: now.timeIntervalSince1970 + 600),
            ]
        )
        XCTAssertEqual(report.accounts.filter { report.needsSignIn($0, now: now) }.map(\.id), ["a"])
    }

    func testASwitchSummaryIsGrazrsLastLine() {
        XCTAssertEqual(GrazrSwitchResult(ok: true, output: "notice\nRotated a -> b\n\n").summary, "Rotated a -> b")
        XCTAssertNil(GrazrSwitchResult(ok: false, output: " \n").summary)
    }

    #if os(macOS)
    /// The reader script itself, against grazr's real file layout in a
    /// throwaway home: what it reports, and that nothing else leaves.
    func testTheReaderReportsGrazrsFilesAndNothingSecret() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("grazr-reader-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let state = home.appendingPathComponent(".local/state/herdr/plugins/wazum.grazr")
        let accounts = state.appendingPathComponent("accounts")
        let config = home.appendingPathComponent(".config/herdr/plugins/config/wazum.grazr")
        try FileManager.default.createDirectory(at: accounts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)

        func write(_ text: String, to url: URL) throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("""
        {"name": "work@x", "email": "work@x", "organization": "Acme",
         "accessToken": "sk-SECRET-1",
         "oauthAccount": {"accountUuid": "uuid-work", "emailAddress": "work@x", "refreshToken": "SECRET-2"},
         "snapshot": [
           {"kind": "session", "scope": null, "group": "session", "remaining": 0, "resets_at": "2026-10-01T21:50:00+00:00"},
           {"kind": "weekly_scoped", "scope": "Fable", "group": "weekly", "remaining": 84, "resets_at": "2026-10-04T18:00:00.513830+00:00"}
         ]}
        """, to: accounts.appendingPathComponent("uuid-work.json"))
        try write(#"{"name": "home@x", "oauthAccount": {"accountUuid": "uuid-home"}, "snapshot": null}"#,
                  to: accounts.appendingPathComponent("uuid-home.json"))
        try write("not json", to: accounts.appendingPathComponent(".grazr-tmp"))
        try write("""
        # comment
        REMAINING_WEEKLY=10   # weekly
        ACCOUNTS="work@x home@x"
        """, to: config.appendingPathComponent("config.env"))
        try write(#"{"uuid-home": {"reason": "billing_error", "at": 1, "until": null, "reading": [{"secret": "SECRET-3"}]}}"#,
                  to: state.appendingPathComponent("blocked.json"))
        try write(#"{"oauthAccount": {"accountUuid": "uuid-work"}, "primaryApiKey": "SECRET-4"}"#,
                  to: home.appendingPathComponent(".claude.json"))

        let environment = "HOME='\(home.path)' XDG_STATE_HOME= XDG_CONFIG_HOME= CLAUDE_CONFIG_DIR= "
        let output = try await DeviceFileService(device: .local).run(environment + Grazr.readerCommand)
        XCTAssertFalse(String(decoding: output, as: UTF8.self).contains("SECRET"))

        let report = try JSONDecoder().decode(GrazrReport.self, from: output)
        XCTAssertEqual(report.active, "uuid-work")
        XCTAssertEqual(report.order, ["work@x", "home@x"])
        XCTAssertEqual(report.weeklyThreshold, 10)
        XCTAssertEqual(report.blocked["uuid-home"]?.reason, "billing_error")
        XCTAssertEqual(report.sortedAccounts.map(\.id), ["uuid-work", "uuid-home"])
        let work = report.sortedAccounts[0]
        XCTAssertEqual(work.organization, "Acme")
        XCTAssertEqual(work.windows.map(\.label), ["5h", "Fable week"])
        XCTAssertEqual(work.windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-10-01T21:50:00Z"))
        XCTAssertEqual(report.sortedAccounts[1].windows, [])
    }

    /// The switch and sign-in scripts, against a stand-in herdr and grazr in a
    /// throwaway home: they find grazr through `herdr plugin list` and run it in
    /// herdr's plugin environment. A switch pins the pick to the chosen
    /// account, listed in ACCOUNTS or not.
    func testSwitchAndSignInRunGrazrPinnedToTheChosenAccount() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("grazr-switch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("plugins/wazum.grazr")
        let bin = home.appendingPathComponent(".local/bin")
        let accounts = home.appendingPathComponent(".local/state/herdr/plugins/wazum.grazr/accounts")
        for directory in [root, bin, accounts] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func write(_ text: String, to url: URL) throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("""
        #!/bin/sh
        printf '{"result":{"plugins":[{"plugin_id":"other","plugin_root":"/nowhere"},{"plugin_id":"wazum.grazr","plugin_root":"%s"}]}}' '\(root.path)'
        """, to: bin.appendingPathComponent("herdr"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("herdr").path)
        for id in ["uuid-work", "uuid-spare"] {
            try write("{}", to: accounts.appendingPathComponent("\(id).json"))
        }
        try write("""
        def load(paths, names):
            everyone = ["uuid-work", "uuid-home", "uuid-spare"]
            return [type("Account", (), {"id": id}) for id in (everyone if not names else everyone[:2])]
        """, to: root.appendingPathComponent("accounts.py"))
        try write("""
        def next_account(active, accounts, now, thresholds):
            return "unpatched"
        """, to: root.appendingPathComponent("core.py"))
        try write("""
        import json, os, accounts, core
        def read_key():
            return "q"
        def _enrol_from(runtime, source):
            name = input("account name: ")
            print("Enrolled %s from %s" % (name, os.path.basename(source)))
            return 0
        def main(argv):
            if argv[1] == "enrol":
                if read_key() != "l":
                    return 0
                source = os.path.join(os.environ["HERDR_PLUGIN_STATE_DIR"], "enrol-1")
                os.makedirs(source, exist_ok=True)
                with open(os.path.join(source, ".claude.json"), "w") as handle:
                    json.dump({"oauthAccount": {"accountUuid": os.environ["LOGIN"], "emailAddress": os.environ["LOGIN"] + "@x"}}, handle)
                return _enrol_from(None, source)
            try:
                picked = core.next_account("uuid-work", accounts.load(None, ["work@x", "home@x"]), None, {})
            except RuntimeError as error:
                print("grazr: %s" % error)
                return 1
            if picked is None:
                print("grazr: Nothing to swap to")
                return 1
            same = lambda a, b: os.path.realpath(a) == os.path.realpath(b)
            print("%s %s %s" % (argv[1], same(os.getcwd(), os.environ["HERDR_PLUGIN_ROOT"]), os.environ["HERDR_PLUGIN_STATE_DIR"].endswith("/wazum.grazr")))
            print("Rotated uuid-work -> %s" % picked)
            return 0
        """, to: root.appendingPathComponent("grazr.py"))

        let environment = "export HOME='\(home.path)' XDG_STATE_HOME= XDG_CONFIG_HOME=; "
        func switching(to id: String) async throws -> GrazrSwitchResult {
            let output = try await DeviceFileService(device: .local).run(environment + Grazr.switchCommand(to: id))
            return try JSONDecoder().decode(GrazrSwitchResult.self, from: output)
        }

        let moved = try await switching(to: "uuid-spare")
        XCTAssertTrue(moved.ok)
        XCTAssertEqual(moved.output, "swap True True\nRotated uuid-work -> uuid-spare\n")

        let stayed = try await switching(to: "uuid-work")
        XCTAssertFalse(stayed.ok)
        XCTAssertEqual(stayed.summary, "grazr: Already on that account")

        let gone = try await switching(to: "it's-gone")
        XCTAssertEqual(gone, GrazrSwitchResult(ok: false, output: "That account is no longer enrolled"))

        // Re-authenticating: grazr's enrol, pre-answered with "l" and the
        // account's name, and refused when the browser signed in elsewhere.
        _ = try await DeviceFileService(device: .local).run(environment + Grazr.installReauthCommand)
        func reauthenticating(signedInAs login: String) async throws -> String {
            let output = try await DeviceFileService(device: .local).run(
                environment + "export LOGIN=\(login) PATH=\"$HOME/.local/bin:$PATH\"; "
                    // A refused login exits 1, which `run` would throw on.
                    + "(\(Grazr.reauthInvocation(accountID: "uuid-home", name: "home's@x"))); true"
            )
            return String(decoding: output, as: UTF8.self)
        }
        let renewed = try await reauthenticating(signedInAs: "uuid-home")
        XCTAssertTrue(renewed.contains("account name: home's@x\nEnrolled home's@x from enrol-1\n"), renewed)

        let elsewhere = try await reauthenticating(signedInAs: "uuid-work")
        XCTAssertTrue(elsewhere.contains("That login is uuid-work@x, not home's@x, so nothing changed"), elsewhere)
        XCTAssertFalse(elsewhere.contains("Enrolled"), elsewhere)
    }
    #endif
}
