#if os(macOS)
import Foundation

/// Streams `MachineSample`s from one long-lived sampler process: `/bin/sh` for
/// the Local device, a single `ssh` command for a remote one. Cancelling the
/// consuming task terminates the process.
public enum MachineStatsStream {
    /// The sampler is POSIX sh; Windows hosts and tailcat devices (no shell
    /// access) get no machine stats.
    public static func isSupported(_ device: Device) -> Bool {
        if device.isTailcat { return false }
        return device.osID?.lowercased() != "windows"
    }

    public static func samples(
        device: Device,
        interval: Int = 2,
        frames: Int = 0
    ) -> AsyncThrowingStream<MachineSample, Error> {
        stream(device: device, interval: interval, frames: frames) { $0 }
    }

    /// Ready-to-render snapshots, diffed off the main thread. The first one has
    /// no CPU figures; they need a second frame.
    public static func snapshots(
        device: Device,
        interval: Int = 2
    ) -> AsyncThrowingStream<MachineSnapshot, Error> {
        // Frames arrive one at a time on the pipe's reading queue, so `previous`
        // is never touched concurrently.
        final class Previous: @unchecked Sendable { var sample: MachineSample? }
        let previous = Previous()
        return stream(device: device, interval: interval, frames: 0) { sample in
            defer { previous.sample = sample }
            return MachineStatsComputer.snapshot(previous: previous.sample, current: sample)
        }
    }

    private static func stream<Element: Sendable>(
        device: Device,
        interval: Int,
        frames: Int,
        transform: @escaping @Sendable (MachineSample) -> Element
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            var authentication: SSHAuthenticationConfiguration?
            if let target = device.sshTarget {
                let auth = SSHTunnel.authenticationConfiguration(for: device.id)
                authentication = auth
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = ["-T"] + auth.arguments + [
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=10",
                    "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=3",
                    "-o", "LogLevel=ERROR",
                    SSHTunnel.sshDestination(target),
                    MachineStatsScript.remoteCommand(interval: interval, frames: frames),
                ]
                process.environment = ProcessInfo.processInfo.environment
                    .merging(auth.environment) { _, new in new }
            } else {
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = MachineStatsScript.shellArguments(interval: interval, frames: frames)
            }

            let reader = MachineFrameReader(authentication: authentication) { sample in
                continuation.yield(transform(sample))
            }
            let output = Pipe()
            let errors = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = errors
            // Finish once stdout hit EOF (every frame is in) and the process exited.
            let done = DispatchGroup()
            done.enter()
            done.enter()
            // Both handlers uninstall themselves at EOF: a dead pipe stays
            // readable forever and would otherwise be polled in a hot loop.
            output.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    done.leave()
                    return
                }
                reader.consume(chunk)
            }
            errors.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                reader.consumeError(chunk)
            }
            process.terminationHandler = { _ in done.leave() }
            done.notify(queue: .global(qos: .utility)) {
                errors.fileHandleForReading.readabilityHandler = nil
                reader.finish()
                let status = process.terminationStatus
                if status == 0 {
                    continuation.finish()
                } else {
                    let detail = reader.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.finish(throwing: HerdrError.tunnelFailed(
                        detail.isEmpty ? "stats sampler exited \(status)" : String(detail.suffix(500))
                    ))
                }
            }
            // Stdout is left to reach EOF on its own so the group above always
            // completes; ssh closes it as soon as it exits.
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
            } catch {
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                reader.finish()
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Splits sampler stdout into frames and parses them. Called from Foundation's
/// pipe-reading queue, hence the lock.
final class MachineFrameReader: @unchecked Sendable {
    /// A frame is ~25 KB on a busy Linux host and ~70 KB on a Mac with 1500
    /// processes; anything far past that is not a sampler talking.
    static let bufferLimit = 4 * 1024 * 1024

    private let lock = NSLock()
    private var buffer = Data()
    private var errorData = Data()
    private var authentication: SSHAuthenticationConfiguration?
    private let onSample: (MachineSample) -> Void
    private static let marker = Data((MachineStatsParser.frameEnd + "\n").utf8)

    init(authentication: SSHAuthenticationConfiguration?, onSample: @escaping (MachineSample) -> Void) {
        self.authentication = authentication
        self.onSample = onSample
    }

    func consume(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        var frames: [String] = []
        lock.lock()
        buffer.append(chunk)
        while let range = buffer.range(of: Self.marker) {
            frames.append(String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        }
        if buffer.count > Self.bufferLimit { buffer.removeAll() }
        lock.unlock()

        for frame in frames {
            // A first frame means ssh authenticated; the one-shot askpass grant is spent.
            discardAuthorization()
            if let sample = MachineStatsParser.parse(frame, receivedAt: ProcessInfo.processInfo.systemUptime) {
                onSample(sample)
            }
        }
    }

    func consumeError(_ chunk: Data) {
        lock.lock()
        errorData.append(chunk)
        if errorData.count > 16_384 { errorData = errorData.suffix(16_384) }
        lock.unlock()
    }

    var errorText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: errorData, as: UTF8.self)
    }

    func finish() {
        discardAuthorization()
    }

    private func discardAuthorization() {
        lock.lock()
        let auth = authentication
        authentication = nil
        lock.unlock()
        auth?.discardAuthorization()
    }
}
#endif
