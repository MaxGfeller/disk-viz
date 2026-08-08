import Foundation

struct DockerUsageEstimate: Equatable, Sendable {
    var reclaimableBytes: Int64
    var reclaimableObjectCount: Int
    var diskImageAllocatedBytes: Int64?
    var diskImagePath: String?
}

protocol DockerInspecting: Sendable {
    func inspect() async throws -> DockerUsageEstimate?
    func executePrune() async throws
}

struct DockerInspector: DockerInspecting {
    private let runner: any CommandRunning
    private let executablePath: String?
    private let homePath: String

    init(
        runner: any CommandRunning = ProcessCommandRunner(),
        executablePath: String? = nil,
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.runner = runner
        self.executablePath = executablePath
        self.homePath = homePath
    }

    func inspect() async throws -> DockerUsageEstimate? {
        guard let executable = resolvedExecutablePath else { return nil }

        let result = try await runner.run(
            executable: executable,
            arguments: ["system", "df", "--format", "json"],
            timeout: 12,
            outputLimit: 2 * 1024 * 1024
        )
        guard !result.timedOut, result.exitCode == 0 else { return nil }

        let rows = Self.parseDiskUsage(result.stdoutString)
        guard !rows.isEmpty else { return nil }

        let reclaimableRows = rows.filter { row in
            row.type != "Local Volumes" && row.reclaimableBytes > 0
        }
        let reclaimableBytes = reclaimableRows.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
        let reclaimableObjectCount = reclaimableRows.reduce(0) { partial, row in
            partial + max(0, row.totalCount - row.activeCount)
        }
        let diskImage = dockerDiskImage()

        return DockerUsageEstimate(
            reclaimableBytes: reclaimableBytes,
            reclaimableObjectCount: reclaimableObjectCount,
            diskImageAllocatedBytes: diskImage?.bytes,
            diskImagePath: diskImage?.path
        )
    }

    func executePrune() async throws {
        guard let executable = resolvedExecutablePath else {
            throw DockerInspectorError.notInstalled
        }

        let result = try await runner.run(
            executable: executable,
            arguments: ["system", "prune", "-a", "--force"],
            timeout: 30 * 60,
            outputLimit: 8 * 1024 * 1024
        )
        guard !result.timedOut else {
            throw DockerInspectorError.timedOut
        }
        guard result.exitCode == 0 else {
            throw DockerInspectorError.commandFailed(result.stderrString)
        }
    }

    static func parseDiskUsage(_ output: String) -> [DockerDiskUsageRow] {
        output
            .split(whereSeparator: { $0.isNewline })
            .compactMap { line in
                guard let data = String(line).data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(DockerDiskUsageJSON.self, from: data)
                else {
                    return nil
                }

                return DockerDiskUsageRow(
                    type: decoded.type,
                    totalCount: Int(decoded.totalCount) ?? 0,
                    activeCount: Int(decoded.active) ?? 0,
                    reclaimableBytes: parseDockerByteCount(decoded.reclaimable)
                )
            }
    }

    private var resolvedExecutablePath: String? {
        if let executablePath,
           FileManager.default.isExecutableFile(atPath: executablePath) {
            return executablePath
        }

        return [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker"
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func dockerDiskImage() -> (path: String, bytes: Int64)? {
        let candidates = [
            "\(homePath)/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
            "\(homePath)/.docker/desktop/vms/0/data/Docker.raw"
        ]
        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey
        ]

        for path in candidates where FileManager.default.fileExists(atPath: path) {
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys)
            let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize
            if let size {
                return (path, Int64(max(0, size)))
            }
        }
        return nil
    }
}

struct DockerDiskUsageRow: Equatable, Sendable {
    var type: String
    var totalCount: Int
    var activeCount: Int
    var reclaimableBytes: Int64
}

enum DockerInspectorError: LocalizedError {
    case notInstalled
    case timedOut
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Docker is not installed."
        case .timedOut:
            return "Docker cleanup timed out."
        case .commandFailed(let detail):
            return detail.isEmpty ? "Docker cleanup failed." : detail
        }
    }
}

private struct DockerDiskUsageJSON: Decodable {
    let active: String
    let reclaimable: String
    let totalCount: String
    let type: String

    enum CodingKeys: String, CodingKey {
        case active = "Active"
        case reclaimable = "Reclaimable"
        case totalCount = "TotalCount"
        case type = "Type"
    }
}

private func parseDockerByteCount(_ input: String) -> Int64 {
    let amount = input.split(separator: " ", maxSplits: 1).first.map(String.init) ?? input
    let pattern = #"^([0-9]+(?:\.[0-9]+)?)([A-Za-z]+)$"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(
            in: amount,
            range: NSRange(amount.startIndex..., in: amount)
          ),
          let numberRange = Range(match.range(at: 1), in: amount),
          let unitRange = Range(match.range(at: 2), in: amount),
          let number = Double(amount[numberRange])
    else {
        return 0
    }

    let unit = amount[unitRange].uppercased()
    let multiplier: Double
    switch unit {
    case "B": multiplier = 1
    case "KB": multiplier = 1_000
    case "MB": multiplier = 1_000_000
    case "GB": multiplier = 1_000_000_000
    case "TB": multiplier = 1_000_000_000_000
    case "KIB": multiplier = 1_024
    case "MIB": multiplier = 1_048_576
    case "GIB": multiplier = 1_073_741_824
    case "TIB": multiplier = 1_099_511_627_776
    default: return 0
    }

    return Int64((number * multiplier).rounded())
}
