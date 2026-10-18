import XCTest
@testable import HerdrKit

final class ProjectProbeScriptTests: XCTestCase {
    func testScriptIsValidPOSIXShell() throws {
        let process = Process()
        // dash is the strictest POSIX sh a Linux host will run; use it where this Mac has it.
        let shell = FileManager.default.isExecutableFile(atPath: "/bin/dash") ? "/bin/dash" : "/bin/sh"
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-n"]
        let input = Pipe()
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(ProjectProbeScript.source.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testLocalRunPrintsEveryRequestedSectionAndEndsTheFrame() async throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("pp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: raw) }
        // git reports the physical path (/private/var/…), so hand the probe that one.
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let tmp = realpath(raw.path, &buffer) != nil ? String(cString: buffer) : raw.path
        try Self.sh("git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && echo '{}' > package.json && printf 'API_PORT=8100\\nDB_PASSWORD=x\\n' > .env", in: tmp)

        let sections = ["tools", "host", "roots", "listeners", "files", "env", "vms"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ProjectProbeScript.shellArguments(sections: sections, cwds: [tmp])
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(process.terminationStatus, 0)
        for needle in ["@@pp-begin 1", "@@tools", "@@host", "os Darwin", "@@roots", "\t\(tmp)", "@@listeners lsof", "@@files ", "@@env ", "API_PORT=8100"] {
            XCTAssertTrue(text.contains(needle), "missing \(needle) in:\n\(text)")
        }
        XCTAssertFalse(text.contains("DB_PASSWORD"))
        // Darwin boottime is the epoch second, not the microseconds after it.
        let boot = text.split(separator: "\n").first { $0.hasPrefix("boottime ") }.flatMap { Double($0.dropFirst(9)) }
        XCTAssertGreaterThan(boot ?? 0, 1_000_000_000)
        XCTAssertTrue(text.contains("@@vms parallels") || text.contains("@@absent prlctl"))
        XCTAssertTrue(text.hasSuffix("@@pp-end\n"), "tail: \(text.suffix(80))")

        // The parser reads the real output back.
        let probe = ProjectProbeParser.parse(text)
        XCTAssertFalse(probe.partial)
        XCTAssertEqual(probe.roots.first?.toplevel, tmp)
        XCTAssertTrue(probe.files[tmp]?.contains { $0.hasSuffix("package.json") } == true)
        XCTAssertEqual(probe.envEntries.map(\.key), ["API_PORT"])
    }

    func testLocalRunPidsAndDockerSectionsParseWithoutADaemon() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ProjectProbeScript.shellArguments(sections: ["listeners", "pids", "compose", "containers", "units"], cwds: [])
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let probe = ProjectProbeParser.parse(text)
        XCTAssertFalse(probe.partial)
        // Every listener the lsof pass saw has a process entry, and no entry lost its command name.
        for pid in Set(probe.listeners.flatMap(\.pids)) {
            XCTAssertNotNil(probe.processes[pid], "no process for listener pid \(pid)")
        }
        XCTAssertFalse(probe.processes.values.contains { $0.comm.isEmpty })
        XCTAssertNil(probe.errors["lsofp"])
        XCTAssertNil(probe.errors["listeners"])
    }

    func testRemoteCommandQuotesEverything() {
        let command = ProjectProbeScript.remoteCommand(sections: ["host"], cwds: ["/home/dev/it's here"])
        XCTAssertTrue(command.hasPrefix("exec /bin/sh -c '"))
        XCTAssertTrue(command.contains("'/home/dev/it'\\''s here'"))
    }

    func testIsSupportedMirrorsMachineStats() {
        XCTAssertTrue(ProjectProbeScript.isSupported(.local))
        XCTAssertFalse(ProjectProbeScript.isSupported(Device(name: "t", kind: .tailcat)))
        XCTAssertFalse(ProjectProbeScript.isSupported(Device(name: "w", kind: .ssh(target: "u@w"), osID: "windows")))
        XCTAssertTrue(ProjectProbeScript.isSupported(Device(name: "l", kind: .ssh(target: "u@l"), osID: "ubuntu")))
    }

    private static func sh(_ command: String, in dir: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        process.standardOutput = Pipe()
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, command)
    }
}
