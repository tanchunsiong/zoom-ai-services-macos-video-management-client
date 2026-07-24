import Foundation

public struct ProcessFailure: LocalizedError {
    public let executable: String
    public let status: Int32
    public let output: String

    public var errorDescription: String? {
        let useful = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").suffix(8).joined(separator: "\n")
        return "\(URL(fileURLWithPath: executable).lastPathComponent) exited with status \(status)." +
            (useful.isEmpty ? "" : " \(useful)")
    }
}

public enum ProcessRunner {
    public static func run(_ executable: String, arguments: [String]) async throws -> String {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let pipe = Pipe()
                let buffer = OutputBuffer()
                let resolved = resolve(executable)
                process.executableURL = URL(fileURLWithPath: resolved)
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = pipe
                box.set(process)

                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if !data.isEmpty { buffer.append(data) }
                }

                process.terminationHandler = { process in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
                    let output = String(decoding: buffer.data, as: UTF8.self)
                    if box.isCanceled {
                        continuation.resume(throwing: CancellationError())
                    } else if process.terminationStatus == 0 {
                        continuation.resume(returning: output)
                    } else {
                        continuation.resume(throwing: ProcessFailure(
                            executable: resolved,
                            status: process.terminationStatus,
                            output: output
                        ))
                    }
                }

                do {
                    try process.run()
                    box.terminateIfCanceled()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    private static func resolve(_ executable: String) -> String {
        if executable.contains("/") { return executable }
        let candidates = [
            "/opt/homebrew/bin/\(executable)",
            "/usr/local/bin/\(executable)",
            "/usr/bin/\(executable)"
        ]
        return candidates.first(where: FileManager.default.isExecutableFile) ?? executable
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var canceled = false

    var isCanceled: Bool {
        lock.withLock { canceled }
    }

    func set(_ process: Process) {
        lock.withLock { self.process = process }
    }

    func cancel() {
        let process = lock.withLock {
            canceled = true
            return self.process
        }
        if process?.isRunning == true { process?.terminate() }
    }

    func terminateIfCanceled() {
        if isCanceled, process?.isRunning == true { process?.terminate() }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    var data: Data { lock.withLock { value } }
    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock { value.append(data) }
    }
}
