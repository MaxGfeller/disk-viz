import AppKit
import Combine
import Foundation

protocol CleanupAnalyzing: Sendable {
    func analyze() async -> [CleanupSuggestion]
}

extension CleanupAnalyzer: CleanupAnalyzing {}

@MainActor
final class CleanupStore: ObservableObject {
    @Published var suggestions: [CleanupSuggestion] = []
    @Published var analyzing = false
    @Published var executing = false
    @Published var errorMessage: String?
    @Published var noticeMessage: String?
    @Published var pendingAction: CleanupPendingAction?
    @Published var hasAnalyzed = false

    private let analyzer: any CleanupAnalyzing
    private let dockerInspector: any DockerInspecting
    private let simulatorInspector: any SimulatorInspecting
    private let executor: any CleanupActionExecuting
    private var refreshTask: Task<Void, Never>?
    private var executionTask: Task<Void, Never>?
    private var activeRefreshID: UUID?

    init(
        analyzer: any CleanupAnalyzing = CleanupAnalyzer(),
        dockerInspector: any DockerInspecting = DockerInspector(),
        simulatorInspector: any SimulatorInspecting = SimulatorInspector(),
        executor: any CleanupActionExecuting = CleanupActionExecutor()
    ) {
        self.analyzer = analyzer
        self.dockerInspector = dockerInspector
        self.simulatorInspector = simulatorInspector
        self.executor = executor
    }

    deinit {
        refreshTask?.cancel()
        executionTask?.cancel()
    }

    var estimatedBytes: Int64 {
        suggestions.reduce(Int64(0)) { $0 + $1.estimatedBytes }
    }

    func refresh() {
        guard !executing else { return }

        refreshTask?.cancel()
        let refreshID = UUID()
        activeRefreshID = refreshID
        analyzing = true
        hasAnalyzed = false
        suggestions = []
        errorMessage = nil
        noticeMessage = nil

        refreshTask = Task { [weak self, analyzer, dockerInspector, simulatorInspector] in
            async let filesystemSuggestions = analyzer.analyze()
            async let dockerEstimate = try? dockerInspector.inspect()
            async let simulatorEstimate = try? simulatorInspector.inspect()

            var combined: [CleanupSuggestion] = []
            if let docker = await dockerEstimate {
                combined.append(Self.dockerSuggestion(docker))
            }
            guard let self, self.activeRefreshID == refreshID else { return }
            self.suggestions = combined.sorted(by: Self.suggestionOrder)

            if let simulators = await simulatorEstimate,
               simulators.unavailableDeviceCount > 0 {
                combined.append(Self.simulatorSuggestion(simulators))
            }
            guard self.activeRefreshID == refreshID else { return }
            self.suggestions = combined.sorted(by: Self.suggestionOrder)

            combined.append(contentsOf: await filesystemSuggestions)
            combined.sort(by: Self.suggestionOrder)

            guard self.activeRefreshID == refreshID else { return }
            self.suggestions = combined
            self.analyzing = false
            self.hasAnalyzed = true
            self.activeRefreshID = nil
            self.refreshTask = nil
        }
    }

    func cancelAnalysis() {
        activeRefreshID = nil
        refreshTask?.cancel()
        refreshTask = nil
        analyzing = false
        if !hasAnalyzed {
            suggestions = []
        }
    }

    func requestMoveToTrash(
        candidates: [CleanupCandidate],
        from suggestion: CleanupSuggestion
    ) {
        guard !candidates.isEmpty,
              hasAnalyzed,
              !executing,
              !analyzing,
              let currentSuggestion = suggestions.first(where: { $0.id == suggestion.id }),
              candidates.allSatisfy({ currentSuggestion.candidates.contains($0) })
        else {
            errorMessage = "Cleanup candidates changed. Refresh and review them again before continuing."
            return
        }
        let total = candidates.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        let count = candidates.count
        pendingAction = CleanupPendingAction(
            kind: .moveToTrash(candidates: candidates),
            title: "Move \(count) item\(count == 1 ? "" : "s") to Trash?",
            message: "Selected from \(suggestion.title) (about \(ByteFormatter.string(from: total))). You can restore these items from Trash. Disk space is reclaimed only after you empty Trash yourself in Finder.",
            confirmTitle: "Move to Trash",
            estimatedBytes: total
        )
    }

    func requestDockerPrune(from suggestion: CleanupSuggestion) {
        guard hasAnalyzed,
              !executing,
              !analyzing,
              suggestions.contains(suggestion)
        else { return }
        pendingAction = CleanupPendingAction(
            kind: .pruneDocker,
            title: "Permanently prune unused Docker data?",
            message: "Docker reports about \(ByteFormatter.string(from: suggestion.estimatedBytes)) reclaimable. DiskViz will run `docker system prune -a --force`, removing stopped containers, unused networks, every image not used by a container, and build cache. Volumes are never included. This cannot be undone.",
            confirmTitle: "Prune Docker Data",
            estimatedBytes: suggestion.estimatedBytes
        )
    }

    func requestDeleteUnavailableSimulators(from suggestion: CleanupSuggestion) {
        guard hasAnalyzed,
              !executing,
              !analyzing,
              suggestions.contains(suggestion)
        else { return }
        pendingAction = CleanupPendingAction(
            kind: .deleteUnavailableSimulators,
            title: "Permanently remove unavailable simulators?",
            message: "This runs `xcrun simctl delete unavailable`. It removes simulator devices whose runtimes are no longer installed (about \(ByteFormatter.string(from: suggestion.estimatedBytes))). Their app data cannot be restored from Trash.",
            confirmTitle: "Remove Simulators",
            estimatedBytes: suggestion.estimatedBytes
        )
    }

    func cancelPendingAction() {
        pendingAction = nil
    }

    func confirmPendingAction() {
        guard let action = pendingAction, !executing else { return }
        pendingAction = nil
        executing = true
        errorMessage = nil
        noticeMessage = nil

        executionTask = Task { [weak self, executor] in
            do {
                let notice: String
                switch action.kind {
                case .moveToTrash(let candidates):
                    let result = try await executor.moveToTrash(candidates: candidates)
                    if result.failedPaths.isEmpty {
                        notice = "Moved \(result.processedCount) item\(result.processedCount == 1 ? "" : "s") to Trash. Empty Trash yourself when you are ready to reclaim the space."
                    } else {
                        notice = "Moved \(result.processedCount) item\(result.processedCount == 1 ? "" : "s") to Trash; \(result.failedPaths.count) could not be moved."
                    }
                case .pruneDocker:
                    try await executor.pruneDocker()
                    notice = "Docker cleanup finished. Docker.raw may take a few seconds to return the reclaimed blocks to macOS."
                case .deleteUnavailableSimulators:
                    try await executor.deleteUnavailableSimulators()
                    notice = "Unavailable simulator cleanup finished."
                }

                guard let self else { return }
                self.executing = false
                self.executionTask = nil
                self.hasAnalyzed = false
                self.refresh()
                self.noticeMessage = notice
            } catch {
                guard let self else { return }
                self.executing = false
                self.errorMessage = error.localizedDescription
                self.executionTask = nil
            }
        }
    }

    func reveal(_ candidate: CleanupCandidate) {
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: candidate.path)
        ])
    }

    func openTrash() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
        NSWorkspace.shared.open(path)
    }

    func openDockerDesktop() {
        let dockerURL = URL(fileURLWithPath: "/Applications/Docker.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: dockerURL.path) {
            NSWorkspace.shared.open(dockerURL)
        } else {
            errorMessage = "Docker Desktop was not found in Applications."
        }
    }

    private static func dockerSuggestion(_ estimate: DockerUsageEstimate) -> CleanupSuggestion {
        let imageDetail: String
        if let allocated = estimate.diskImageAllocatedBytes {
            imageDetail = " Docker.raw currently occupies about \(ByteFormatter.string(from: allocated)); resizing its maximum is not counted because it can destroy Docker data."
        } else {
            imageDetail = " Open Docker Desktop after pruning to review its disk settings."
        }
        return CleanupSuggestion(
            category: .docker,
            title: "Unused Docker data",
            detail: "Docker reports \(estimate.reclaimableObjectCount.formatted()) unused objects reclaimable. Volumes are excluded." + imageDetail,
            estimatedBytes: estimate.reclaimableBytes,
            estimateKind: .toolReportedReclaimable,
            totalCandidateCount: estimate.reclaimableObjectCount
        )
    }

    private static func simulatorSuggestion(_ estimate: SimulatorUsageEstimate) -> CleanupSuggestion {
        CleanupSuggestion(
            category: .unavailableSimulators,
            title: "Unavailable simulators",
            detail: "\(estimate.unavailableDeviceCount.formatted()) devices refer to runtimes that are no longer installed. Removal is permanent.",
            estimatedBytes: estimate.allocatedBytes,
            totalCandidateCount: estimate.unavailableDeviceCount,
            isPartial: estimate.isSizePartial
        )
    }

    private static func suggestionOrder(_ lhs: CleanupSuggestion, _ rhs: CleanupSuggestion) -> Bool {
        if lhs.estimatedBytes != rhs.estimatedBytes {
            return lhs.estimatedBytes > rhs.estimatedBytes
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}
