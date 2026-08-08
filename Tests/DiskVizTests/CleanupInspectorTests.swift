@testable import DiskViz
import XCTest

final class CleanupInspectorTests: XCTestCase {
    func testDockerInspectorParsesReportedSpaceAndNeverAddsVolumesToPrune() async throws {
        let usage = """
        {"Active":"0","Reclaimable":"23.68GB (100%)","Size":"23.68GB","TotalCount":"43","Type":"Images"}
        {"Active":"0","Reclaimable":"24.18MB (100%)","Size":"24.18MB","TotalCount":"1","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"512MB (100%)","Size":"512MB","TotalCount":"2","Type":"Build Cache"}
        """
        let runner = RecordingCommandRunner { arguments in
            if arguments == ["system", "df", "--format", "json"] {
                return commandResult(arguments: arguments, stdout: usage)
            }
            return commandResult(arguments: arguments)
        }
        let inspector = DockerInspector(
            runner: runner,
            executablePath: "/usr/bin/true",
            homePath: "/path/that/does/not/exist"
        )

        let inspectedUsage = try await inspector.inspect()
        let estimate = try XCTUnwrap(inspectedUsage)
        XCTAssertEqual(estimate.reclaimableBytes, 23_680_000_000 + 512_000_000)
        XCTAssertEqual(estimate.reclaimableObjectCount, 45)

        try await inspector.executePrune()
        let calls = await runner.recordedArguments()
        XCTAssertTrue(calls.contains(["system", "prune", "-a", "--force"]))
        XCTAssertFalse(calls.flatMap { $0 }.contains("--volumes"))
    }

    func testSimulatorInspectorMeasuresUnavailableDevicesAndUsesExactDeleteCommand() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("DiskVizSimulators-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("A"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("B"), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let listJSON = """
        {"devices":{"runtime":[
          {"name":"Old Phone","udid":"A","isAvailable":false},
          {"name":"Old Watch","udid":"B","isAvailable":false}
        ]}}
        """
        let runner = RecordingCommandRunner { arguments in
            if arguments == ["simctl", "list", "devices", "unavailable", "-j"] {
                return commandResult(arguments: arguments, stdout: listJSON)
            }
            if arguments.first == "-skx" {
                return commandResult(arguments: arguments, stdout: "100\tA\n250\tB\n")
            }
            return commandResult(arguments: arguments)
        }
        let inspector = SimulatorInspector(
            runner: runner,
            xcrunPath: "/usr/bin/true",
            duPath: "/usr/bin/true",
            devicesPath: root.path
        )

        let inspectedUsage = try await inspector.inspect()
        let estimate = try XCTUnwrap(inspectedUsage)
        XCTAssertEqual(estimate.unavailableDeviceCount, 2)
        XCTAssertEqual(estimate.allocatedBytes, 350 * 1_024)

        try await inspector.executeDeleteUnavailable()
        let calls = await runner.recordedArguments()
        XCTAssertTrue(calls.contains(["simctl", "delete", "unavailable"]))
    }
}

private actor RecordingCommandRunner: CommandRunning {
    typealias Handler = @Sendable ([String]) -> CommandResult

    private let handler: Handler
    private var calls: [[String]] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        outputLimit: Int
    ) async throws -> CommandResult {
        calls.append(arguments)
        return handler(arguments)
    }

    func recordedArguments() -> [[String]] {
        calls
    }
}

private func commandResult(arguments: [String], stdout: String = "") -> CommandResult {
    CommandResult(
        executable: "/usr/bin/true",
        arguments: arguments,
        exitCode: 0,
        stdout: Data(stdout.utf8),
        stderr: Data(),
        timedOut: false
    )
}
