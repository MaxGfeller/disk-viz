import Foundation

struct CleanupExecutionResult: Equatable, Sendable {
    var processedCount: Int
    var failedPaths: [String]
}

protocol CleanupActionExecuting: Sendable {
    func moveToTrash(candidates: [CleanupCandidate]) async throws -> CleanupExecutionResult
    func pruneDocker() async throws
    func deleteUnavailableSimulators() async throws
}

struct CleanupActionExecutor: CleanupActionExecuting {
    private let dockerInspector: any DockerInspecting
    private let simulatorInspector: any SimulatorInspecting

    init(
        dockerInspector: any DockerInspecting = DockerInspector(),
        simulatorInspector: any SimulatorInspecting = SimulatorInspector()
    ) {
        self.dockerInspector = dockerInspector
        self.simulatorInspector = simulatorInspector
    }

    func moveToTrash(candidates: [CleanupCandidate]) async throws -> CleanupExecutionResult {
        return await Task.detached(priority: .userInitiated) {
            var processedCount = 0
            var failedPaths: [String] = []

            for candidate in candidates {
                do {
                    // Revalidate immediately before the filesystem operation so a path
                    // replaced after review cannot redirect cleanup to a different item.
                    let path = try Self.validatedTrashPath(candidate)
                    try FileManager.default.trashItem(
                        at: URL(fileURLWithPath: path),
                        resultingItemURL: nil
                    )
                    processedCount += 1
                } catch {
                    failedPaths.append(candidate.path)
                }
            }

            return CleanupExecutionResult(
                processedCount: processedCount,
                failedPaths: failedPaths
            )
        }.value
    }

    func pruneDocker() async throws {
        try await dockerInspector.executePrune()
    }

    func deleteUnavailableSimulators() async throws {
        try await simulatorInspector.executeDeleteUnavailable()
    }

    static func validatedTrashPath(_ candidate: CleanupCandidate) throws -> String {
        let url = URL(fileURLWithPath: candidate.path).standardizedFileURL
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let home = homeURL.path
        let keys: Set<URLResourceKey> = [
            .isSymbolicLinkKey,
            .isVolumeKey,
            .fileResourceIdentifierKey,
            .volumeIdentifierKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let currentFileIdentifier = values.fileResourceIdentifier
                .map({ String(describing: $0) }),
              let currentVolumeIdentifier = values.volumeIdentifier
                .map({ String(describing: $0) }),
              let homeVolumeIdentifier = (try? homeURL.resourceValues(forKeys: [.volumeIdentifierKey]))?
                .volumeIdentifier
                .map({ String(describing: $0) }),
              !url.path.isEmpty,
              canonical == candidate.canonicalPath,
              canonical.hasPrefix(home.hasSuffix("/") ? home : home + "/"),
              canonical != home,
              values.isSymbolicLink != true,
              values.isVolume != true,
              currentFileIdentifier == candidate.fileResourceIdentifier,
              currentVolumeIdentifier == candidate.volumeIdentifier,
              currentVolumeIdentifier == homeVolumeIdentifier,
              FileManager.default.fileExists(atPath: url.path)
        else {
            throw CleanupActionExecutorError.invalidPath(candidate.path)
        }
        return url.path
    }
}

enum CleanupActionExecutorError: LocalizedError {
    case invalidPath(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            return "DiskViz refused to move an unsafe or missing path to Trash: \(path)"
        }
    }
}
