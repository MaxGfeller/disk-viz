import Foundation

struct VolumeDescriptor: Equatable, Sendable {
    let name: String
    let path: String
    let isInternal: Bool
    let totalBytes: Int64
    let freeBytes: Int64
    let isStartup: Bool
}

enum VolumeCatalog {
    struct Discovery: Equatable, Sendable {
        let sources: [ScanSource]
        let defaultSource: ScanSource?
    }

    private static let volumeResourceKeys: Set<URLResourceKey> = [
        .volumeNameKey,
        .volumeIsInternalKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey
    ]

    static func discover(fileManager: FileManager = .default) -> Discovery {
        let volumeURLs = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(volumeResourceKeys),
            options: [.skipHiddenVolumes]
        ) ?? []

        let descriptors = volumeURLs.compactMap(volumeDescriptor(for:))
        return resolve(descriptors)
    }

    static func customFolderSource(path: String, name: String? = nil) -> ScanSource {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expandedPath = (trimmedPath.isEmpty ? "/" : trimmedPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath, isDirectory: true).standardizedFileURL
        let values = try? url.resourceValues(forKeys: volumeResourceKeys)

        return .customFolder(
            path: url.path,
            name: name,
            isInternal: values?.volumeIsInternal ?? false,
            totalBytes: Int64(values?.volumeTotalCapacity ?? 0),
            freeBytes: Int64(values?.volumeAvailableCapacity ?? 0)
        )
    }

    static func resolve(_ descriptors: [VolumeDescriptor]) -> Discovery {
        let orderedDescriptors = descriptors.sorted(by: descriptorComesFirst)
        let sources = orderedDescriptors.map(source(from:))

        let defaultDescriptor = orderedDescriptors.first(where: \.isStartup)
            ?? orderedDescriptors.first(where: \.isInternal)
        let defaultSource = defaultDescriptor.map(source(from:))

        return Discovery(sources: sources, defaultSource: defaultSource)
    }

    private static func volumeDescriptor(for url: URL) -> VolumeDescriptor? {
        guard let values = try? url.resourceValues(forKeys: volumeResourceKeys) else {
            return nil
        }

        let path = url.standardizedFileURL.path
        return VolumeDescriptor(
            name: values.volumeName ?? "",
            path: path,
            isInternal: values.volumeIsInternal ?? (path == "/"),
            totalBytes: Int64(values.volumeTotalCapacity ?? 0),
            freeBytes: Int64(values.volumeAvailableCapacity ?? 0),
            isStartup: path == "/"
        )
    }

    private static func source(from descriptor: VolumeDescriptor) -> ScanSource {
        ScanSource(
            kind: .volume,
            name: descriptor.name,
            path: descriptor.path,
            isInternal: descriptor.isInternal,
            totalBytes: descriptor.totalBytes,
            freeBytes: descriptor.freeBytes
        )
    }

    private static func descriptorComesFirst(_ lhs: VolumeDescriptor, _ rhs: VolumeDescriptor) -> Bool {
        let lhsRank = rank(of: lhs)
        let rhsRank = rank(of: rhs)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }

        let nameComparison = lhs.name.localizedStandardCompare(rhs.name)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }

        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }

    private static func rank(of descriptor: VolumeDescriptor) -> Int {
        if descriptor.isStartup {
            return 0
        }
        return descriptor.isInternal ? 1 : 2
    }
}
