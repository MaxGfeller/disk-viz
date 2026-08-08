import Foundation

enum CleanupCategory: String, CaseIterable, Hashable, Sendable {
    case oldDownloads
    case oldDiskImages
    case developerArtifacts
    case xcodeDerivedData
    case docker
    case unavailableSimulators
    case trash
}

enum CleanupEstimateKind: Hashable, Sendable {
    case eligibleAllocated
    case toolReportedReclaimable
    case currentlyInTrash
}

struct CleanupCandidate: Identifiable, Hashable, Sendable {
    var id: String { path }

    var name: String
    var path: String
    var allocatedBytes: Int64
    var modifiedAt: Date?
}

struct CleanupSuggestion: Identifiable, Hashable, Sendable {
    var id: CleanupCategory { category }

    var category: CleanupCategory
    var title: String
    var detail: String
    var estimatedBytes: Int64
    var estimateKind: CleanupEstimateKind
    var totalCandidateCount: Int
    var candidates: [CleanupCandidate]
    var inaccessibleCount: Int
    var isPartial: Bool

    init(
        category: CleanupCategory,
        title: String,
        detail: String,
        estimatedBytes: Int64,
        estimateKind: CleanupEstimateKind = .eligibleAllocated,
        totalCandidateCount: Int = 0,
        candidates: [CleanupCandidate] = [],
        inaccessibleCount: Int = 0,
        isPartial: Bool = false
    ) {
        self.category = category
        self.title = title
        self.detail = detail
        self.estimatedBytes = max(0, estimatedBytes)
        self.estimateKind = estimateKind
        self.totalCandidateCount = max(totalCandidateCount, candidates.count)
        self.candidates = candidates
        self.inaccessibleCount = max(0, inaccessibleCount)
        self.isPartial = isPartial
    }
}

enum CleanupPendingActionKind: Hashable, Sendable {
    case moveToTrash(paths: [String])
    case pruneDocker
    case deleteUnavailableSimulators
}

struct CleanupPendingAction: Identifiable, Hashable, Sendable {
    var id = UUID()
    var kind: CleanupPendingActionKind
    var title: String
    var message: String
    var confirmTitle: String
    var estimatedBytes: Int64
}
