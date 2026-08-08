@testable import DiskViz
import XCTest

final class VolumeCatalogTests: XCTestCase {
    func testResolveOrdersStartupThenInternalThenExternalAndDefaultsToStartup() throws {
        let discovery = VolumeCatalog.resolve([
            descriptor(name: "Photos", path: "/Volumes/Photos", isInternal: false),
            descriptor(name: "Archive", path: "/Volumes/Archive", isInternal: false),
            descriptor(name: "Workspace", path: "/Volumes/Workspace", isInternal: true),
            descriptor(name: "Macintosh HD", path: "/", isInternal: true, isStartup: true)
        ])

        XCTAssertEqual(
            discovery.sources.map(\.path),
            ["/", "/Volumes/Workspace", "/Volumes/Archive", "/Volumes/Photos"]
        )
        XCTAssertEqual(discovery.defaultSource?.path, "/")
    }

    func testResolveFallsBackToInternalVolumeWithoutAutoSelectingExternalVolume() {
        let withInternal = VolumeCatalog.resolve([
            descriptor(name: "External", path: "/Volumes/External", isInternal: false),
            descriptor(name: "Internal", path: "/Volumes/Internal", isInternal: true)
        ])
        XCTAssertEqual(withInternal.defaultSource?.path, "/Volumes/Internal")

        let externalOnly = VolumeCatalog.resolve([
            descriptor(name: "External", path: "/Volumes/External", isInternal: false)
        ])
        XCTAssertEqual(externalOnly.sources.map(\.path), ["/Volumes/External"])
        XCTAssertNil(externalOnly.defaultSource)
    }

    func testCustomFolderHelperHasStableIdentityAndClampsCapacityValues() {
        let first = ScanSource.customFolder(
            path: "/tmp/../tmp/DiskViz Fixture",
            isInternal: true,
            totalBytes: 100,
            freeBytes: 120
        )
        let refreshed = ScanSource.customFolder(
            path: "/tmp/DiskViz Fixture",
            isInternal: true,
            totalBytes: 200,
            freeBytes: 50
        )

        XCTAssertEqual(first.name, "DiskViz Fixture")
        XCTAssertEqual(first.path, "/tmp/DiskViz Fixture")
        XCTAssertEqual(first.freeBytes, 100)
        XCTAssertEqual(first, refreshed)
        XCTAssertEqual(Set([first, refreshed]).count, 1)
        XCTAssertNotEqual(
            first.id,
            ScanSource(
                kind: .volume,
                name: first.name,
                path: first.path,
                isInternal: true,
                totalBytes: first.totalBytes,
                freeBytes: first.freeBytes
            ).id
        )
    }

    private func descriptor(
        name: String,
        path: String,
        isInternal: Bool,
        isStartup: Bool = false
    ) -> VolumeDescriptor {
        VolumeDescriptor(
            name: name,
            path: path,
            isInternal: isInternal,
            totalBytes: 1_000,
            freeBytes: 250,
            isStartup: isStartup
        )
    }
}
