@testable import DiskViz
import XCTest

final class CleanupStoreTests: XCTestCase {
    func testExecutorRejectsBroadSystemCandidateBeforeAnyTrashOperation() {
        let applications = CleanupCandidate(
            name: "Applications",
            path: "/Applications",
            allocatedBytes: 1,
            modifiedAt: nil
        )

        XCTAssertThrowsError(
            try CleanupActionExecutor.validatedTrashPath(applications)
        )
    }

    func testExecutorRejectsAPathWhoseIdentityChangedAfterReview() throws {
        let fileManager = FileManager.default
        let directory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".diskviz-test-\(UUID().uuidString)", isDirectory: true)
        let reviewedURL = directory.appendingPathComponent("reviewed.tmp")
        let movedURL = directory.appendingPathComponent("original.tmp")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        try Data([1]).write(to: reviewedURL)
        let candidate = CleanupCandidate(
            name: reviewedURL.lastPathComponent,
            path: reviewedURL.path,
            allocatedBytes: 1,
            modifiedAt: nil
        )
        try fileManager.moveItem(at: reviewedURL, to: movedURL)
        try Data([2]).write(to: reviewedURL)

        XCTAssertThrowsError(
            try CleanupActionExecutor.validatedTrashPath(candidate)
        )
    }

    @MainActor
    func testCleanupRequestRequiresConfirmationBeforeExecutorRuns() async throws {
        let executor = RecordingCleanupExecutor()
        let store = CleanupStore(
            analyzer: FixedCleanupAnalyzer(),
            dockerInspector: EmptyDockerInspector(),
            simulatorInspector: EmptySimulatorInspector(),
            executor: executor
        )
        let first = CleanupCandidate(
            name: "old.dmg",
            path: "/fixture/old.dmg",
            allocatedBytes: 100,
            modifiedAt: nil
        )
        let unselected = CleanupCandidate(
            name: "keep.dmg",
            path: "/fixture/keep.dmg",
            allocatedBytes: 200,
            modifiedAt: nil
        )
        let suggestion = CleanupSuggestion(
            category: .oldDiskImages,
            title: "Old disk images",
            detail: "fixture",
            estimatedBytes: 300,
            totalCandidateCount: 2,
            candidates: [first, unselected]
        )
        store.suggestions = [suggestion]
        store.hasAnalyzed = true

        store.requestMoveToTrash(candidates: [first], from: suggestion)

        XCTAssertNotNil(store.pendingAction)
        let callsBeforeConfirmation = await executor.recordedTrashCalls()
        XCTAssertTrue(callsBeforeConfirmation.isEmpty)

        store.cancelPendingAction()
        XCTAssertNil(store.pendingAction)
        let callsAfterCancel = await executor.recordedTrashCalls()
        XCTAssertTrue(callsAfterCancel.isEmpty)

        let nonmember = CleanupCandidate(
            name: "intruder.dmg",
            path: "/fixture/intruder.dmg",
            allocatedBytes: 400,
            modifiedAt: nil
        )
        store.requestMoveToTrash(candidates: [nonmember], from: suggestion)
        XCTAssertNil(store.pendingAction)
        XCTAssertNotNil(store.errorMessage)

        store.requestMoveToTrash(candidates: [first], from: suggestion)
        store.confirmPendingAction()

        for _ in 0..<50 {
            if !(await executor.recordedTrashCalls()).isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let callsAfterConfirmation = await executor.recordedTrashCalls()
        XCTAssertEqual(callsAfterConfirmation, [[first.path]])
    }

    @MainActor
    func testQuickExternalEstimatePublishesBeforeFilesystemAnalysisCompletes() async throws {
        let store = CleanupStore(
            analyzer: DelayedCleanupAnalyzer(),
            dockerInspector: ImmediateDockerInspector(),
            simulatorInspector: EmptySimulatorInspector(),
            executor: RecordingCleanupExecutor()
        )

        store.refresh()
        for _ in 0..<50 {
            if store.suggestions.contains(where: { $0.category == .docker }) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(store.analyzing)
        XCTAssertTrue(store.suggestions.contains(where: { $0.category == .docker }))
        XCTAssertFalse(store.suggestions.contains(where: { $0.category == .oldDiskImages }))

        for _ in 0..<100 {
            if !store.analyzing { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(store.analyzing)
        XCTAssertTrue(store.suggestions.contains(where: { $0.category == .oldDiskImages }))
    }

    @MainActor
    func testCancelClearsIncrementalResultsBeforeTheyCanBecomeActionable() async throws {
        let store = CleanupStore(
            analyzer: DelayedCleanupAnalyzer(),
            dockerInspector: ImmediateDockerInspector(),
            simulatorInspector: EmptySimulatorInspector(),
            executor: RecordingCleanupExecutor()
        )

        store.refresh()
        for _ in 0..<50 {
            if store.suggestions.contains(where: { $0.category == .docker }) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let incrementalDocker = try XCTUnwrap(
            store.suggestions.first(where: { $0.category == .docker })
        )

        store.cancelAnalysis()
        store.requestDockerPrune(from: incrementalDocker)

        XCTAssertFalse(store.analyzing)
        XCTAssertFalse(store.hasAnalyzed)
        XCTAssertTrue(store.suggestions.isEmpty)
        XCTAssertNil(store.pendingAction)
    }

    @MainActor
    func testOutdatedRuntimeQuickActionRequiresConfirmationAndExecutes() async throws {
        let executor = RecordingCleanupExecutor()
        let store = CleanupStore(
            analyzer: FixedCleanupAnalyzer(),
            dockerInspector: EmptyDockerInspector(),
            simulatorInspector: OutdatedSimulatorInspector(),
            executor: executor
        )

        store.refresh()
        for _ in 0..<100 {
            if !store.analyzing { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let suggestion = try XCTUnwrap(
            store.suggestions.first { $0.category == .outdatedSimulatorRuntimes }
        )
        XCTAssertEqual(suggestion.estimatedBytes, 15_000)

        store.requestDeleteOutdatedSimulatorRuntimes(from: suggestion)
        XCTAssertNotNil(store.pendingAction)
        let callsBeforeConfirmation = await executor.recordedOutdatedRuntimeDeleteCount()
        XCTAssertEqual(callsBeforeConfirmation, 0)

        store.confirmPendingAction()
        for _ in 0..<50 {
            if await executor.recordedOutdatedRuntimeDeleteCount() > 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let callsAfterConfirmation = await executor.recordedOutdatedRuntimeDeleteCount()
        XCTAssertEqual(callsAfterConfirmation, 1)
    }
}

private struct FixedCleanupAnalyzer: CleanupAnalyzing {
    func analyze() async -> [CleanupSuggestion] { [] }
}

private struct DelayedCleanupAnalyzer: CleanupAnalyzing {
    func analyze() async -> [CleanupSuggestion] {
        try? await Task.sleep(nanoseconds: 120_000_000)
        return [
            CleanupSuggestion(
                category: .oldDiskImages,
                title: "Old disk images",
                detail: "fixture",
                estimatedBytes: 100
            )
        ]
    }
}

private struct ImmediateDockerInspector: DockerInspecting {
    func inspect() async throws -> DockerUsageEstimate? {
        DockerUsageEstimate(
            reclaimableBytes: 1_000,
            reclaimableObjectCount: 1,
            diskImageAllocatedBytes: nil,
            diskImagePath: nil
        )
    }

    func executePrune() async throws {}
}

private struct EmptyDockerInspector: DockerInspecting {
    func inspect() async throws -> DockerUsageEstimate? { nil }
    func executePrune() async throws {}
}

private struct EmptySimulatorInspector: SimulatorInspecting {
    func inspect() async throws -> SimulatorUsageEstimate? { nil }
    func inspectOutdatedRuntimes() async throws -> OutdatedSimulatorRuntimeEstimate? { nil }
    func executeDeleteUnavailable() async throws {}
    func executeDeleteOutdatedRuntimes() async throws {}
}

private struct OutdatedSimulatorInspector: SimulatorInspecting {
    func inspect() async throws -> SimulatorUsageEstimate? { nil }
    func inspectOutdatedRuntimes() async throws -> OutdatedSimulatorRuntimeEstimate? {
        OutdatedSimulatorRuntimeEstimate(
            runtimeCount: 2,
            allocatedBytes: 15_000
        )
    }
    func executeDeleteUnavailable() async throws {}
    func executeDeleteOutdatedRuntimes() async throws {}
}

private actor RecordingCleanupExecutor: CleanupActionExecuting {
    private var trashCalls: [[String]] = []
    private var outdatedRuntimeDeleteCount = 0

    func moveToTrash(candidates: [CleanupCandidate]) async throws -> CleanupExecutionResult {
        let paths = candidates.map(\.path)
        trashCalls.append(paths)
        return CleanupExecutionResult(processedCount: paths.count, failedPaths: [])
    }

    func pruneDocker() async throws {}
    func deleteUnavailableSimulators() async throws {}
    func deleteOutdatedSimulatorRuntimes() async throws {
        outdatedRuntimeDeleteCount += 1
    }

    func recordedTrashCalls() -> [[String]] {
        trashCalls
    }

    func recordedOutdatedRuntimeDeleteCount() -> Int {
        outdatedRuntimeDeleteCount
    }
}
