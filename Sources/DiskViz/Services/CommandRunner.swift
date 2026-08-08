import Foundation
import Darwin

struct CommandResult: Equatable, Sendable {
    var executable: String
    var arguments: [String]
    var exitCode: Int32
    var stdout: Data
    var stderr: Data
    var timedOut: Bool

    var stdoutString: String {
        String(decoding: stdout, as: UTF8.self)
    }

    var stderrString: String {
        String(decoding: stderr, as: UTF8.self)
    }
}

protocol CommandRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        outputLimit: Int
    ) async throws -> CommandResult
}

struct ProcessCommandRunner: CommandRunning {
    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 15,
        outputLimit: Int = 4 * 1024 * 1024
    ) async throws -> CommandResult {
        let worker = Task.detached(priority: .utility) {
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            let output = LimitedCommandOutput(limit: outputLimit)
            let errorOutput = LimitedCommandOutput(limit: outputLimit)

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = standardOutput
            process.standardError = standardError

            standardOutput.fileHandleForReading.readabilityHandler = { handle in
                output.append(handle.availableData)
            }
            standardError.fileHandleForReading.readabilityHandler = { handle in
                errorOutput.append(handle.availableData)
            }

            defer {
                standardOutput.fileHandleForReading.readabilityHandler = nil
                standardError.fileHandleForReading.readabilityHandler = nil
            }

            try process.run()

            func stopProcess() async {
                guard process.isRunning else { return }
                process.terminate()
                let gracefulDeadline = Date().addingTimeInterval(0.4)
                while process.isRunning && Date() < gracefulDeadline {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    let killDeadline = Date().addingTimeInterval(0.4)
                    while process.isRunning && Date() < killDeadline {
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                }
            }

            let deadline = Date().addingTimeInterval(max(0.1, timeout))
            do {
                while process.isRunning && Date() < deadline {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
            } catch {
                await stopProcess()
                throw error
            }

            let timedOut = process.isRunning
            if timedOut {
                await stopProcess()
            }
            try? await Task.sleep(nanoseconds: 20_000_000)

            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: process.terminationStatus,
                stdout: output.data,
                stderr: errorOutput.data,
                timedOut: timedOut
            )
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

private final class LimitedCommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ incoming: Data) {
        guard !incoming.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        let remaining = max(0, limit - storage.count)
        if remaining > 0 {
            storage.append(incoming.prefix(remaining))
        }
    }
}
