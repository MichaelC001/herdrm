import Foundation

/// grazr (github.com/wazum/herdr-grazr) rotates Claude Code between several
/// subscriptions. It keeps what each account had left in plain JSON files on
/// the device; this reads them for the sidebar's Accounts window.
public enum Grazr {
    public static let pluginID = "wazum.grazr"
    public static let swapActionID = "swap"

    /// Prints a `GrazrReport` as JSON. Runs on the device with the python3
    /// grazr itself needs. Only names, ids and usage readings leave the device:
    /// the parked credentials live elsewhere, and `.claude.json` contributes
    /// the active account's id and nothing else.
    public static let readerCommand = #"""
    python3 - <<'GRAZR_EOF'
    import glob, json, os
    from datetime import datetime

    home = os.path.expanduser("~")
    state = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(home, ".local/state"), "herdr/plugins/wazum.grazr")
    config = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(home, ".config"), "herdr/plugins/config/wazum.grazr/config.env")

    def load(path, default=None):
        try:
            with open(path) as handle:
                return json.load(handle)
        except Exception:
            return default

    def epoch(text):
        try:
            return datetime.fromisoformat(text).timestamp()
        except Exception:
            return None

    report = {"installed": os.path.isdir(state), "accounts": [], "order": [], "settings": {}, "blocked": {}}
    for path in sorted(glob.glob(os.path.join(state, "accounts", "*.json"))):
        entry = load(path)
        if not isinstance(entry, dict):
            continue
        oauth = entry.get("oauthAccount") or {}
        windows = []
        for window in entry.get("snapshot") or []:
            if isinstance(window, dict) and isinstance(window.get("remaining"), (int, float)):
                windows.append({
                    "kind": str(window.get("kind") or ""),
                    "scope": window.get("scope"),
                    "group": str(window.get("group") or ""),
                    "remaining": int(window["remaining"]),
                    "resets_at": epoch(window.get("resets_at") or ""),
                })
        report["accounts"].append({
            "id": oauth.get("accountUuid") or os.path.basename(path)[:-5],
            "name": entry.get("name") or entry.get("email") or "",
            "organization": entry.get("organization"),
            "windows": windows,
            "updated": os.path.getmtime(path),
        })

    claude = load(os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or home, ".claude.json"), {})
    report["active"] = ((claude or {}).get("oauthAccount") or {}).get("accountUuid")

    try:
        with open(config) as handle:
            for line in handle:
                line = line.split("#", 1)[0].strip()
                if "=" in line:
                    key, value = line.split("=", 1)
                    report["settings"][key.strip()] = value.strip().strip("\"'")
    except Exception:
        pass
    report["order"] = report["settings"].get("ACCOUNTS", "").split()

    for identifier, entry in (load(os.path.join(state, "blocked.json"), {}) or {}).items():
        if isinstance(entry, dict):
            report["blocked"][identifier] = {"reason": str(entry.get("reason") or ""), "until": entry.get("until")}

    print(json.dumps(report))
    GRAZR_EOF
    """#

    #if os(macOS)
    /// Moves Claude to one chosen account and prints a `GrazrSwitchResult`.
    /// grazr's own `swap` only knows "the next account with headroom", so this
    /// runs that same swap -- rotation lock, credential park, pane tags, log --
    /// with its pick pinned to `accountID`, from any enrolled account rather
    /// than only those in ACCOUNTS. grazr's refusals land in `output`, not in a
    /// failed exit.
    public static func switchCommand(to accountID: String) -> String {
        SSHTunnel.remotePathExport + "\n"
            + "python3 - \(HerdrService.shellQuoted(accountID)) <<'GRAZR_EOF'\n"
            + #"""
            import json, sys

            target = sys.argv[1]

            def fail(output):
                print(json.dumps({"ok": False, "output": output}))
                sys.exit(0)

            """#
            + pluginPreamble
            + #"""

            if not os.path.isfile(os.path.join(state, "accounts", target + ".json")):
                fail("That account is no longer enrolled")

            load = accounts.load
            accounts.load = lambda paths, names: load(paths, [])

            def pinned(active, enrolled, now, thresholds):
                # grazr prints a RuntimeError as its refusal.
                if active == target:
                    raise RuntimeError("Already on that account")
                return next((entry.id for entry in enrolled if entry.id == target), None)

            core.next_account = pinned
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = grazr.main(["grazr.py", "swap"])
            print(json.dumps({"ok": code == 0, "output": output.getvalue()}))
            GRAZR_EOF
            """#
    }

    /// Where `installReauthCommand` puts the sign-in script on the device.
    public static let reauthScriptPath = "~/.cache/herdrm/grazr-reauth.py"

    /// Writes the sign-in script that `reauthInvocation` runs in a terminal.
    /// It goes to a file first so the terminal shows one short line, not the
    /// script pasted into the shell.
    public static var installReauthCommand: String {
        "mkdir -p ~/.cache/herdrm && cat > \(reauthScriptPath) <<'GRAZR_EOF'\n"
            + #"""
            import json, sys

            target, name = sys.argv[1], sys.argv[2]

            def fail(message):
                print(message + "\n\npress return to close")
                sys.stdin.readline()
                sys.exit(1)

            """#
            + pluginPreamble
            + #"""

            # grazr's enrol, pre-answered: "l" logs in with an isolated config
            # dir, leaving the account Claude is on alone, and the name is the
            # account's own. Re-enrolling lifts grazr's block on it.
            key = grazr.read_key
            grazr.read_key = lambda *args: "l"
            grazr.input = lambda prompt="": print(prompt + name) or name
            enrol_from = grazr._enrol_from

            def same_account(runtime, source):
                try:
                    with open(os.path.join(source, ".claude.json")) as handle:
                        signed = json.load(handle).get("oauthAccount") or {}
                except Exception:
                    signed = {}
                if signed.get("accountUuid") != target:
                    print("\nThat login is %s, not %s, so nothing changed. Sign in as %s."
                          % (signed.get("emailAddress") or "another account", name, name))
                    return 1
                return enrol_from(runtime, source)

            grazr._enrol_from = same_account
            print("Sign in to Claude as %s. Claude's current account is left as it is.\n" % name)
            code = grazr.main(["grazr.py", "enrol"])
            print("\npress any key to close")
            key()
            sys.exit(code)
            GRAZR_EOF
            """#
    }

    /// The line typed into a fresh terminal on the device; the tab closes
    /// with the script.
    public static func reauthInvocation(accountID: String, name: String) -> String {
        "exec python3 \(reauthScriptPath) \(HerdrService.shellQuoted(accountID)) \(HerdrService.shellQuoted(name))"
    }

    /// Finds grazr through `herdr plugin list` and sets the environment herdr
    /// gives a plugin action, then imports grazr's modules. Expects `fail`.
    private static let pluginPreamble = #"""
    import contextlib, io, os, shutil, subprocess

    home = os.path.expanduser("~")
    herdr = shutil.which("herdr")
    if not herdr:
        fail("herdr is not on this device's PATH")
    try:
        listed = subprocess.run([herdr, "plugin", "list", "--json"], capture_output=True, text=True, timeout=10)
        plugins = json.loads(listed.stdout)["result"]["plugins"]
        root = next(plugin["plugin_root"] for plugin in plugins if plugin.get("plugin_id") == "wazum.grazr")
    except Exception:
        fail("grazr is not installed")

    state = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(home, ".local/state"), "herdr/plugins/wazum.grazr")
    config = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(home, ".config"), "herdr/plugins/config/wazum.grazr")
    os.environ.update({
        "HERDR_BIN_PATH": herdr,
        "HERDR_PLUGIN_ROOT": root,
        "HERDR_PLUGIN_CONFIG_DIR": config,
        "HERDR_PLUGIN_STATE_DIR": state,
    })
    os.chdir(root)
    sys.path.insert(0, root)
    import accounts, core, grazr
    """#
    #endif
}

/// What `Grazr.switchCommand` printed: whether Claude moved, and grazr's say.
public struct GrazrSwitchResult: Decodable, Sendable, Equatable {
    public let ok: Bool
    public let output: String

    public init(ok: Bool, output: String) {
        self.ok = ok
        self.output = output
    }

    /// grazr's verdict ("Rotated a -> b", "grazr: Busy rotating already, …")
    /// is its last line.
    public var summary: String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}

public struct GrazrReport: Decodable, Sendable, Equatable {
    public let installed: Bool
    public let active: String?
    public let accounts: [GrazrAccount]
    /// `ACCOUNTS` in config.env: the order grazr tries them in.
    public let order: [String]
    public let settings: [String: String]
    public let blocked: [String: GrazrBlock]

    public init(
        installed: Bool = true,
        active: String? = nil,
        accounts: [GrazrAccount] = [],
        order: [String] = [],
        settings: [String: String] = [:],
        blocked: [String: GrazrBlock] = [:]
    ) {
        self.installed = installed
        self.active = active
        self.accounts = accounts
        self.order = order
        self.settings = settings
        self.blocked = blocked
    }

    /// grazr's own defaults when config.env does not say.
    public var sessionThreshold: Int { settings["REMAINING_SESSION"].flatMap(Int.init) ?? 15 }
    public var weeklyThreshold: Int { settings["REMAINING_WEEKLY"].flatMap(Int.init) ?? 20 }
    public var enabled: Bool { settings["ENABLED"] != "0" }
    public var dryRun: Bool { settings["DRY_RUN"] == "1" }

    /// The active account first, then `ACCOUNTS` order, then any enrolled
    /// account the config leaves out.
    public var sortedAccounts: [GrazrAccount] {
        accounts.sorted { lhs, rhs in
            func rank(_ account: GrazrAccount) -> (Int, Int, String) {
                let listed = order.firstIndex(of: account.name) ?? order.count
                return (account.id == active ? 0 : 1, listed, account.name)
            }
            return rank(lhs) < rank(rhs)
        }
    }

    public func isListed(_ account: GrazrAccount) -> Bool { order.contains(account.name) }

    /// A block with a lapsed `until` no longer applies.
    public func block(for account: GrazrAccount, now: Date) -> GrazrBlock? {
        guard let block = blocked[account.id] else { return nil }
        if let until = block.until, until <= now.timeIntervalSince1970 { return nil }
        return block
    }

    /// Any enrolled account but the active one, unless grazr has blocked it:
    /// a failed login or a hard limit would leave Claude unable to answer.
    public func canSwitch(to account: GrazrAccount, now: Date) -> Bool {
        account.id != active && block(for: account, now: now) == nil
    }

    /// A block with no end (a refused login, say) lifts only when the account
    /// is enrolled again; one that ends (a rate limit) lifts on its own.
    public func needsSignIn(_ account: GrazrAccount, now: Date) -> Bool {
        guard let block = block(for: account, now: now) else { return false }
        return block.until == nil
    }

    public func threshold(for window: GrazrWindow) -> Int? {
        switch window.group {
        case "session": return sessionThreshold
        case "weekly": return weeklyThreshold
        default: return nil
        }
    }
}

public struct GrazrAccount: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let organization: String?
    public let windows: [GrazrWindow]
    /// When grazr last wrote this account's reading (unix seconds).
    public let updated: Double?

    public init(id: String, name: String, organization: String? = nil, windows: [GrazrWindow] = [], updated: Double? = nil) {
        self.id = id
        self.name = name
        self.organization = organization
        self.windows = windows
        self.updated = updated
    }

    /// Session first, then the all-models week, then per-model weeks.
    public var sortedWindows: [GrazrWindow] {
        windows.sorted { lhs, rhs in
            func rank(_ window: GrazrWindow) -> Int {
                switch (window.group, window.scope) {
                case ("session", _): return 0
                case ("weekly", nil): return 1
                default: return 2
                }
            }
            return (rank(lhs), lhs.scope ?? "") < (rank(rhs), rhs.scope ?? "")
        }
    }

    /// The tightest window still open: how close the account is to the wall.
    public func leastLeft(now: Date) -> Int? {
        windows.filter { $0.isOpen(now: now) }.map(\.remaining).min()
    }
}

public struct GrazrWindow: Decodable, Sendable, Equatable {
    public let kind: String
    /// A model name for a per-model weekly limit ("Fable"), nil otherwise.
    public let scope: String?
    public let group: String
    /// Percent left, as Claude reported it.
    public let remaining: Int
    public let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case kind, scope, group, remaining
        case resetsAt = "resets_at"
    }

    public init(kind: String, scope: String? = nil, group: String, remaining: Int, resetsAt: Date?) {
        self.kind = kind
        self.scope = scope
        self.group = group
        self.remaining = remaining
        self.resetsAt = resetsAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        group = try container.decode(String.self, forKey: .group)
        remaining = try container.decode(Int.self, forKey: .remaining)
        resetsAt = try container.decodeIfPresent(Double.self, forKey: .resetsAt)
            .map(Date.init(timeIntervalSince1970:))
    }

    /// A window past its reset has refilled, whatever the last reading said.
    public func isOpen(now: Date) -> Bool {
        resetsAt.map { $0 > now } ?? true
    }

    /// What is left right now: the reading inside the window, all of it after.
    public func left(now: Date) -> Int {
        isOpen(now: now) ? remaining : 100
    }

    public var label: String {
        switch (group, scope) {
        case ("session", _): return "5h"
        case ("weekly", nil): return "Week"
        case (_, let scope?): return "\(scope) week"
        default: return group
        }
    }
}

public struct GrazrBlock: Decodable, Sendable, Equatable {
    public let reason: String
    public let until: Double?

    public init(reason: String, until: Double? = nil) {
        self.reason = reason
        self.until = until
    }
}
