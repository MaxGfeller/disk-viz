import Foundation

final class DiskScanner {
    private let fileManager = FileManager.default

    private let defaultMaxDepth = 8
    private let childLimitDepth = 2
    private let maxChildren = 30
    private let maxShallowChildren = 500
    private let snapshotInterval: TimeInterval = 0.35

    func scanDirectoryStreaming(
        path: String,
        maxDepth: Int? = nil,
        onProgress: @escaping (DiskNode, ScanProgress) async -> Void
    ) async throws -> DiskNode {
        let normalizedPath = normalizedScanPath(path)
        let root = MutableDiskNode.directory(path: normalizedPath)
        let runState = ScanRunState(
            root: root,
            progress: ScanProgress(dirsFound: 1, dirsCompleted: 0),
            snapshotInterval: snapshotInterval,
            onProgress: onProgress
        )

        try await fillNode(
            root,
            maxDepth: maxDepth ?? defaultMaxDepth,
            depth: 0,
            state: runState
        )
        try Task.checkCancellation()

        let final = root.snapshot()
        await onProgress(final, runState.progress)
        return final
    }

    private func fillNode(
        _ node: MutableDiskNode,
        maxDepth: Int,
        depth: Int,
        state: ScanRunState
    ) async throws {
        try Task.checkCancellation()

        if depth >= maxDepth {
            node.truncated = true
            node.size = fastDirectorySize(path: node.path)
            state.progress.dirsCompleted += 1
            await state.emit(force: true)
            return
        }

        let entries: [DirectoryEntry]
        do {
            entries = try directoryEntries(atPath: node.path)
        } catch {
            state.progress.dirsCompleted += 1
            await state.emit(force: true)
            return
        }

        state.progress.dirsFound += entries.filter(\.isDirectory).count
        var children = ChildAccumulator(parentPath: node.path, limit: childLimit(forDepth: depth))

        for entry in entries {
            try Task.checkCancellation()

            if entry.isDirectory {
                let child = MutableDiskNode.directory(path: entry.path, name: entry.name)
                children.addPending(child)
                sync(node: node, children: children)

                do {
                    try await fillNode(child, maxDepth: maxDepth, depth: depth + 1, state: state)
                    children.finishPending()
                    sync(node: node, children: children)
                    await state.emit()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    children.remove(child)
                    sync(node: node, children: children)
                    continue
                }
            } else if entry.isRegularFile {
                let child = MutableDiskNode.file(
                    path: entry.path,
                    name: entry.name,
                    size: entry.fileSize
                )
                children.add(child)
                sync(node: node, children: children)
                await state.emit()
            }
        }

        sync(node: node, children: children)
        state.progress.dirsCompleted += 1
        await state.emit(force: true)
    }

    private func directoryEntries(atPath path: String) throws -> [DirectoryEntry] {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        )

        return urls.compactMap { entryURL in
            guard let values = try? entryURL.resourceValues(forKeys: keys) else {
                return nil
            }
            if values.isSymbolicLink == true {
                return nil
            }

            let isDirectory = values.isDirectory == true
            let isRegularFile = values.isRegularFile == true
            guard isDirectory || isRegularFile else { return nil }

            return DirectoryEntry(
                name: entryURL.lastPathComponent,
                path: entryURL.path,
                isDirectory: isDirectory,
                isRegularFile: isRegularFile,
                fileSize: Int64(values.fileSize ?? 0)
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func fastDirectorySize(path: String) -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", path]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return 0 }

            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return 0 }
            guard let kb = Int64(text.split(whereSeparator: \.isWhitespace).first ?? "") else {
                return 0
            }
            return kb * 1024
        } catch {
            return 0
        }
    }

    private func normalizedScanPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed.isEmpty ? "/" : trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private func childLimit(forDepth depth: Int) -> Int {
        depth >= childLimitDepth ? maxChildren : maxShallowChildren
    }

    private func sync(node: MutableDiskNode, children: ChildAccumulator) {
        node.children = children.materialize()
        node.size = children.size
    }
}

private struct DirectoryEntry {
    var name: String
    var path: String
    var isDirectory: Bool
    var isRegularFile: Bool
    var fileSize: Int64
}

private final class ScanRunState {
    var root: MutableDiskNode
    var progress: ScanProgress
    let snapshotInterval: TimeInterval
    let onProgress: (DiskNode, ScanProgress) async -> Void
    private var lastEmit = Date.distantPast

    init(
        root: MutableDiskNode,
        progress: ScanProgress,
        snapshotInterval: TimeInterval,
        onProgress: @escaping (DiskNode, ScanProgress) async -> Void
    ) {
        self.root = root
        self.progress = progress
        self.snapshotInterval = snapshotInterval
        self.onProgress = onProgress
    }

    func emit(force: Bool = false) async {
        let now = Date()
        guard force || now.timeIntervalSince(lastEmit) >= snapshotInterval else {
            return
        }

        lastEmit = now
        await onProgress(root.snapshot(), progress)
    }
}

private final class MutableDiskNode {
    var name: String
    var path: String
    var size: Int64
    var kind: DiskNodeKind
    var fileExtension: String?
    var children: [MutableDiskNode]?
    var truncated: Bool

    init(
        name: String,
        path: String,
        size: Int64,
        kind: DiskNodeKind,
        fileExtension: String? = nil,
        children: [MutableDiskNode]? = nil,
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

    static func directory(path: String, name: String? = nil) -> MutableDiskNode {
        MutableDiskNode(
            name: name ?? displayName(forPath: path),
            path: path,
            size: 0,
            kind: .directory
        )
    }

    static func file(path: String, name: String, size: Int64) -> MutableDiskNode {
        let ext = (name as NSString).pathExtension.lowercased()
        return MutableDiskNode(
            name: name,
            path: path,
            size: size,
            kind: .file,
            fileExtension: ext.isEmpty ? nil : "." + ext
        )
    }

    func snapshot() -> DiskNode {
        let mappedChildren = children?.map { child in
            child.snapshot()
        } ?? []
        let sortedChildren = mappedChildren.sorted { lhs, rhs in
            if lhs.size == rhs.size {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.size > rhs.size
        }
        let childSnapshots = sortedChildren.isEmpty ? nil : sortedChildren
        let recalculatedSize = childSnapshots?.reduce(Int64(0)) { $0 + $1.size } ?? size

        return DiskNode(
            name: name,
            path: path,
            size: recalculatedSize,
            kind: kind,
            fileExtension: fileExtension,
            children: childSnapshots,
            truncated: truncated
        )
    }

    private static func displayName(forPath path: String) -> String {
        if path == "/" { return "/" }
        let last = URL(fileURLWithPath: path).lastPathComponent
        return last.isEmpty ? path : last
    }
}

private struct ChildAccumulator {
    var parentPath: String
    var limit: Int
    private var retained: [MutableDiskNode] = []
    private var droppedCount = 0
    private var droppedSize: Int64 = 0

    init(parentPath: String, limit: Int) {
        self.parentPath = parentPath
        self.limit = limit
    }

    var size: Int64 {
        retained.reduce(Int64(0)) { $0 + $1.size } + droppedSize
    }

    mutating func add(_ child: MutableDiskNode) {
        retained.append(child)
        enforceLimit()
    }

    mutating func addPending(_ child: MutableDiskNode) {
        retained.append(child)
        retained.sort(by: compareBySizeDescending)
    }

    mutating func finishPending() {
        enforceLimit()
    }

    mutating func remove(_ child: MutableDiskNode) {
        retained.removeAll { $0 === child }
    }

    private mutating func enforceLimit() {
        retained.sort(by: compareBySizeDescending)
        while retained.count > limit {
            guard let dropped = retained.popLast() else { break }
            droppedCount += 1
            droppedSize += dropped.size
        }
    }

    func materialize() -> [MutableDiskNode] {
        var children = retained.sorted(by: compareBySizeDescending)
        if droppedCount > 0 && droppedSize > 0 {
            children.append(
                MutableDiskNode(
                    name: "(\(droppedCount) smaller items)",
                    path: parentPath.appendingPathComponent("__other__"),
                    size: droppedSize,
                    kind: .file
                )
            )
        }
        return children
    }

    private func compareBySizeDescending(_ lhs: MutableDiskNode, _ rhs: MutableDiskNode) -> Bool {
        if lhs.size == rhs.size {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return lhs.size > rhs.size
    }
}

private extension String {
    func appendingPathComponent(_ component: String) -> String {
        (self as NSString).appendingPathComponent(component)
    }
}
