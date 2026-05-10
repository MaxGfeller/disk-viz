@testable import DiskViz
import XCTest

final class TreemapLayoutEngineTests: XCTestCase {
    func testLayoutPreservesRootSiblingsWhenFirstChildHasDeepTree() throws {
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

        for child in layout.children {
            XCTAssertGreaterThan(child.rect.width, 0, child.node.name)
            XCTAssertGreaterThan(child.rect.height, 0, child.node.name)
        }
    }

    func testLayoutCollapsesDeepNodesIntoClickableDirectoryTiles() throws {
        let root = DiskNode(
            name: "fixture",
            path: "/fixture",
            size: 100,
            kind: .directory,
            children: [
                deepDirectory(name: "Applications", path: "/fixture/Applications", size: 100, fileCount: 80)
            ]
        )

        let layout = try XCTUnwrap(TreemapLayoutEngine.layout(root: root, width: 1000, height: 700))
        let flattened = layout.flattened
        let collapsedDirectories = flattened.filter {
            $0.node.isDirectory && $0.node.truncated && $0.children.isEmpty
        }

        XCTAssertFalse(collapsedDirectories.isEmpty)
        XCTAssertTrue(collapsedDirectories.allSatisfy { $0.rect.width > 0 && $0.rect.height > 0 })
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
