import Foundation

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
        try await Task.detached(priority: .utility) {
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

            let deadline = Date().addingTimeInterval(max(0.1, timeout))
            while process.isRunning && Date() < deadline {
                if Task.isCancelled {
                    process.terminate()
                    process.waitUntilExit()
                    throw CancellationError()
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }

            let timedOut = process.isRunning
            if timedOut {
                process.terminate()
            }
            process.waitUntilExit()

            output.append(standardOutput.fileHandleForReading.availableData)
            errorOutput.append(standardError.fileHandleForReading.availableData)

            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: process.terminationStatus,
                stdout: output.data,
                stderr: errorOutput.data,
                timedOut: timedOut
            )
        }.value
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
