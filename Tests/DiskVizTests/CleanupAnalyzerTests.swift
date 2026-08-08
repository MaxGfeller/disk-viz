@testable import DiskViz
import XCTest

final class CleanupAnalyzerTests: XCTestCase {
    func testAnalyzerFindsOnlyReviewableOldAndRegeneratableCandidates() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("DiskVizCleanup-\(UUID().uuidString)", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let projects = home.appendingPathComponent("projects", isDirectory: true)
        let nodeProject = projects.appendingPathComponent("web", isDirectory: true)
        let nodeModules = nodeProject.appendingPathComponent("node_modules", isDirectory: true)
        let falseTarget = projects.appendingPathComponent("photos/target", isDirectory: true)
        let npmCache = home.appendingPathComponent(".npm", isDirectory: true)
        let derivedData = home.appendingPathComponent(
            "Library/Developer/Xcode/DerivedData/App-123",
            isDirectory: true
        )
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)

        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: falseTarget, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: npmCache, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: derivedData, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let oldDate = now.addingTimeInterval(-120 * 24 * 60 * 60)
        let oldDownload = downloads.appendingPathComponent("archive.zip")
        let recentDownload = downloads.appendingPathComponent("keep.txt")
        let oldDMG = downloads.appendingPathComponent("old-installer.dmg")

        try write(bytes: 4_096, to: oldDownload)
        try write(bytes: 4_096, to: recentDownload)
        try write(bytes: 4_096, to: oldDMG)
        try write(bytes: 32, to: nodeProject.appendingPathComponent("package.json"))
        try write(bytes: 8_192, to: nodeModules.appendingPathComponent("package.js"))
        try write(bytes: 8_192, to: falseTarget.appendingPathComponent("not-generated.bin"))
        try write(bytes: 8_192, to: npmCache.appendingPathComponent("cache.bin"))
        try write(bytes: 8_192, to: derivedData.appendingPathComponent("index.bin"))
        try write(bytes: 8_192, to: trash.appendingPathComponent("discarded.bin"))

        try setModificationDate(oldDate, at: oldDownload)
        try setModificationDate(oldDate, at: oldDMG)
        try setModificationDate(now, at: recentDownload)

        let roots = CleanupRoots(
            homePath: home.path,
            downloadsPath: downloads.path,
            developerSearchPaths: [projects.path],
            packageCachePaths: [npmCache.path],
            xcodeDerivedDataPath: derivedData.deletingLastPathComponent().path,
            trashPath: trash.path
        )
        let analyzer = CleanupAnalyzer(
            roots: roots,
            referenceDate: now,
            suppliedDownloadPaths: [oldDownload.path, recentDownload.path, oldDMG.path],
            suppliedDeveloperArtifactPaths: [nodeModules.path, falseTarget.path],
            suppliedDiskImagePaths: [oldDMG.path]
        )

        let suggestions = await analyzer.analyze()
        let byCategory = Dictionary(uniqueKeysWithValues: suggestions.map { ($0.category, $0) })

        let downloadSuggestion = try XCTUnwrap(byCategory[.oldDownloads])
        XCTAssertEqual(downloadSuggestion.candidates.map(\.path), [oldDownload.path])

        let imageSuggestion = try XCTUnwrap(byCategory[.oldDiskImages])
        XCTAssertEqual(imageSuggestion.candidates.map(\.path), [oldDMG.path])

        let artifactSuggestion = try XCTUnwrap(byCategory[.developerArtifacts])
        XCTAssertTrue(artifactSuggestion.candidates.contains { $0.path == nodeModules.path })
        XCTAssertTrue(artifactSuggestion.candidates.contains { $0.path == npmCache.path })
        XCTAssertFalse(artifactSuggestion.candidates.contains { $0.path == falseTarget.path })

        XCTAssertNotNil(byCategory[.xcodeDerivedData])
        XCTAssertNotNil(byCategory[.trash])
    }

    func testSlowDownloadsEnumerationIsBoundedAndReportedAsPartial() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("DiskVizCleanupTimeout-\(UUID().uuidString)", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        let runner = TimedOutFindRunner()
        let roots = CleanupRoots(
            homePath: home.path,
            downloadsPath: downloads.path,
            developerSearchPaths: [],
            packageCachePaths: [],
            xcodeDerivedDataPath: home.appendingPathComponent("DerivedData").path,
            trashPath: home.appendingPathComponent(".Trash").path
        )
        let analyzer = CleanupAnalyzer(
            roots: roots,
            commandRunner: runner,
            suppliedDiskImagePaths: []
        )

        let suggestions = await analyzer.analyze()
        let downloadsSuggestion = try XCTUnwrap(
            suggestions.first(where: { $0.category == .oldDownloads })
        )
        XCTAssertTrue(downloadsSuggestion.isPartial)
        XCTAssertEqual(downloadsSuggestion.estimatedBytes, 0)
        XCTAssertTrue(downloadsSuggestion.candidates.isEmpty)
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls, [[
            "-x",
            downloads.path,
            "-mindepth", "1",
            "-maxdepth", "1",
            "-print0"
        ]])
    }

    private func write(bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    private func setModificationDate(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }
}

private actor TimedOutFindRunner: CommandRunning {
    private var calls: [[String]] = []

    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        outputLimit: Int
    ) async throws -> CommandResult {
        calls.append(arguments)
        return CommandResult(
            executable: executable,
            arguments: arguments,
            exitCode: -1,
            stdout: Data(),
            stderr: Data(),
            timedOut: true
        )
    }

    func recordedCalls() -> [[String]] {
        calls
    }
}
