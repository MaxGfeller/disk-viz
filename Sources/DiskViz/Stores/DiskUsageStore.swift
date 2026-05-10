import AppKit
import Combine
import Foundation

@MainActor
final class DiskUsageStore: ObservableObject {
    @Published var root: DiskNode?
    @Published var loading = false
    @Published var scanning = false
    @Published var errorMessage: String?
    @Published var progress: ScanProgress?
    @Published var scanPath = "/"
    @Published var volumeInfo: DiskVolumeInfo?

    private let scanner = DiskScanner()
    private var scanTask: Task<Void, Never>?

    init(initialScanPath: String = "/") {
        self.scanPath = initialScanPath
        refreshVolumeInfo(for: initialScanPath)
    }

    deinit {
        scanTask?.cancel()
    }

    func scan(_ path: String? = nil) {
        let targetPath = normalizedInput(path ?? scanPath)
        guard !targetPath.isEmpty else { return }

        scanTask?.cancel()
        scanPath = targetPath
        refreshVolumeInfo(for: targetPath)
        root = nil
        loading = true
        scanning = true
        errorMessage = nil
        progress = nil

        scanTask = Task { [scanner] in
            do {
                let finalTree = try await scanner.scanDirectoryStreaming(path: targetPath) { [weak self] tree, progress in
                    await MainActor.run {
                        self?.root = tree
                        self?.loading = false
                        self?.progress = progress
                    }
                }

                await MainActor.run {
                    self.root = finalTree
                    self.loading = false
                    self.scanning = false
                    self.errorMessage = nil
                    self.progress = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.loading = false
                    self.scanning = false
                }
            } catch {
                await MainActor.run {
                    self.loading = false
                    self.scanning = false
                    self.errorMessage = error.localizedDescription
                    self.progress = nil
                }
            }
        }
    }

    func chooseDirectoryAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: scanPath)

        if panel.runModal() == .OK, let url = panel.url {
            scan(url.path)
        }
    }

    func delete(_ node: DiskNode) {
        do {
            try FileManager.default.removeItem(atPath: node.path)
            if let currentRoot = root {
                root = TreeOperations.removeNode(from: currentRoot, targetPath: node.path)
            }
            refreshVolumeInfo()
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    func refreshVolumeInfo(for path: String? = nil) {
        let targetPath = normalizedInput(path ?? scanPath)
        volumeInfo = targetPath.isEmpty ? nil : DiskSpaceReader.volumeInfo(for: targetPath)
    }

    private func normalizedInput(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return (trimmed as NSString).expandingTildeInPath
    }
}
