import AppKit
import Combine
import Foundation

@MainActor
final class DiskUsageStore: ObservableObject {
    @Published var root: DiskNode?
    @Published var largestFiles: [DiskNode] = []
    @Published var progress: ScanProgress?
    @Published var loading = false
    @Published var scanning = false
    @Published var errorMessage: String?
    @Published var scanPath = "/"
    @Published var volumeInfo: DiskVolumeInfo?
    @Published var scanSources: [ScanSource] = []
    @Published var selectedSource: ScanSource?
    @Published var scanStopped = false

    private let scanner = DiskScanner()
    private var scanTask: Task<Void, Never>?
    private var activeScanID: UUID?

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

        let scanID = UUID()
        activeScanID = scanID
        scanPath = targetPath
        selectSource(matching: targetPath)
        refreshVolumeInfo(for: targetPath)
        root = nil
        largestFiles = []
        loading = true
        scanning = true
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
                    self.loading = false
                    self.scanning = false
                    self.scanStopped = false
                    self.errorMessage = nil
                    self.activeScanID = nil
                    self.scanTask = nil
                    self.refreshVolumeInfo()
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self, self.activeScanID == scanID else { return }
                    self.loading = false
                    self.scanning = false
                    self.scanStopped = true
                    self.activeScanID = nil
                    self.scanTask = nil
                }
            } catch {
                await MainActor.run {
                    guard let self, self.activeScanID == scanID else { return }
                    self.loading = false
                    self.scanning = false
                    self.scanStopped = false
                    self.errorMessage = error.localizedDescription
                    self.activeScanID = nil
                    self.scanTask = nil
                }
            }
        }
    }

    func stopScan() {
        guard scanning || loading else { return }

        activeScanID = nil
        scanTask?.cancel()
        scanTask = nil
        loading = false
        scanning = false
        scanStopped = true
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

        do {
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: node.path),
                resultingItemURL: nil
            )

            if let currentRoot = root {
                root = TreeOperations.removeNode(from: currentRoot, targetPath: node.path)
            }
            largestFiles.removeAll { candidate in
                isSameOrDescendant(candidate.path, of: node.path)
            }
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
        largestFiles = snapshot.largestFiles

        if snapshot.root.size > 0 || snapshot.progress.dirsCompleted >= snapshot.progress.dirsFound {
            root = snapshot.root
            loading = false
        }
    }

    private func apply(_ result: DiskScanResult) {
        root = result.root
        largestFiles = result.largestFiles
        progress = result.progress
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
