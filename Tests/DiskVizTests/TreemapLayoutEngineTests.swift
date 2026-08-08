@testable import DiskViz
import XCTest

final class TreemapLayoutEngineTests: XCTestCase {
    func testLayoutKeepsRootSiblingsAsUsableDirectChildTiles() throws {
        let root = DiskNode(
            name: "fixture",
            path: "/fixture",
            size: 220,
            kind: .directory,
            children: [
                deepDirectory(name: "Applications", path: "/fixture/Applications", size: 100, fileCount: 80),
                directory(name: "Users", path: "/fixture/Users", size: 60),
                directory(name: "Library", path: "/fixture/Library", size: 40),
                directory(name: "System", path: "/fixture/System", size: 20)
            ]
        )

        let layout = try XCTUnwrap(TreemapLayoutEngine.layout(root: root, width: 1200, height: 800))
        let rootNames = Set(layout.children.map(\.node.name))

        XCTAssertTrue(rootNames.contains("Applications"))
        XCTAssertTrue(rootNames.contains("Users"))
        XCTAssertTrue(rootNames.contains("Library"))
        XCTAssertTrue(rootNames.contains("System"))
        XCTAssertEqual(layout.flattened.count, 5)

        for child in layout.children {
            XCTAssertEqual(child.depth, 1, child.node.name)
            XCTAssertTrue(child.children.isEmpty, child.node.name)
            XCTAssertGreaterThan(child.rect.width, 0, child.node.name)
            XCTAssertGreaterThan(child.rect.height, 0, child.node.name)
        }
    }

    func testLayoutPreservesDirectoryChildrenAndScanTruncationSemantics() throws {
        let scannedDirectory = deepDirectory(
            name: "Applications",
            path: "/fixture/Applications",
            size: 100,
            fileCount: 80
        )
        let scanTruncatedDirectory = DiskNode(
            name: "Caches",
            path: "/fixture/Caches",
            size: 50,
            kind: .directory,
            truncated: true
        )
        let root = DiskNode(
            name: "fixture",
            path: "/fixture",
            size: 150,
            kind: .directory,
            children: [
                scannedDirectory,
                scanTruncatedDirectory
            ]
        )

        let layout = try XCTUnwrap(TreemapLayoutEngine.layout(root: root, width: 1000, height: 700))
        let applicationsTile = try XCTUnwrap(
            layout.children.first { $0.node.path == scannedDirectory.path }
        )
        let cachesTile = try XCTUnwrap(
            layout.children.first { $0.node.path == scanTruncatedDirectory.path }
        )

        XCTAssertEqual(applicationsTile.node, scannedDirectory)
        XCTAssertFalse(applicationsTile.node.truncated)
        XCTAssertTrue(applicationsTile.node.hasChildren)
        XCTAssertTrue(applicationsTile.children.isEmpty)

        XCTAssertEqual(cachesTile.node, scanTruncatedDirectory)
        XCTAssertTrue(cachesTile.node.truncated)
        XCTAssertFalse(cachesTile.node.hasChildren)
        XCTAssertTrue(cachesTile.children.isEmpty)
    }

    func testLayoutIsStableLargestFirstAndAreaIsProportional() throws {
        let root = DiskNode(
            name: "fixture",
            path: "/fixture",
            size: 250,
            kind: .directory,
            children: [
                file(name: "Tiny", size: 10),
                file(name: "Beta", size: 100),
                file(name: "Medium", size: 40),
                file(name: "Alpha", size: 100)
            ]
        )

        let layout = try XCTUnwrap(TreemapLayoutEngine.layout(root: root, width: 1000, height: 700))
        XCTAssertEqual(layout.children.map(\.node.name), ["Alpha", "Beta", "Medium", "Tiny"])

        let areas = Dictionary(uniqueKeysWithValues: layout.children.map {
            ($0.node.name, $0.rect.width * $0.rect.height)
        })
        let alphaArea = try XCTUnwrap(areas["Alpha"])
        let betaArea = try XCTUnwrap(areas["Beta"])
        let mediumArea = try XCTUnwrap(areas["Medium"])
        let tinyArea = try XCTUnwrap(areas["Tiny"])

        XCTAssertGreaterThan(tinyArea, 0)
        XCTAssertEqual(alphaArea, betaArea, accuracy: 0.001)
        XCTAssertEqual(alphaArea / mediumArea, 2.5, accuracy: 0.001)
        XCTAssertEqual(mediumArea / tinyArea, 4, accuracy: 0.001)
    }

    func testLayoutAggregatesOverflowWithoutRecursingIntoRetainedChildren() throws {
        let children = (1...90).map { index in
            directory(
                name: "Directory-\(index)",
                path: "/fixture/Directory-\(index)",
                size: Int64(index)
            )
        }
        let root = DiskNode(
            name: "fixture",
            path: "/fixture",
            size: children.reduce(0) { $0 + $1.size },
            kind: .directory,
            children: children
        )

        let layout = try XCTUnwrap(TreemapLayoutEngine.layout(root: root, width: 1200, height: 800))
        let overflow = try XCTUnwrap(
            layout.children.first { $0.node.path.contains("__layout_other_") }
        )

        XCTAssertEqual(layout.children.count, 81)
        XCTAssertEqual(overflow.node.size, 55)
        XCTAssertEqual(overflow.node.name, "(10 smaller items)")
        XCTAssertTrue(layout.children.allSatisfy { $0.children.isEmpty })
        XCTAssertTrue(layout.children.allSatisfy { $0.rect.width > 0 && $0.rect.height > 0 })
    }

    private func file(name: String, size: Int64) -> DiskNode {
        DiskNode(
            name: name,
            path: "/fixture/\(name)",
            size: size,
            kind: .file
        )
    }

    private func directory(name: String, path: String, size: Int64) -> DiskNode {
        DiskNode(
            name: name,
            path: path,
            size: size,
            kind: .directory,
            children: [
                DiskNode(
                    name: "\(name).bin",
                    path: "\(path)/\(name).bin",
                    size: size,
                    kind: .file
                )
            ]
        )
    }

    private func deepDirectory(name: String, path: String, size: Int64, fileCount: Int) -> DiskNode {
        let files = (0..<fileCount).map { index in
            DiskNode(
                name: "File-\(index).swift",
                path: "\(path)/Developer/Toolchains/usr/lib/File-\(index).swift",
                size: max(1, size / Int64(fileCount)),
                kind: .file,
                fileExtension: ".swift"
            )
        }

        let lib = DiskNode(
            name: "lib",
            path: "\(path)/Developer/Toolchains/usr/lib",
            size: size,
            kind: .directory,
            children: files
        )
        let usr = DiskNode(
            name: "usr",
            path: "\(path)/Developer/Toolchains/usr",
            size: size,
            kind: .directory,
            children: [lib]
        )
        let toolchains = DiskNode(
            name: "Toolchains",
            path: "\(path)/Developer/Toolchains",
            size: size,
            kind: .directory,
            children: [usr]
        )
        let developer = DiskNode(
            name: "Developer",
            path: "\(path)/Developer",
            size: size,
            kind: .directory,
            children: [toolchains]
        )
        return DiskNode(
            name: name,
            path: path,
            size: size,
            kind: .directory,
            children: [developer]
        )
    }
}
