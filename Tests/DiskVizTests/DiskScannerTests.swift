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
        var snapshots: [(tree: DiskNode, progress: ScanProgress)] = []

        _ = try await scanner.scanDirectoryStreaming(path: rootURL.path) { tree, progress in
            snapshots.append((tree, progress))
        }

        let earlySnapshots = snapshots.filter { $0.progress.dirsCompleted == 0 }
        XCTAssertTrue(
            earlySnapshots.contains { snapshot in
                guard let parent = snapshot.tree.children?.first(where: { $0.name == "Parent" }) else {
                    return false
                }

                return parent.size >= 4096
                    && parent.children?.first?.name == "Child"
            },
            "Expected an in-progress snapshot to include the active top-level directory."
        )

        XCTAssertTrue(
            earlySnapshots.contains { snapshot in
                guard let layout = TreemapLayoutEngine.layout(root: snapshot.tree, width: 1000, height: 700) else {
                    return false
                }

                return layout.flattened.contains { node in
                    node.depth > 0 && node.rect.width > 0 && node.rect.height > 0
                }
            },
            "Expected an in-progress snapshot to produce visible treemap nodes."
        )
    }
}
