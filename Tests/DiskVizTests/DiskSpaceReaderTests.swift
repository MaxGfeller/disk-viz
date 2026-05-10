@testable import DiskViz
import XCTest

final class DiskSpaceReaderTests: XCTestCase {
    func testVolumeInfoUsesNearestExistingAncestorForMissingPath() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("DiskVizVolume-\(UUID().uuidString)", isDirectory: true)
        let missingPath = rootURL
            .appendingPathComponent("Missing", isDirectory: true)
            .appendingPathComponent("Child", isDirectory: true)
            .path

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: rootURL)
        }

        let info = try XCTUnwrap(DiskSpaceReader.volumeInfo(for: missingPath))

        XCTAssertEqual(info.path, rootURL.path)
        XCTAssertGreaterThan(info.totalBytes, 0)
        XCTAssertGreaterThanOrEqual(info.freeBytes, 0)
        XCTAssertLessThanOrEqual(info.freeBytes, info.totalBytes)
    }
}
