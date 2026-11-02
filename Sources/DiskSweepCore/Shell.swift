import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public var succeeded: Bool { status == 0 && !timedOut }

    /// Last non-empty line of stderr (or stdout), useful as a short error message.
    public var lastMessageLine: String {
        let text = stderr.isEmpty ? stdout : stderr
        return text.split(whereSeparator: \.isNewline).last.map(String.init) ?? "Bilinmeyen hata"
    }
}

private final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

public enum Shell {
    private static var searchPath: String {
        let extra = [
            "/usr/local/bin", "/opt/homebrew/bin",
            NSHomeDirectory() + "/.docker/bin",
            "/Applications/Docker.app/Contents/Resources/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return (extra + [existing]).joined(separator: ":")
    }

    public static func run(executable: String, arguments: [String], timeout: TimeInterval = 60) async -> ShellResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = searchPath
            process.environment = environment

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = FileHandle.nullDevice

            let outBuffer = LockedBuffer()
            let errBuffer = LockedBuffer()
            let timedOut = LockedBuffer() // non-empty == timed out

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { outBuffer.append(chunk) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { errBuffer.append(chunk) }
            }

            process.terminationHandler = { finished in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? outPipe.fileHandleForReading.readToEnd() { outBuffer.append(rest) }
                if let rest = try? errPipe.fileHandleForReading.readToEnd() { errBuffer.append(rest) }
                continuation.resume(returning: ShellResult(
                    status: finished.terminationStatus,
                    stdout: outBuffer.string,
                    stderr: errBuffer.string,
                    timedOut: !timedOut.string.isEmpty
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: ShellResult(status: -1, stdout: "", stderr: "\(error)", timedOut: false))
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    timedOut.append(Data("x".utf8))
                    process.terminate()
                }
            }
        }
    }

    /// Runs one of the fixed command lines from `SafeCommand` (or a read-only probe).
    public static func shell(_ line: String, userShell: Bool = false, timeout: TimeInterval = 60) async -> ShellResult {
        await run(executable: "/bin/zsh", arguments: [userShell ? "-ilc" : "-c", line], timeout: timeout)
    }
}
