import Foundation

final class DiskScanner {
    private let fileManager = FileManager.default

    private let defaultMaxDepth = 8
    private let childLimitDepth = 2
    private let maxChildren = 30
    private let maxShallowChildren = 500
    private let maxConcurrentChildScans = 8
    private let maxConcurrentDirectoryReads = 8
    private let fileSyncBatchSize = 128
    private let accumulatorSlack = 32
    private let snapshotInterval: TimeInterval

    init(snapshotInterval: TimeInterval = 0.9) {
        self.snapshotInterval = snapshotInterval
    }

    func scanDirectoryStreaming(
        path: String,
        maxDepth: Int? = nil,
        onProgress: @escaping (ScanSnapshot) async -> Void
    ) async throws -> DiskScanResult {
        let normalizedPath = normalizedScanPath(path)
        let root = MutableDiskNode.directory(path: normalizedPath)
        let runState = ScanRunState(
            root: root,
            progress: ScanProgress(dirsFound: 1),
            maxConcurrentDirectoryReads: maxConcurrentDirectoryReads,
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

        runState.update { progress in
            progress.currentPath = nil
        }
        let final = runState.currentSnapshot()
        await onProgress(final)
        return DiskScanResult(
            root: final.root,
            progress: final.progress,
            largestFiles: final.largestFiles
        )
    }

    @available(*, deprecated, message: "Use the ScanSnapshot/DiskScanResult overload")
    func scanDirectoryStreaming(
        path: String,
        maxDepth: Int? = nil,
        onProgress: @escaping (DiskNode, ScanProgress) async -> Void
    ) async throws -> DiskNode {
        let result: DiskScanResult = try await scanDirectoryStreaming(
            path: path,
            maxDepth: maxDepth
        ) { snapshot in
            await onProgress(snapshot.root, snapshot.progress)
        }
        return result.root
    }

    private func fillNode(
        _ node: MutableDiskNode,
        maxDepth: Int,
        depth: Int,
        state: ScanRunState
    ) async throws {
        try Task.checkCancellation()

        if depth >= maxDepth {
            let size = try await nativeDirectorySize(path: node.path, state: state)
            state.update { _ in
                node.truncated = true
                node.size = size
            }
            await state.emit()
            return
        }

        state.update { progress in
            progress.currentPath = node.path
        }
        await state.emit()

        let entries: [DirectoryEntry]
        do {
            entries = try await directoryEntries(atPath: node.path, state: state)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            state.update { progress in
                progress.dirsCompleted += 1
                progress.inaccessibleDirs += 1
                progress.currentPath = node.path
            }
            await state.emit()
            return
        }

        let directories = entries.filter(\.isDirectory)
        let files = entries.filter(\.isRegularFile)

        state.update { progress in
            progress.dirsFound += directories.count
        }
        state.record(files: files, currentPath: node.path)

        var children = ChildAccumulator(
            parentPath: node.path,
            limit: childLimit(forDepth: depth),
            slack: accumulatorSlack
        )

        try await withThrowingTaskGroup(of: DirectoryScanResult.self) { group in
            var nextDirectoryIndex = 0
            var activeDirectoryScans = 0
            var scheduledSinceEmit = false

            func scheduleNextDirectoryScan() {
                guard nextDirectoryIndex < directories.count else { return }
                let entry = directories[nextDirectoryIndex]
                nextDirectoryIndex += 1
                activeDirectoryScans += 1

                let child = MutableDiskNode.directory(path: entry.path, name: entry.name)
                children.addPending(child)
                sync(node: node, children: children, state: state)
                scheduledSinceEmit = true

                group.addTask { [state] in
                    do {
                        try await self.fillNode(
                            child,
                            maxDepth: maxDepth,
                            depth: depth + 1,
                            state: state
                        )
                        return .completed(child)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return .failed(child)
                    }
                }
            }

            while activeDirectoryScans < maxConcurrentChildScans,
                  nextDirectoryIndex < directories.count {
                scheduleNextDirectoryScan()
            }

            if scheduledSinceEmit {
                scheduledSinceEmit = false
                await state.emit()
            }

            var filesSinceSync = 0
            for entry in files {
                try Task.checkCancellation()

                let child = MutableDiskNode.file(
                    path: entry.path,
                    name: entry.name,
                    size: entry.fileSize
                )
                children.add(child)
                filesSinceSync += 1

                if filesSinceSync >= fileSyncBatchSize || children.shouldPrune {
                    children.enforceLimit()
                    sync(node: node, children: children, state: state)
                    await state.emit()
                    filesSinceSync = 0
                }
            }

            if filesSinceSync > 0 {
                children.enforceLimit()
                sync(node: node, children: children, state: state)
                await state.emit()
            }

            while activeDirectoryScans > 0 {
                guard let result = try await group.next() else { break }
                activeDirectoryScans -= 1

                switch result {
                case .completed(let child):
                    children.finishPending(child)
                case .failed(let child):
                    children.remove(child)
                }

                children.enforceLimit()
                sync(node: node, children: children, state: state)
                await state.emit()

                while activeDirectoryScans < maxConcurrentChildScans,
                      nextDirectoryIndex < directories.count {
                    scheduleNextDirectoryScan()
                }

                if scheduledSinceEmit {
                    scheduledSinceEmit = false
                    await state.emit()
                }
            }
        }

        children.enforceLimit()
        sync(node: node, children: children, state: state)
        state.update { progress in
            progress.dirsCompleted += 1
        }
        await state.emit()
    }

    private func directoryEntries(atPath path: String, state: ScanRunState) async throws -> [DirectoryEntry] {
        try await state.withDirectoryReadPermit {
            try directoryEntries(atPath: path)
        }
    }

    private func directoryEntries(atPath path: String) throws -> [DirectoryEntry] {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isVolumeKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileSizeKey,
            .totalFileAllocatedSizeKey
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
            guard Self.shouldScanURL(
                path: entryURL.standardizedFileURL.path,
                isSymbolicLink: values.isSymbolicLink,
                isVolume: values.isVolume,
                isScanRoot: false
            ) else {
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
                fileSize: Int64(
                    max(
                        0,
                        values.totalFileAllocatedSize
                        ?? values.fileAllocatedSize
                        ?? values.totalFileSize
                        ?? values.fileSize
                        ?? 0
                    )
                )
            )
        }
    }

    static func shouldScanURL(
        path: String? = nil,
        isSymbolicLink: Bool?,
        isVolume: Bool?,
        isScanRoot: Bool
    ) -> Bool {
        guard isSymbolicLink != true else { return false }
        // `/.nofollow` is macOS's hidden physical-root mirror. Foundation reports
        // it as a volume when queried directly, but its prefetched directory value
        // is false. Traversing it duplicates /Users, /Library, and other firmlinks.
        if !isScanRoot, path == "/.nofollow" || path == "/.nofollow/" {
            return false
        }
        return isScanRoot || isVolume != true
    }

    private func nativeDirectorySize(path: String, state: ScanRunState) async throws -> Int64 {
        var totalSize: Int64 = 0
        var pendingDirectories = [path]

        while let currentPath = pendingDirectories.popLast() {
            try Task.checkCancellation()
            state.update { progress in
                progress.currentPath = currentPath
            }
            await state.emit()

            let entries: [DirectoryEntry]
            do {
                entries = try await directoryEntries(atPath: currentPath, state: state)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                state.update { progress in
                    progress.dirsCompleted += 1
                    progress.inaccessibleDirs += 1
                    progress.currentPath = currentPath
                }
                await state.emit()
                continue
            }

            let directories = entries.filter(\.isDirectory)
            let files = entries.filter(\.isRegularFile)
            pendingDirectories.append(contentsOf: directories.map(\.path))
            totalSize += files.reduce(Int64(0)) { $0 + $1.fileSize }

            state.update { progress in
                progress.dirsFound += directories.count
                progress.dirsCompleted += 1
            }
            state.record(files: files, currentPath: currentPath)
            await state.emit()
        }

        return totalSize
    }

    private func normalizedScanPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed.isEmpty ? "/" : trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private func childLimit(forDepth depth: Int) -> Int {
        depth >= childLimitDepth ? maxChildren : maxShallowChildren
    }

    private func sync(node: MutableDiskNode, children: ChildAccumulator, state: ScanRunState) {
        state.update { _ in
            node.children = children.materialize()
            node.size = children.size
        }
    }
}

private enum DirectoryScanResult {
    case completed(MutableDiskNode)
    case failed(MutableDiskNode)
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
    let snapshotInterval: TimeInterval
    let onProgress: (ScanSnapshot) async -> Void
    private var progress: ScanProgress
    private var largestFiles = LargestFileAccumulator(limit: 100)
    private var lastEmit = Date.distantPast
    private var emittedVisibleSnapshot = false
    private let lock = NSRecursiveLock()
    private let directoryReadLimiter: AsyncSemaphore

    init(
        root: MutableDiskNode,
        progress: ScanProgress,
        maxConcurrentDirectoryReads: Int,
        snapshotInterval: TimeInterval,
        onProgress: @escaping (ScanSnapshot) async -> Void
    ) {
        self.root = root
        self.progress = progress
        self.snapshotInterval = snapshotInterval
        self.onProgress = onProgress
        self.directoryReadLimiter = AsyncSemaphore(value: maxConcurrentDirectoryReads)
    }

    func update(_ body: (inout ScanProgress) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&progress)
    }

    func record(files: [DirectoryEntry], currentPath: String) {
        guard !files.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        progress.filesFound += files.count
        progress.bytesFound += files.reduce(Int64(0)) { $0 + $1.fileSize }
        progress.currentPath = currentPath
        largestFiles.add(files)
    }

    func currentSnapshot() -> ScanSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ScanSnapshot(
            root: root.snapshot(),
            progress: progress,
            largestFiles: largestFiles.snapshot
        )
    }

    func withDirectoryReadPermit<T>(_ operation: () throws -> T) async throws -> T {
        try Task.checkCancellation()
        await directoryReadLimiter.wait()

        do {
            try Task.checkCancellation()
            let result = try operation()
            await directoryReadLimiter.signal()
            return result
        } catch {
            await directoryReadLimiter.signal()
            throw error
        }
    }

    func emit(force: Bool = false) async {
        if let output = snapshotForEmit(force: force) {
            await onProgress(output)
        }
    }

    private func snapshotForEmit(force: Bool) -> ScanSnapshot? {
        let now = Date()

        lock.lock()
        defer { lock.unlock() }

        let hasVisibleContent = root.size > 0
        let intervalElapsed = now.timeIntervalSince(lastEmit) >= snapshotInterval
        let firstVisibleSnapshot = hasVisibleContent && !emittedVisibleSnapshot
        guard force || intervalElapsed || firstVisibleSnapshot else {
            return nil
        }

        if hasVisibleContent {
            emittedVisibleSnapshot = true
        }
        lastEmit = now

        return ScanSnapshot(
            root: root.snapshot(),
            progress: progress,
            largestFiles: largestFiles.snapshot
        )
    }
}

private struct LargestFileAccumulator {
    var limit: Int
    private var files: [DiskNode] = []

    init(limit: Int) {
        self.limit = limit
    }

    var snapshot: [DiskNode] {
        files
    }

    mutating func add(_ entries: [DirectoryEntry]) {
        for entry in entries where entry.isRegularFile {
            add(
                DiskNode(
                    name: entry.name,
                    path: entry.path,
                    size: entry.fileSize,
                    kind: .file,
                    fileExtension: fileExtension(for: entry.name)
                )
            )
        }
    }

    private mutating func add(_ file: DiskNode) {
        guard limit > 0 else { return }
        if files.count >= limit,
           let smallest = files.last,
           !comesBefore(file, smallest) {
            return
        }

        let insertionIndex = files.firstIndex { existing in
            comesBefore(file, existing)
        } ?? files.endIndex
        files.insert(file, at: insertionIndex)

        if files.count > limit {
            files.removeLast()
        }
    }

    private func comesBefore(_ lhs: DiskNode, _ rhs: DiskNode) -> Bool {
        if lhs.size != rhs.size {
            return lhs.size > rhs.size
        }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }

    private func fileExtension(for name: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : "." + ext
    }
}

private actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.permits = max(1, value)
    }

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
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
    var slack: Int
    private var retained: [MutableDiskNode] = []
    private var pending: Set<ObjectIdentifier> = []
    private var droppedCount = 0
    private var droppedSize: Int64 = 0

    init(parentPath: String, limit: Int, slack: Int) {
        self.parentPath = parentPath
        self.limit = limit
        self.slack = slack
    }

    var size: Int64 {
        retained.reduce(Int64(0)) { $0 + $1.size } + droppedSize
    }

    var shouldPrune: Bool {
        retained.count > limit + slack
    }

    mutating func add(_ child: MutableDiskNode) {
        retained.append(child)
    }

    mutating func addPending(_ child: MutableDiskNode) {
        retained.append(child)
        pending.insert(ObjectIdentifier(child))
    }

    mutating func finishPending(_ child: MutableDiskNode) {
        pending.remove(ObjectIdentifier(child))
        enforceLimit()
    }

    mutating func remove(_ child: MutableDiskNode) {
        pending.remove(ObjectIdentifier(child))
        retained.removeAll { $0 === child }
    }

    mutating func enforceLimit() {
        let completed = retained.filter { child in
            !pending.contains(ObjectIdentifier(child))
        }
        guard completed.count > limit else { return }

        let keptCompleted = Set(
            completed
                .sorted(by: compareBySizeDescending)
                .prefix(limit)
                .map(ObjectIdentifier.init)
        )

        retained.removeAll { child in
            let id = ObjectIdentifier(child)
            guard !pending.contains(id), !keptCompleted.contains(id) else {
                return false
            }

            droppedCount += 1
            droppedSize += child.size
            return true
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
