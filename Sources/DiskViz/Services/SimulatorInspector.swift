import Foundation

struct SimulatorUsageEstimate: Equatable, Sendable {
    var unavailableDeviceCount: Int
    var allocatedBytes: Int64
    var isSizePartial = false
}

struct OutdatedSimulatorRuntimeEstimate: Equatable, Sendable {
    var runtimeCount: Int
    var allocatedBytes: Int64
    var isSizePartial = false
}

protocol SimulatorInspecting: Sendable {
    func inspect() async throws -> SimulatorUsageEstimate?
    func inspectOutdatedRuntimes() async throws -> OutdatedSimulatorRuntimeEstimate?
    func executeDeleteUnavailable() async throws
    func executeDeleteOutdatedRuntimes() async throws
}

struct SimulatorInspector: SimulatorInspecting {
    private let runner: any CommandRunning
    private let xcrunPath: String
    private let duPath: String
    private let devicesPath: String

    init(
        runner: any CommandRunning = ProcessCommandRunner(),
        xcrunPath: String = "/usr/bin/xcrun",
        duPath: String = "/usr/bin/du",
        devicesPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
            .path
    ) {
        self.runner = runner
        self.xcrunPath = xcrunPath
        self.duPath = duPath
        self.devicesPath = devicesPath
    }

    func inspect() async throws -> SimulatorUsageEstimate? {
        guard FileManager.default.isExecutableFile(atPath: xcrunPath) else { return nil }

        let listResult = try await runner.run(
            executable: xcrunPath,
            arguments: ["simctl", "list", "devices", "unavailable", "-j"],
            timeout: 20,
            outputLimit: 8 * 1024 * 1024
        )
        guard !listResult.timedOut, listResult.exitCode == 0 else { return nil }

        let devices = Self.parseUnavailableDevices(listResult.stdout)
        guard !devices.isEmpty else {
            return SimulatorUsageEstimate(unavailableDeviceCount: 0, allocatedBytes: 0)
        }

        let paths = devices.map { device in
            URL(fileURLWithPath: devicesPath, isDirectory: true)
                .appendingPathComponent(device.udid, isDirectory: true)
                .path
        }.filter { FileManager.default.fileExists(atPath: $0) }

        guard !paths.isEmpty else {
            return SimulatorUsageEstimate(
                unavailableDeviceCount: devices.count,
                allocatedBytes: 0,
                isSizePartial: false
            )
        }

        let sizeResult = try await runner.run(
            executable: duPath,
            arguments: ["-skx"] + paths,
            timeout: 60,
            outputLimit: 4 * 1024 * 1024
        )
        guard !sizeResult.timedOut, sizeResult.exitCode == 0 else {
            return SimulatorUsageEstimate(
                unavailableDeviceCount: devices.count,
                allocatedBytes: 0,
                isSizePartial: true
            )
        }
        let allocatedBytes = Self.parseDiskUsageKilobytes(sizeResult.stdoutString) * 1_024

        return SimulatorUsageEstimate(
            unavailableDeviceCount: devices.count,
            allocatedBytes: allocatedBytes,
            isSizePartial: false
        )
    }

    func executeDeleteUnavailable() async throws {
        guard FileManager.default.isExecutableFile(atPath: xcrunPath) else {
            throw SimulatorInspectorError.xcodeToolsUnavailable
        }

        let result = try await runner.run(
            executable: xcrunPath,
            arguments: ["simctl", "delete", "unavailable"],
            timeout: 15 * 60,
            outputLimit: 8 * 1024 * 1024
        )
        guard !result.timedOut else {
            throw SimulatorInspectorError.timedOut
        }
        guard result.exitCode == 0 else {
            throw SimulatorInspectorError.commandFailed(result.stderrString)
        }
    }

    func inspectOutdatedRuntimes() async throws -> OutdatedSimulatorRuntimeEstimate? {
        guard FileManager.default.isExecutableFile(atPath: xcrunPath) else { return nil }

        let dryRun = try await runner.run(
            executable: xcrunPath,
            arguments: ["simctl", "runtime", "delete", "--outdated", "--dry-run"],
            timeout: 30,
            outputLimit: 2 * 1024 * 1024
        )
        guard !dryRun.timedOut, dryRun.exitCode == 0 else { return nil }

        let identifiers = Self.parseOutdatedRuntimeIdentifiers(
            dryRun.stdoutString + "\n" + dryRun.stderrString
        )
        guard !identifiers.isEmpty else {
            return OutdatedSimulatorRuntimeEstimate(runtimeCount: 0, allocatedBytes: 0)
        }

        let listResult = try await runner.run(
            executable: xcrunPath,
            arguments: ["simctl", "runtime", "list", "-j"],
            timeout: 30,
            outputLimit: 8 * 1024 * 1024
        )
        guard !listResult.timedOut,
              listResult.exitCode == 0,
              let runtimes = try? JSONDecoder().decode(
                [String: SimulatorRuntimeJSON].self,
                from: listResult.stdout
              )
        else {
            return OutdatedSimulatorRuntimeEstimate(
                runtimeCount: identifiers.count,
                allocatedBytes: 0,
                isSizePartial: true
            )
        }

        var measuredCount = 0
        let allocatedBytes = identifiers.reduce(Int64(0)) { total, identifier in
            guard let size = runtimes[identifier]?.sizeBytes else { return total }
            measuredCount += 1
            return total + max(0, size)
        }
        return OutdatedSimulatorRuntimeEstimate(
            runtimeCount: identifiers.count,
            allocatedBytes: allocatedBytes,
            isSizePartial: measuredCount != identifiers.count
        )
    }

    func executeDeleteOutdatedRuntimes() async throws {
        guard FileManager.default.isExecutableFile(atPath: xcrunPath) else {
            throw SimulatorInspectorError.xcodeToolsUnavailable
        }

        let result = try await runner.run(
            executable: xcrunPath,
            arguments: ["simctl", "runtime", "delete", "--outdated"],
            timeout: 15 * 60,
            outputLimit: 8 * 1024 * 1024
        )
        guard !result.timedOut else {
            throw SimulatorInspectorError.timedOut
        }
        guard result.exitCode == 0 else {
            throw SimulatorInspectorError.commandFailed(result.stderrString)
        }
    }

    static func parseUnavailableDevices(_ data: Data) -> [SimulatorDevice] {
        guard let response = try? JSONDecoder().decode(SimulatorListResponse.self, from: data) else {
            return []
        }

        return response.devices.values
            .flatMap { $0 }
            .filter { $0.isAvailable != true }
            .sorted { lhs, rhs in
                if lhs.name != rhs.name {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.udid < rhs.udid
            }
            .map(SimulatorDevice.init)
    }

    static func parseDiskUsageKilobytes(_ output: String) -> Int64 {
        output.split(whereSeparator: { $0.isNewline }).reduce(Int64(0)) { partial, line in
            guard let firstColumn = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
                  let value = Int64(firstColumn)
            else {
                return partial
            }
            return partial + max(0, value)
        }
    }

    static func parseOutdatedRuntimeIdentifiers(_ output: String) -> Set<String> {
        Set(output.split(whereSeparator: \Character.isNewline).compactMap { line in
            guard line.hasPrefix("Would delete") else { return nil }
            return line.split(whereSeparator: \Character.isWhitespace)
                .map(String.init)
                .first { UUID(uuidString: $0) != nil }
                .map { $0.uppercased() }
        })
    }
}

struct SimulatorDevice: Equatable, Sendable {
    var name: String
    var udid: String
}

enum SimulatorInspectorError: LocalizedError {
    case xcodeToolsUnavailable
    case timedOut
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .xcodeToolsUnavailable:
            return "Xcode command-line tools are unavailable."
        case .timedOut:
            return "Simulator cleanup timed out."
        case .commandFailed(let detail):
            return detail.isEmpty ? "Simulator cleanup failed." : detail
        }
    }
}

private struct SimulatorListResponse: Decodable {
    var devices: [String: [SimulatorDeviceJSON]]
}

private struct SimulatorDeviceJSON: Decodable {
    var name: String
    var udid: String
    var isAvailable: Bool?
}

private struct SimulatorRuntimeJSON: Decodable {
    var sizeBytes: Int64?
}

private extension SimulatorDevice {
    init(_ json: SimulatorDeviceJSON) {
        self.init(name: json.name, udid: json.udid)
    }
}
