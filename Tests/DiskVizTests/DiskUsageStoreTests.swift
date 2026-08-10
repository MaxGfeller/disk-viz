@testable import DiskViz
import XCTest

@MainActor
final class DiskUsageStoreTests: XCTestCase {
    func testDetailExpansionPreservesSourceRootAndNavigationAncestry() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("DiskVizStore-\(UUID().uuidString)", isDirectory: true)
        let targetURL = rootURL
            .appendingPathComponent("Users", isDirectory: true)
            .appendingPathComponent("mg", isDirectory: true)
        let nestedURL = targetURL.appendingPathComponent("Library", isDirectory: true)
        let siblingURL = rootURL.appendingPathComponent("Applications", isDirectory: true)
        let payloadURL = nestedURL.appendingPathComponent("large.cache")

        try fileManager.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: siblingURL, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 128 * 1024).write(to: payloadURL)
        try Data(repeating: 3, count: 4096)
            .write(to: siblingURL.appendingPathComponent("app.bin"))
        defer {
            try? fileManager.removeItem(at: rootURL)
        }

        let store = DiskUsageStore(initialScanPath: rootURL.path)
        store.scan()
        try await waitUntil {
            !store.scanning && store.root != nil
        }

        let originalRoot = try XCTUnwrap(store.root)
        let users = try XCTUnwrap(originalRoot.children?.first { $0.name == "Users" })
        let target = try XCTUnwrap(users.children?.first { $0.name == "mg" })
        let originalSourceID = store.selectedSource?.id

        XCTAssertTrue(target.truncated)
        XCTAssertFalse(target.hasChildren)

        store.expand(target.path)

        XCTAssertEqual(store.root?.path, originalRoot.path)
        XCTAssertEqual(store.scanPath, rootURL.path)
        XCTAssertEqual(store.selectedSource?.id, originalSourceID)

        store.stopScan()
        XCTAssertFalse(
            store.scanStopped,
            "Stopping folder details must not mark a completed source scan as partial."
        )
        XCTAssertTrue(store.hasIncompleteDetails(for: target.path))

        store.expand(target.path)

        try await waitUntil {
            !store.scanning && store.expandingPath == nil
        }

        let expandedRoot = try XCTUnwrap(store.root)
        let expandedTarget = try XCTUnwrap(
            TreeOperations.node(in: expandedRoot, atPath: target.path)
        )

        XCTAssertTrue(expandedTarget.hasChildren)
        XCTAssertNotNil(
            TreeOperations.node(in: expandedRoot, atPath: siblingURL.path),
            "Expanding a folder must not replace the source root or its siblings."
        )
        XCTAssertEqual(
            TreeOperations.buildZoomPath(root: expandedRoot, targetPath: target.path).map(\.path),
            [originalRoot.path, users.path, target.path]
        )
        XCTAssertEqual(
            store.largestFiles(in: target.path).first.map {
                URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path
            },
            payloadURL.resolvingSymlinksInPath().path
        )
    }

    func testFolderCanExpandWhileSourceScanContinues() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("DiskVizStore-\(UUID().uuidString)", isDirectory: true)
        let targetURL = rootURL
            .appendingPathComponent("Users", isDirectory: true)
            .appendingPathComponent("mg", isDirectory: true)

        for branchIndex in 0..<60 {
            let branchURL = targetURL.appendingPathComponent(
                "Branch-\(branchIndex)",
                isDirectory: true
            )
            var deepURL = branchURL
            for depth in 0..<40 {
                deepURL.appendPathComponent("Level-\(depth)", isDirectory: true)
            }
            try fileManager.createDirectory(at: deepURL, withIntermediateDirectories: true)
            try Data(repeating: UInt8(branchIndex), count: 1024)
                .write(to: branchURL.appendingPathComponent("payload.bin"))
        }
        defer {
            try? fileManager.removeItem(at: rootURL)
        }

        let store = DiskUsageStore(initialScanPath: rootURL.path)
        let originalSourceID = store.selectedSource?.id
        store.scan()

        var visibleTarget: DiskNode?
        try await waitUntil(timeout: 12, pollingNanoseconds: 1_000_000) {
            guard
                store.sourceScanning,
                let root = store.root,
                let target = TreeOperations.node(in: root, atPath: targetURL.path),
                target.truncated
            else {
                return false
            }
            visibleTarget = target
            return true
        }

        let target = try XCTUnwrap(visibleTarget)
        let sourceRootPath = try XCTUnwrap(store.root?.path)
        store.expand(target.path)

        XCTAssertTrue(store.sourceScanning)
        XCTAssertTrue(store.isExpanding(target.path))
        XCTAssertEqual(store.root?.path, sourceRootPath)
        XCTAssertEqual(store.scanPath, rootURL.path)
        XCTAssertEqual(store.selectedSource?.id, originalSourceID)

        var visibleChild: DiskNode?
        try await waitUntil(timeout: 12, pollingNanoseconds: 1_000_000) {
            guard
                store.isExpanding(target.path),
                let root = store.root,
                let refreshedTarget = TreeOperations.node(in: root, atPath: target.path),
                let child = refreshedTarget.children?.first(where: \.isDirectory)
            else {
                return false
            }
            visibleChild = child
            return true
        }

        let child = try XCTUnwrap(visibleChild)
        store.expand(child.path)
        XCTAssertTrue(
            store.isExpanding(target.path),
            "Opening a child must not cancel its parent detail scan."
        )
        XCTAssertTrue(store.isExpanding(child.path))

        try await waitUntil(timeout: 15) {
            !store.scanning
        }

        let finalRoot = try XCTUnwrap(store.root)
        let expandedTarget = try XCTUnwrap(
            TreeOperations.node(in: finalRoot, atPath: target.path)
        )
        XCTAssertTrue(expandedTarget.hasChildren)
        XCTAssertFalse(store.hasIncompleteDetails(for: target.path))
        XCTAssertFalse(store.hasIncompleteDetails(for: child.path))
        XCTAssertTrue(
            TreeOperations.node(in: finalRoot, atPath: child.path)?.hasChildren == true
        )
        XCTAssertEqual(
            TreeOperations.buildZoomPath(root: finalRoot, targetPath: target.path).map(\.path).last,
            target.path
        )
    }

    func testDetailExpansionQueueBoundsConcurrentScans() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("DiskVizStore-\(UUID().uuidString)", isDirectory: true)
        let folderURLs = (0..<5).map { index in
            rootURL.appendingPathComponent("Folder-\(index)", isDirectory: true)
        }
        for folderURL in folderURLs {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }
        defer {
            try? fileManager.removeItem(at: rootURL)
        }

        let store = DiskUsageStore(initialScanPath: rootURL.path)
        store.scan()
        try await waitUntil {
            !store.scanning && store.root != nil
        }

        for folderURL in folderURLs {
            store.expand(folderURL.path)
        }

        XCTAssertEqual(store.runningDetailScanCount, 2)
        XCTAssertTrue(folderURLs.allSatisfy { store.isExpanding($0.path) })

        try await waitUntil {
            !store.scanning
        }

        XCTAssertEqual(store.runningDetailScanCount, 0)
        XCTAssertTrue(folderURLs.allSatisfy { !store.hasIncompleteDetails(for: $0.path) })
    }

    private func waitUntil(
        timeout: TimeInterval = 8,
        pollingNanoseconds: UInt64 = 20_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for store state")
                return
            }
            try await Task.sleep(nanoseconds: pollingNanoseconds)
        }
    }
}
