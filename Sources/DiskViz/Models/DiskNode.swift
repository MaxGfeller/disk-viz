import Foundation

enum DiskNodeKind: String, Hashable, Sendable {
    case file
    case directory
}

struct DiskNode: Identifiable, Hashable, Sendable {
    var id: String { path }

    var name: String
    var path: String
    var size: Int64
    var kind: DiskNodeKind
    var fileExtension: String?
    var children: [DiskNode]?
    var truncated: Bool

    var isDirectory: Bool {
        kind == .directory
    }

    var hasChildren: Bool {
        !(children?.isEmpty ?? true)
    }

    init(
        name: String,
        path: String,
        size: Int64,
        kind: DiskNodeKind,
        fileExtension: String? = nil,
        children: [DiskNode]? = nil,
        truncated: Bool = false
    ) {
        self.name = name
        self.path = path
        self.size = size
        self.kind = kind
        self.fileExtension = fileExtension
        self.children = children
        self.truncated = truncated
    }
}

struct ScanProgress: Equatable, Sendable {
    var dirsFound = 0
    var dirsCompleted = 0
    var filesFound = 0
    var bytesFound: Int64 = 0
    var inaccessibleDirs = 0
    var currentPath: String?
}

struct ScanSnapshot: Equatable, Sendable {
    var root: DiskNode
    var progress: ScanProgress
    var largestFiles: [DiskNode]
    var largestFilesByFolder: [String: [DiskNode]]
}

struct DiskScanResult: Equatable, Sendable {
    var root: DiskNode
    var progress: ScanProgress
    var largestFiles: [DiskNode]
    var largestFilesByFolder: [String: [DiskNode]]
}
