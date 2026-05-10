import Foundation

enum DiskSpaceReader {
    static func volumeInfo(for path: String) -> DiskVolumeInfo? {
        let normalizedPath = normalized(path)
        guard let existingPath = nearestExistingPath(for: normalizedPath) else {
            return nil
        }

        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: existingPath)
            guard
                let totalBytes = int64Value(attributes[.systemSize]),
                let freeBytes = int64Value(attributes[.systemFreeSize])
            else {
                return nil
            }

            return DiskVolumeInfo(
                path: existingPath,
                totalBytes: totalBytes,
                freeBytes: freeBytes
            )
        } catch {
            return nil
        }
    }

    private static func normalized(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed.isEmpty ? "/" : trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func nearestExistingPath(for path: String) -> String? {
        let fileManager = FileManager.default
        var url = URL(fileURLWithPath: path)
        var isDirectory = ObjCBool(false)

        while !fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else {
                return nil
            }

            url = parent
        }

        return url.path
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let integer as Int:
            return Int64(integer)
        case let integer as Int64:
            return integer
        case let unsignedInteger as UInt64:
            guard unsignedInteger <= UInt64(Int64.max) else { return nil }
            return Int64(unsignedInteger)
        default:
            return nil
        }
    }
}
