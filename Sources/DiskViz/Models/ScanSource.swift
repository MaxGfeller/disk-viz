import Foundation

struct ScanSource: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case volume
        case customFolder
    }

    let kind: Kind
    let name: String
    let path: String
    let isInternal: Bool
    let totalBytes: Int64
    let freeBytes: Int64

    var id: String {
        "\(kind.rawValue):\(path)"
    }

    var usedBytes: Int64 {
        max(0, totalBytes - freeBytes)
    }

    var isExternal: Bool {
        !isInternal
    }

    init(
        kind: Kind,
        name: String,
        path: String,
        isInternal: Bool,
        totalBytes: Int64,
        freeBytes: Int64
    ) {
        let normalizedPath = Self.normalizedPath(path)
        let normalizedTotal = max(0, totalBytes)

        self.kind = kind
        self.name = Self.displayName(name, path: normalizedPath)
        self.path = normalizedPath
        self.isInternal = isInternal
        self.totalBytes = normalizedTotal
        self.freeBytes = min(max(0, freeBytes), normalizedTotal)
    }

    static func customFolder(
        path: String,
        name: String? = nil,
        isInternal: Bool,
        totalBytes: Int64,
        freeBytes: Int64
    ) -> ScanSource {
        ScanSource(
            kind: .customFolder,
            name: name ?? "",
            path: path,
            isInternal: isInternal,
            totalBytes: totalBytes,
            freeBytes: freeBytes
        )
    }

    static func == (lhs: ScanSource, rhs: ScanSource) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    private static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed.isEmpty ? "/" : trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }

    private static func displayName(_ name: String, path: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        if path == "/" {
            return "Startup Disk"
        }

        let lastComponent = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        return lastComponent.isEmpty ? path : lastComponent
    }
}
