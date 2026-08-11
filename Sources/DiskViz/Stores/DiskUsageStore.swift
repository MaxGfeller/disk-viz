import AppKit
import Combine
import Foundation

private enum DetailScanPhase: Equatable {
    case queued
    case loading
    case partial
    case complete
    case failed
}

@MainActor
final class DiskUsageStore: ObservableObject {
    @Published var root: DiskNode?
    @Published var largestFiles: [DiskNode] = []
    @Published var largestFilesByFolder: [String: [DiskNode]] = [:]
    @Published var progress: ScanProgress?
    @Published var loading = false
    @Published var scanning = false
    @Published private(set) var sourceScanning = false
    @Published private(set) var expandingPath: String?
    @Published private(set) var sourceScanGeneration = UUID()
    @Published var errorMessage: String?
    @Published var scanPath = "/"
    @Published var volumeInfo: DiskVolumeInfo?
    @Published var scanSources: [ScanSource] = []
    @Published var selectedSource: ScanSource?
    @Published var scanStopped = false

    private let scanner = DiskScanner()
    private var scanTask: Task<Void, Never>?
    private var activeScanID: UUID?
    private var detailScanTasks: [String: Task<Void, Never>] = [:]
    private var activeDetailScanIDs: [String: UUID] = [:]
    private var detailScanPhases: [String: DetailScanPhase] = [:]
    private var detailErrors: [String: String] = [:]
    private var detailActivityOrder: [String] = []
    private let maxConcurrentDetailScans = 2

    private var baseRoot: DiskNode?
    private var baseLargestFiles: [DiskNode] = []
    private var baseLargestFilesByFolder: [String: [DiskNode]] = [:]
    private var detailRoots: [String: DiskNode] = [:]
    private var detailAncestries: [String: [DiskNode]] = [:]
    private var detailLargestFilesByExpansion: [String: [String: [DiskNode]]] = [:]
    private var detailCacheOrder: [String] = []
    private let detailCacheLimit = 16

    init(initialScanPath: String = "/") {
        let targetPath = normalizedInput(initialScanPath)
        let discovery = VolumeCatalog.discover()
        let discoveredMatch = discovery.sources.first { source in
            source.path == targetPath
        }
        var isDirectory = ObjCBool(false)
        let isExistingDirectory = FileManager.default.fileExists(
            atPath: targetPath,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
        let initialSource = discoveredMatch
            ?? (isExistingDirectory ? VolumeCatalog.customFolderSource(path: targetPath) : nil)
            ?? discovery.defaultSource

        scanSources = discovery.sources
        if let initialSource, initialSource.kind == .customFolder {
            scanSources.append(initialSource)
        }
        selectedSource = initialSource
        scanPath = initialSource?.path ?? (targetPath.isEmpty ? "/" : targetPath)
        refreshVolumeInfo()
    }

    deinit {
        activeScanID = nil
        scanTask?.cancel()
        for task in detailScanTasks.values {
            task.cancel()
        }
    }

    func selectAndScan(_ source: ScanSource) {
        retainCustomSourceIfNeeded(source)
        selectedSource = source
        scan(source.path)
    }

    func refreshScanSources() {
        let discovery = VolumeCatalog.discover()
        let previousSelection = selectedSource
        var refreshedSources = discovery.sources

        if let previousSelection, previousSelection.kind == .customFolder {
            let refreshedFolder = VolumeCatalog.customFolderSource(
                path: previousSelection.path,
                name: previousSelection.name
            )
            refreshedSources.append(refreshedFolder)
            selectedSource = refreshedFolder
        } else if let previousSelection,
                  let refreshedSelection = refreshedSources.first(where: { $0.id == previousSelection.id }) {
            selectedSource = refreshedSelection
        } else {
            selectedSource = discovery.defaultSource
        }

        scanSources = refreshedSources
        if let selectedSource, !scanning {
            scanPath = selectedSource.path
            refreshVolumeInfo()
        }
    }

    func chooseDirectoryAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: scanPath, isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            let normalizedPath = normalizedInput(url.path)
            let source = scanSources.first { $0.path == normalizedPath }
                ?? VolumeCatalog.customFolderSource(path: normalizedPath)
            selectAndScan(source)
        }
    }

    func scan(_ path: String? = nil) {
        let targetPath = normalizedInput(path ?? scanPath)
        guard !targetPath.isEmpty else { return }

        activeScanID = nil
        scanTask?.cancel()
        cancelAllDetailScans(clearCachedState: true)

        let scanID = UUID()
        activeScanID = scanID
        sourceScanGeneration = UUID()
        scanPath = targetPath
        selectSource(matching: targetPath)
        refreshVolumeInfo(for: targetPath)
        baseRoot = nil
        baseLargestFiles = []
        baseLargestFilesByFolder = [:]
        detailRoots = [:]
        detailAncestries = [:]
        detailLargestFilesByExpansion = [:]
        detailCacheOrder = []
        root = nil
        largestFiles = []
        largestFilesByFolder = [:]
        loading = true
        sourceScanning = true
        expandingPath = nil
        refreshScanningState()
        scanStopped = false
        errorMessage = nil
        progress = nil

        scanTask = Task { [weak self, scanner] in
            do {
                let result = try await scanner.scanDirectoryStreaming(path: targetPath) { snapshot in
                    await MainActor.run {
                        guard let self, self.activeScanID == scanID else { return }
                        self.apply(snapshot)
                    }
                }

                await MainActor.run {
                    guard let self, self.activeScanID == scanID else { return }
                    self.apply(result)
                    self.sourceScanning = false
                    self.scanStopped = false
                    self.errorMessage = nil
                    self.activeScanID = nil
                    self.scanTask = nil
                    self.refreshScanningState()
                    self.refreshVolumeInfo()
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self, self.activeScanID == scanID else { return }
                    self.sourceScanning = false
                    self.scanStopped = true
                    self.activeScanID = nil
                    self.scanTask = nil
                    self.refreshScanningState()
                }
            } catch {
                await MainActor.run {
                    guard let self, self.activeScanID == scanID else { return }
                    self.sourceScanning = false
                    self.scanStopped = false
                    self.errorMessage = error.localizedDescription
                    self.activeScanID = nil
                    self.scanTask = nil
                    self.refreshScanningState()
                }
            }
        }
    }

    func expand(_ path: String) {
        let targetPath = normalizedInput(path)
        guard
            !targetPath.isEmpty,
            let currentRoot = root,
            let target = TreeOperations.node(in: currentRoot, atPath: targetPath),
            target.isDirectory
        else {
            return
        }

        if activeDetailScanIDs[targetPath] != nil {
            return
        }

        let detailScanID = UUID()
        activeDetailScanIDs[targetPath] = detailScanID
        detailScanPhases[targetPath] = .queued
        detailErrors.removeValue(forKey: targetPath)
        detailActivityOrder.removeAll { $0 == targetPath }
        detailActivityOrder.append(targetPath)
        expandingPath = targetPath
        detailRoots[targetPath] = target
        detailAncestries[targetPath] = TreeOperations.buildZoomPath(
            root: currentRoot,
            targetPath: targetPath
        )
        touchDetailCache(targetPath)
        trimDetailCache()
        refreshScanningState()
        refreshPresentedState()
        startQueuedDetailScans()
    }

    private func startQueuedDetailScans() {
        while detailScanTasks.count < maxConcurrentDetailScans {
            guard let targetPath = detailActivityOrder.first(where: { path in
                detailScanPhases[path] == .queued && activeDetailScanIDs[path] != nil
            }), let detailScanID = activeDetailScanIDs[targetPath] else {
                return
            }

            let sourceGeneration = sourceScanGeneration
            let targetName = detailRoots[targetPath]?.name
                ?? URL(fileURLWithPath: targetPath).lastPathComponent
            detailScanPhases[targetPath] = .loading

            let detailScanner = DiskScanner(
                maxConcurrentChildScans: 2,
                maxConcurrentDirectoryReads: 2
            )
            detailScanTasks[targetPath] = Task { [weak self, detailScanner] in
                do {
                    let result = try await detailScanner.scanDirectoryStreaming(
                        path: targetPath,
                        maxDepth: 1
                    ) { snapshot in
                        await MainActor.run {
                            guard
                                let self,
                                self.sourceScanGeneration == sourceGeneration,
                                self.activeDetailScanIDs[targetPath] == detailScanID
                            else {
                                return
                            }
                            self.applyDetail(snapshot, atPath: targetPath, isFinal: false)
                        }
                    }

                    await MainActor.run {
                        guard
                            let self,
                            self.sourceScanGeneration == sourceGeneration,
                            self.activeDetailScanIDs[targetPath] == detailScanID
                        else {
                            return
                        }
                        self.applyDetail(result, atPath: targetPath)
                        self.finishDetailScan(
                            atPath: targetPath,
                            id: detailScanID,
                            phase: .complete
                        )
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        guard
                            let self,
                            self.sourceScanGeneration == sourceGeneration,
                            self.activeDetailScanIDs[targetPath] == detailScanID
                        else {
                            return
                        }
                        self.finishDetailScan(
                            atPath: targetPath,
                            id: detailScanID,
                            phase: .partial
                        )
                    }
                } catch {
                    await MainActor.run {
                        guard
                            let self,
                            self.sourceScanGeneration == sourceGeneration,
                            self.activeDetailScanIDs[targetPath] == detailScanID
                        else {
                            return
                        }
                        self.detailErrors[targetPath] = "Couldn’t open \(targetName): \(error.localizedDescription)"
                        self.finishDetailScan(
                            atPath: targetPath,
                            id: detailScanID,
                            phase: .failed
                        )
                    }
                }
            }
        }
    }

    func stopScan() {
        guard scanning || loading else { return }

        let stoppedSourceScan = sourceScanning
        activeScanID = nil
        scanTask?.cancel()
        scanTask = nil
        sourceScanning = false
        cancelAllDetailScans(clearCachedState: false)
        loading = false
        refreshScanningState()
        if stoppedSourceScan {
            scanStopped = true
        }
    }

    func largestFiles(in folderPath: String?) -> [DiskNode] {
        guard let root else { return [] }
        let targetPath = normalizedInput(folderPath ?? root.path)
        if targetPath == root.path {
            return largestFiles
        }
        return largestFilesByFolder[targetPath] ?? []
    }

    func hasLargestFilesIndex(for folderPath: String?) -> Bool {
        guard let root else { return false }
        let targetPath = normalizedInput(folderPath ?? root.path)
        return targetPath == root.path || largestFilesByFolder.keys.contains(targetPath)
    }

    func isExpanding(_ path: String) -> Bool {
        switch detailScanPhases[normalizedInput(path)] {
        case .queued, .loading:
            return true
        case .partial, .complete, .failed, .none:
            return false
        }
    }

    var runningDetailScanCount: Int {
        detailScanTasks.count
    }

    func hasIncompleteDetails(for path: String) -> Bool {
        switch detailScanPhases[normalizedInput(path)] {
        case .partial, .failed:
            return true
        case .queued, .loading, .complete, .none:
            return false
        }
    }

    func detailError(for path: String) -> String? {
        detailErrors[normalizedInput(path)]
    }

    func needsExpansion(for node: DiskNode) -> Bool {
        guard node.isDirectory else { return false }

        switch detailScanPhases[node.path] {
        case .queued, .loading, .complete:
            return false
        case .partial, .failed:
            return true
        case .none:
            return !node.hasChildren && (node.truncated || sourceScanning)
        }
    }

    func revealInFinder(_ node: DiskNode) {
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: node.path)
        ])
    }

    func moveToTrash(_ node: DiskNode) {
        guard !scanning else {
            errorMessage = "Stop the scan before moving an item to Trash."
            return
        }

        if let restriction = FileActionPolicy.manualDeletionRestriction(for: node.path) {
            errorMessage = restriction
            return
        }

        do {
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: node.path),
                resultingItemURL: nil
            )

            if let baseRoot {
                self.baseRoot = TreeOperations.removeNode(from: baseRoot, targetPath: node.path)
            }
            baseLargestFiles.removeAll { candidate in
                isSameOrDescendant(candidate.path, of: node.path)
            }
            removeFiles(atOrBelow: node.path, from: &baseLargestFilesByFolder)

            detailRoots = detailRoots.compactMapValues { detailRoot in
                TreeOperations.removeNode(from: detailRoot, targetPath: node.path)
            }
            detailRoots = detailRoots.filter { path, _ in
                !isSameOrDescendant(path, of: node.path)
            }
            detailAncestries = detailAncestries.filter { path, _ in
                !isSameOrDescendant(path, of: node.path)
            }
            detailLargestFilesByExpansion = detailLargestFilesByExpansion.filter { path, _ in
                !isSameOrDescendant(path, of: node.path)
            }
            for expansionPath in Array(detailLargestFilesByExpansion.keys) {
                guard var filesByFolder = detailLargestFilesByExpansion[expansionPath] else {
                    continue
                }
                removeFiles(atOrBelow: node.path, from: &filesByFolder)
                detailLargestFilesByExpansion[expansionPath] = filesByFolder
            }
            detailCacheOrder.removeAll { path in
                isSameOrDescendant(path, of: node.path)
            }
            detailScanPhases = detailScanPhases.filter { path, _ in
                !isSameOrDescendant(path, of: node.path)
            }
            detailErrors = detailErrors.filter { path, _ in
                !isSameOrDescendant(path, of: node.path)
            }

            refreshPresentedState()
            errorMessage = nil
            refreshVolumeInfo()
            refreshScanSources()
        } catch {
            errorMessage = "Move to Trash failed: \(error.localizedDescription)"
        }
    }

    func refreshVolumeInfo(for path: String? = nil) {
        let targetPath = normalizedInput(path ?? scanPath)
        volumeInfo = targetPath.isEmpty ? nil : DiskSpaceReader.volumeInfo(for: targetPath)
    }

    private func apply(_ snapshot: ScanSnapshot) {
        progress = snapshot.progress
        baseLargestFiles = snapshot.largestFiles
        baseLargestFilesByFolder = snapshot.largestFilesByFolder

        if snapshot.root.size > 0 || snapshot.progress.dirsCompleted >= snapshot.progress.dirsFound {
            baseRoot = snapshot.root
            loading = false
        }
        refreshPresentedState()
    }

    private func apply(_ result: DiskScanResult) {
        baseRoot = result.root
        baseLargestFiles = result.largestFiles
        baseLargestFilesByFolder = result.largestFilesByFolder
        progress = result.progress
        loading = false
        refreshPresentedState()
    }

    private func applyDetail(
        _ snapshot: ScanSnapshot,
        atPath targetPath: String,
        isFinal: Bool
    ) {
        var replacement = snapshot.root
        let previous = detailRoots[targetPath]
            ?? root.flatMap { TreeOperations.node(in: $0, atPath: targetPath) }

        let detailComplete = snapshot.progress.dirsCompleted >= snapshot.progress.dirsFound
        let hasVisibleDetail = replacement.hasChildren || replacement.size > 0
        if !isFinal, !detailComplete, !hasVisibleDetail {
            detailLargestFilesByExpansion[targetPath] = snapshot.largestFilesByFolder
            refreshPresentedState()
            return
        }

        if !isFinal, let previous {
            replacement.size = max(previous.size, replacement.size)
        }

        detailRoots[targetPath] = replacement
        detailLargestFilesByExpansion[targetPath] = snapshot.largestFilesByFolder
        touchDetailCache(targetPath)
        trimDetailCache()
        refreshPresentedState()
    }

    private func applyDetail(_ result: DiskScanResult, atPath targetPath: String) {
        detailRoots[targetPath] = result.root
        detailLargestFilesByExpansion[targetPath] = result.largestFilesByFolder
        touchDetailCache(targetPath)
        trimDetailCache()
        refreshPresentedState()
    }

    private func finishDetailScan(
        atPath path: String,
        id: UUID,
        phase: DetailScanPhase
    ) {
        guard activeDetailScanIDs[path] == id else { return }
        activeDetailScanIDs.removeValue(forKey: path)
        detailScanTasks.removeValue(forKey: path)
        detailScanPhases[path] = phase
        detailActivityOrder.removeAll { $0 == path }
        startQueuedDetailScans()
        expandingPath = detailActivityOrder.last
        refreshScanningState()
    }

    private func cancelAllDetailScans(clearCachedState: Bool) {
        let activePaths = Array(activeDetailScanIDs.keys)
        activeDetailScanIDs.removeAll()
        for task in detailScanTasks.values {
            task.cancel()
        }
        detailScanTasks.removeAll()
        detailActivityOrder.removeAll()
        expandingPath = nil

        if clearCachedState {
            detailScanPhases.removeAll()
            detailErrors.removeAll()
        } else {
            for path in activePaths {
                detailScanPhases[path] = .partial
            }
        }
    }

    private func refreshScanningState() {
        scanning = sourceScanning || !activeDetailScanIDs.isEmpty
        if !sourceScanning {
            loading = false
        }
    }

    private func refreshPresentedState() {
        guard var composedRoot = baseRoot else {
            root = nil
            largestFiles = []
            largestFilesByFolder = [:]
            return
        }

        let orderedExpansionPaths = detailRoots.keys.sorted(by: comparePathDepth)

        for path in orderedExpansionPaths {
            guard let detailRoot = detailRoots[path] else { continue }
            if let ancestry = detailAncestries[path],
               let pinnedRoot = TreeOperations.pinningBranch(
                   in: composedRoot,
                   ancestry: ancestry
               ) {
                composedRoot = pinnedRoot
            }

            if let baseNode = TreeOperations.node(in: composedRoot, atPath: path),
               baseNode.hasChildren,
               !detailRoot.hasChildren {
                continue
            }

            guard let updated = TreeOperations.replacingNode(
                in: composedRoot,
                atPath: path,
                with: detailRoot
            ) else {
                continue
            }
            composedRoot = updated
        }

        var scopedFiles = baseLargestFilesByFolder
        for path in detailLargestFilesByExpansion.keys.sorted(by: comparePathDepth) {
            guard let detailScopes = detailLargestFilesByExpansion[path] else { continue }
            scopedFiles.merge(detailScopes) { _, detailFiles in detailFiles }
        }

        let mergedGlobalFiles = mergeLargestFiles(
            baseLargestFiles,
            with: detailLargestFilesByExpansion.compactMap { path, scopes in
                scopes[path]
            }
        )
        scopedFiles[composedRoot.path] = mergedGlobalFiles

        root = composedRoot
        largestFiles = mergedGlobalFiles
        largestFilesByFolder = scopedFiles
    }

    private func mergeLargestFiles(
        _ base: [DiskNode],
        with detailLists: [[DiskNode]],
        limit: Int = 100
    ) -> [DiskNode] {
        var filesByPath = Dictionary(uniqueKeysWithValues: base.map { ($0.path, $0) })
        for file in detailLists.flatMap({ $0 }) {
            filesByPath[file.path] = file
        }

        return filesByPath.values.sorted { lhs, rhs in
            if lhs.size != rhs.size {
                return lhs.size > rhs.size
            }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
        .prefix(limit)
        .map { $0 }
    }

    private func removeFiles(
        atOrBelow targetPath: String,
        from filesByFolder: inout [String: [DiskNode]]
    ) {
        filesByFolder = filesByFolder.compactMapValues { files in
            files.filter { candidate in
                !isSameOrDescendant(candidate.path, of: targetPath)
            }
        }
        filesByFolder = filesByFolder.filter { path, _ in
            !isSameOrDescendant(path, of: targetPath)
        }
    }

    private func touchDetailCache(_ path: String) {
        detailCacheOrder.removeAll { $0 == path }
        detailCacheOrder.append(path)
    }

    private func trimDetailCache() {
        while detailRoots.count > detailCacheLimit {
            guard let evictionPath = detailCacheOrder.first(where: { candidate in
                activeDetailScanIDs[candidate] == nil
                    && !detailRoots.keys.contains(where: { otherPath in
                        otherPath != candidate
                            && isSameOrDescendant(otherPath, of: candidate)
                    })
            }) else {
                return
            }

            detailCacheOrder.removeAll { $0 == evictionPath }
            detailRoots.removeValue(forKey: evictionPath)
            detailAncestries.removeValue(forKey: evictionPath)
            detailLargestFilesByExpansion.removeValue(forKey: evictionPath)
            detailScanPhases.removeValue(forKey: evictionPath)
            detailErrors.removeValue(forKey: evictionPath)
        }
    }

    private func comparePathDepth(_ lhs: String, _ rhs: String) -> Bool {
        let lhsDepth = URL(fileURLWithPath: lhs).pathComponents.count
        let rhsDepth = URL(fileURLWithPath: rhs).pathComponents.count
        if lhsDepth != rhsDepth {
            return lhsDepth < rhsDepth
        }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private func selectSource(matching path: String) {
        if let source = scanSources.first(where: { $0.path == path }) {
            selectedSource = source
            return
        }

        let customSource = VolumeCatalog.customFolderSource(path: path)
        retainCustomSourceIfNeeded(customSource)
        selectedSource = customSource
    }

    private func retainCustomSourceIfNeeded(_ source: ScanSource) {
        guard source.kind == .customFolder else { return }

        scanSources.removeAll { candidate in
            candidate.kind == .customFolder && candidate.id != source.id
        }
        if !scanSources.contains(where: { $0.id == source.id }) {
            scanSources.append(source)
        }
    }

    private func normalizedInput(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }

    private func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        if path == ancestor {
            return true
        }
        if ancestor == "/" {
            return path.hasPrefix("/")
        }
        return path.hasPrefix(ancestor + "/")
    }
}
