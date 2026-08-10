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

    func testReplacingNestedNodePreservesRootAndSiblingsAndRecomputesAncestorSizes() throws {
        let oldUser = DiskNode(
            name: "mg",
            path: "/fixture/Users/mg",
            size: 100,
            kind: .directory,
            truncated: true
        )
        let users = DiskNode(
            name: "Users",
            path: "/fixture/Users",
            size: 100,
            kind: .directory,
            children: [oldUser]
        )
        let applications = DiskNode(
            name: "Applications",
            path: "/fixture/Applications",
            size: 50,
            kind: .directory
        )
        let root = DiskNode(
            name: "fixture",
            path: "/fixture",
            size: 150,
            kind: .directory,
            children: [users, applications]
        )
        let payload = DiskNode(
            name: "archive.zip",
            path: "/fixture/Users/mg/archive.zip",
            size: 240,
            kind: .file,
            fileExtension: ".zip"
        )
        let replacement = DiskNode(
            name: "mg",
            path: oldUser.path,
            size: 240,
            kind: .directory,
            children: [payload]
        )

        let updated = try XCTUnwrap(
            TreeOperations.replacingNode(
                in: root,
                atPath: oldUser.path,
                with: replacement
            )
        )

        XCTAssertEqual(updated.path, root.path)
        XCTAssertEqual(updated.size, 290)
        XCTAssertEqual(updated.children?.first { $0.path == applications.path }, applications)

        let updatedUsers = try XCTUnwrap(
            TreeOperations.node(in: updated, atPath: users.path)
        )
        XCTAssertEqual(updatedUsers.size, 240)
        XCTAssertEqual(
            TreeOperations.node(in: updated, atPath: replacement.path),
            replacement
        )
        XCTAssertEqual(
            TreeOperations.buildZoomPath(root: updated, targetPath: replacement.path).map(\.path),
            [root.path, users.path, replacement.path]
        )
    }

    func testReplacingNodeRequiresAnExactExistingComponentBoundary() {
        let user = DiskNode(
            name: "Users",
            path: "/fixture/Users",
            size: 100,
            kind: .directory
        )
        let root = DiskNode(
            name: "fixture",
            path: "/fixture",
            size: 100,
            kind: .directory,
            children: [user]
        )
        let prefixSibling = DiskNode(
            name: "Users-old",
            path: "/fixture/Users-old",
            size: 200,
            kind: .directory
        )

        XCTAssertNil(
            TreeOperations.replacingNode(
                in: root,
                atPath: prefixSibling.path,
                with: prefixSibling
            )
        )
        XCTAssertEqual(root.children, [user])
        XCTAssertEqual(root.size, 100)
    }

    func testReplacingRootReturnsTheReplacement() {
        let root = DiskNode(
            name: "fixture",
            path: "/fixture",
            size: 100,
            kind: .directory
        )
        let replacement = DiskNode(
            name: "fixture",
            path: root.path,
            size: 400,
            kind: .directory,
            children: [
                DiskNode(
                    name: "large.mov",
                    path: "/fixture/large.mov",
                    size: 400,
                    kind: .file,
                    fileExtension: ".mov"
                )
            ]
        )

        XCTAssertEqual(
            TreeOperations.replacingNode(
                in: root,
                atPath: root.path,
                with: replacement
            ),
            replacement
        )
    }

    func testReplacingNodeRejectsAReplacementForAnotherPath() {
        let root = DiskNode(
            name: "fixture",
            path: "/fixture",
            size: 100,
            kind: .directory
        )
        let mismatchedReplacement = DiskNode(
            name: "elsewhere",
            path: "/elsewhere",
            size: 100,
            kind: .directory
        )

        XCTAssertNil(
            TreeOperations.replacingNode(
                in: root,
                atPath: root.path,
                with: mismatchedReplacement
            )
        )
    }

    func testPinningPrunedBranchPreservesNewSnapshotAndNavigation() throws {
        let target = DiskNode(
            name: "Selected",
            path: "/fixture/Parent/Selected",
            size: 20,
            kind: .directory,
            truncated: true
        )
        let capturedParent = DiskNode(
            name: "Parent",
            path: "/fixture/Parent",
            size: 100,
            kind: .directory,
            children: [
                target,
                DiskNode(
                    name: "Old sibling",
                    path: "/fixture/Parent/Old",
                    size: 80,
                    kind: .directory
                )
            ]
        )
        let capturedRoot = DiskNode(
            name: "fixture",
            path: "/fixture",
            size: 110,
            kind: .directory,
            children: [
                capturedParent,
                DiskNode(
                    name: "Earlier root item",
                    path: "/fixture/Earlier",
                    size: 10,
                    kind: .file
                )
            ]
        )

        let latestParent = DiskNode(
            name: "Parent",
            path: capturedParent.path,
            size: 150,
            kind: .directory,
            children: [
                DiskNode(
                    name: "Updated sibling",
                    path: "/fixture/Parent/Updated",
                    size: 100,
                    kind: .directory
                ),
                DiskNode(
                    name: "(500 smaller items)",
                    path: "/fixture/Parent/__other__",
                    size: 50,
                    kind: .file
                )
            ]
        )
        let newestRootItem = DiskNode(
            name: "Newest root item",
            path: "/fixture/Newest",
            size: 200,
            kind: .file
        )
        let latestRoot = DiskNode(
            name: "fixture",
            path: capturedRoot.path,
            size: 350,
            kind: .directory,
            children: [latestParent, newestRootItem]
        )

        let pinned = try XCTUnwrap(
            TreeOperations.pinningBranch(
                in: latestRoot,
                ancestry: [capturedRoot, capturedParent, target]
            )
        )
        let pinnedParent = try XCTUnwrap(
            TreeOperations.node(in: pinned, atPath: latestParent.path)
        )

        XCTAssertEqual(pinned.size, latestRoot.size)
        XCTAssertEqual(pinnedParent.size, latestParent.size)
        XCTAssertEqual(
            TreeOperations.node(in: pinned, atPath: newestRootItem.path),
            newestRootItem,
            "Pinning a navigation branch must retain unrelated data from the newest snapshot."
        )
        XCTAssertEqual(
            TreeOperations.node(in: pinned, atPath: "/fixture/Parent/Updated")?.size,
            100
        )
        XCTAssertEqual(
            TreeOperations.node(in: pinned, atPath: "/fixture/Parent/__other__")?.size,
            30,
            "The restored branch must be removed from the aggregate to avoid double counting."
        )
        XCTAssertEqual(
            TreeOperations.buildZoomPath(root: pinned, targetPath: target.path).map(\.path),
            [capturedRoot.path, capturedParent.path, target.path]
        )

        let expandedTarget = DiskNode(
            name: target.name,
            path: target.path,
            size: 25,
            kind: .directory,
            children: [
                DiskNode(
                    name: "payload.bin",
                    path: target.path + "/payload.bin",
                    size: 25,
                    kind: .file
                )
            ]
        )
        let composed = try XCTUnwrap(
            TreeOperations.replacingNode(
                in: pinned,
                atPath: target.path,
                with: expandedTarget
            )
        )
        XCTAssertEqual(composed.size, latestRoot.size + 5)
        XCTAssertEqual(
            TreeOperations.node(in: composed, atPath: target.path),
            expandedTarget
        )
    }
}
