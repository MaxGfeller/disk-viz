@testable import DiskViz
import XCTest

final class DiskScannerTests: XCTestCase {
    func testStreamingSnapshotsIncludeDirectoryBeforeTopLevelScanCompletes() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("DiskVizScanner-\(UUID().uuidString)", isDirectory: true)
        let nestedURL = rootURL
            .appendingPathComponent("Parent", isDirectory: true)
            .appendingPathComponent("Child", isDirectory: true)
            .appendingPathComponent("Grandchild", isDirectory: true)

        try fileManager.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096)
            .write(to: nestedURL.appendingPathComponent("payload.bin"))
        defer {
            try? fileManager.removeItem(at: rootURL)
        }

        let scanner = DiskScanner()
        var snapshots: [ScanSnapshot] = []

        _ = try await scanner.scanDirectoryStreaming(path: rootURL.path) { snapshot in
            snapshots.append(snapshot)
        }

        let earlySnapshots = snapshots.filter { snapshot in
            snapshot.progress.dirsCompleted < snapshot.progress.dirsFound
        }
        XCTAssertTrue(
            earlySnapshots.contains { snapshot in
                guard let parent = snapshot.root.children?.first(where: { $0.name == "Parent" }) else {
                    return false
                }

                return parent.size >= 4096
                    && parent.children?.first?.name == "Child"
            },
            "Expected an in-progress snapshot to include the active top-level directory."
        )

        XCTAssertTrue(
            earlySnapshots.contains { snapshot in
                guard let layout = TreemapLayoutEngine.layout(root: snapshot.root, width: 1000, height: 700) else {
                    return false
                }

                return layout.flattened.contains { node in
                    node.depth > 0 && node.rect.width > 0 && node.rect.height > 0
                }
            },
            "Expected an in-progress snapshot to produce visible treemap nodes."
        )
    }

    func testTruncatedDirectorySizeUsesNativeTraversal() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("DiskVizScanner-\(UUID().uuidString)", isDirectory: true)
        let nestedURL = rootURL
            .appendingPathComponent("Child", isDirectory: true)
            .appendingPathComponent("Grandchild", isDirectory: true)
        let payload = Data(repeating: 1, count: 4096)

        try fileManager.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        try payload.write(to: nestedURL.appendingPathComponent("payload.bin"))
        defer {
            try? fileManager.removeItem(at: rootURL)
        }

        let scanner = DiskScanner()
        let result = try await scanner.scanDirectoryStreaming(path: rootURL.path, maxDepth: 1) { _ in }
        let child = try XCTUnwrap(result.root.children?.first { $0.name == "Child" })

        XCTAssertTrue(child.truncated)
        XCTAssertNil(child.children)
        XCTAssertGreaterThanOrEqual(child.size, Int64(payload.count))
    }

    func testProgressCountsFilesAndDirectoriesInTruncatedTraversal() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("DiskVizScanner-\(UUID().uuidString)", isDirectory: true)
        let childURL = rootURL.appendingPathComponent("Child", isDirectory: true)
        let grandchildURL = childURL.appendingPathComponent("Grandchild", isDirectory: true)
        let rootPayload = Data(repeating: 1, count: 4096)
        let deepPayload = Data(repeating: 2, count: 32 * 1024)

        try fileManager.createDirectory(at: grandchildURL, withIntermediateDirectories: true)
        try rootPayload.write(to: rootURL.appendingPathComponent("root.bin"))
        try deepPayload.write(to: grandchildURL.appendingPathComponent("deep.bin"))
        defer {
            try? fileManager.removeItem(at: rootURL)
        }

        let scanner = DiskScanner(snapshotInterval: 0)
        var snapshots: [ScanSnapshot] = []
        let result = try await scanner.scanDirectoryStreaming(
            path: rootURL.path,
            maxDepth: 1
        ) { snapshot in
            snapshots.append(snapshot)
        }

        XCTAssertEqual(result.progress.dirsFound, 3)
        XCTAssertEqual(result.progress.dirsCompleted, 3)
        XCTAssertEqual(result.progress.filesFound, 2)
        XCTAssertGreaterThanOrEqual(
            result.progress.bytesFound,
            Int64(rootPayload.count + deepPayload.count)
        )
        XCTAssertEqual(result.progress.inaccessibleDirs, 0)
        XCTAssertNil(result.progress.currentPath)

        for (earlier, later) in zip(snapshots, snapshots.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.progress.dirsFound, later.progress.dirsFound)
            XCTAssertLessThanOrEqual(earlier.progress.dirsCompleted, later.progress.dirsCompleted)
            XCTAssertLessThanOrEqual(earlier.progress.filesFound, later.progress.filesFound)
            XCTAssertLessThanOrEqual(earlier.progress.bytesFound, later.progress.bytesFound)
            XCTAssertLessThanOrEqual(earlier.progress.inaccessibleDirs, later.progress.inaccessibleDirs)
        }
    }

    func testLargestFilesIncludeDeepFilesFromTruncatedTraversal() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("DiskVizScanner-\(UUID().uuidString)", isDirectory: true)
        let deepURL = rootURL
            .appendingPathComponent("Child", isDirectory: true)
            .appendingPathComponent("Grandchild", isDirectory: true)
        let smallURL = rootURL.appendingPathComponent("small.bin")
        let largeURL = deepURL.appendingPathComponent("large.dat")

        try fileManager.createDirectory(at: deepURL, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: smallURL)
        try Data(repeating: 2, count: 256 * 1024).write(to: largeURL)
        defer {
            try? fileManager.removeItem(at: rootURL)
        }

        let scanner = DiskScanner(snapshotInterval: 0)
        var snapshots: [ScanSnapshot] = []
        let result = try await scanner.scanDirectoryStreaming(
            path: rootURL.path,
            maxDepth: 1
        ) { snapshot in
            snapshots.append(snapshot)
        }

        XCTAssertTrue(result.largestFiles.first?.path.hasSuffix("/Child/Grandchild/large.dat") == true)
        XCTAssertEqual(result.largestFiles.first?.fileExtension, ".dat")
        XCTAssertTrue(
            snapshots.contains { snapshot in
                snapshot.progress.dirsCompleted < snapshot.progress.dirsFound
                    && snapshot.largestFiles.first?.path.hasSuffix("/Child/Grandchild/large.dat") == true
            },
            "Expected the tail traversal to stream its largest file before the whole scan completed."
        )
    }

    func testNestedVolumePolicySkipsMountedChildrenButAllowsSelectedRoot() {
        XCTAssertFalse(
            DiskScanner.shouldScanURL(
                isSymbolicLink: false,
                isVolume: true,
                isScanRoot: false
            )
        )
        XCTAssertTrue(
            DiskScanner.shouldScanURL(
                isSymbolicLink: false,
                isVolume: true,
                isScanRoot: true
            )
        )
        XCTAssertFalse(
            DiskScanner.shouldScanURL(
                isSymbolicLink: true,
                isVolume: false,
                isScanRoot: true
            )
        )
    }
}
