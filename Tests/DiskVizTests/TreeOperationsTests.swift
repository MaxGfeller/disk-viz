@testable import DiskViz
import XCTest

final class TreeOperationsTests: XCTestCase {
    func testNodeLookupAndZoomPathUsePathComponentBoundaries() throws {
        let file = DiskNode(
            name: "large.mov",
            path: "/fixture/Media/large.mov",
            size: 400,
            kind: .file,
            fileExtension: ".mov"
        )
        let media = DiskNode(
            name: "Media",
            path: "/fixture/Media",
            size: 400,
            kind: .directory,
            children: [file]
        )
        let root = DiskNode(
            name: "fixture",
            path: "/fixture",
            size: 400,
            kind: .directory,
            children: [media]
        )

        XCTAssertEqual(TreeOperations.node(in: root, atPath: file.path), file)
        XCTAssertNil(TreeOperations.node(in: root, atPath: "/fixture-other/large.mov"))
        XCTAssertEqual(
            TreeOperations.buildZoomPath(root: root, targetPath: file.path).map(\.path),
            [root.path, media.path, file.path]
        )
    }

    func testPathRelationshipDoesNotMatchSiblingPrefixes() {
        XCTAssertTrue(TreeOperations.isPath("/Users/mg", equalToOrDescendantOf: "/Users"))
        XCTAssertTrue(TreeOperations.isPath("/Users", equalToOrDescendantOf: "/Users"))
        XCTAssertFalse(TreeOperations.isPath("/Users-old/mg", equalToOrDescendantOf: "/Users"))
    }
}
