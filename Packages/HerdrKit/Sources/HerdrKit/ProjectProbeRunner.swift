import Foundation

/// Runs the project probe script on a device and returns its raw output frame(s).
public protocol ProjectProbeRunning: Sendable {
    func run(device: Device, sections: [String], cwds: [String]) async throws -> String
}

#if os(macOS)
/// The real runner: the same `exec /bin/sh -c '<script>' …` command line works under the local
/// `sh -c` and over plain `ssh`, so every device takes one path.
public struct DeviceProjectProbeRunner: ProjectProbeRunning {
    public init() {}

    /// Drops directories whose quoting a remote login shell could misread: a fish shell treats a
    /// backslash as an escape even inside single quotes. Such paths are not probed.
    public static func safeCwds(_ cwds: [String]) -> [String] {
        cwds.filter { cwd in
            !cwd.unicodeScalars.contains { $0 == "\\" || $0 == "'" || $0.value < 0x20 || $0.value == 0x7f }
        }
    }

    public func run(device: Device, sections: [String], cwds: [String]) async throws -> String {
        let command = ProjectProbeScript.remoteCommand(sections: sections, cwds: Self.safeCwds(cwds))
        let data = try await DeviceFileService(device: device).run(command, timeout: 20)
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
