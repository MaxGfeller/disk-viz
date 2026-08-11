import Foundation

enum CleanupCategory: String, CaseIterable, Hashable, Sendable {
    case oldDownloads
    case oldDiskImages
    case developerArtifacts
    case xcodeDerivedData
    case docker
    case unavailableSimulators
    case outdatedSimulatorRuntimes
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
    var canonicalPath: String
    var allocatedBytes: Int64
    var modifiedAt: Date?
    var fileResourceIdentifier: String?
    var volumeIdentifier: String?

    init(
        name: String,
        path: String,
        allocatedBytes: Int64,
        modifiedAt: Date?,
        canonicalPath: String? = nil,
        fileResourceIdentifier: String? = nil,
        volumeIdentifier: String? = nil
    ) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .fileResourceIdentifierKey,
            .volumeIdentifierKey
        ]
        let values = try? url.resourceValues(forKeys: keys)

        self.name = name
        self.path = url.path
        self.canonicalPath = canonicalPath
            ?? url.resolvingSymlinksInPath().standardizedFileURL.path
        self.allocatedBytes = max(0, allocatedBytes)
        self.modifiedAt = modifiedAt
        self.fileResourceIdentifier = fileResourceIdentifier
            ?? values?.fileResourceIdentifier.map { String(describing: $0) }
        self.volumeIdentifier = volumeIdentifier
            ?? values?.volumeIdentifier.map { String(describing: $0) }
    }
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
    case moveToTrash(candidates: [CleanupCandidate])
    case pruneDocker
    case deleteUnavailableSimulators
    case deleteOutdatedSimulatorRuntimes
}

struct CleanupPendingAction: Identifiable, Hashable, Sendable {
    var id = UUID()
    var kind: CleanupPendingActionKind
    var title: String
    var message: String
    var confirmTitle: String
    var estimatedBytes: Int64
}
