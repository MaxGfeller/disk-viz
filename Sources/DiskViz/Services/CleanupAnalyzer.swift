import Foundation

struct CleanupRoots: Sendable {
    var homePath: String
    var downloadsPath: String
    var developerSearchPaths: [String]
    var packageCachePaths: [String]
    var xcodeDerivedDataPath: String
    var trashPath: String

    static var currentUser: CleanupRoots {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return CleanupRoots(
            homePath: home,
            downloadsPath: "\(home)/Downloads",
            developerSearchPaths: [
                "\(home)/projects",
                "\(home)/Developer",
                "\(home)/Code",
                "\(home)/src",
                "\(home)/workspace"
            ],
            packageCachePaths: [
                "\(home)/.npm",
                "\(home)/.pnpm-store",
                "\(home)/Library/pnpm/store",
                "\(home)/.gradle/caches",
                "\(home)/Library/Caches/Homebrew",
                "\(home)/Library/Caches/CocoaPods",
                "\(home)/Library/Caches/org.swift.swiftpm"
            ],
            xcodeDerivedDataPath: "\(home)/Library/Developer/Xcode/DerivedData",
            trashPath: "\(home)/.Trash"
        )
    }
}

struct CleanupAnalyzer: Sendable {
    private let roots: CleanupRoots
    private let referenceDate: Date
    private let oldItemAge: TimeInterval
    private let commandRunner: any CommandRunning
    private let suppliedDiskImagePaths: [String]?

    init(
        roots: CleanupRoots = .currentUser,
        referenceDate: Date = Date(),
        oldItemAge: TimeInterval = 90 * 24 * 60 * 60,
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        suppliedDiskImagePaths: [String]? = nil
    ) {
        self.roots = roots
        self.referenceDate = referenceDate
        self.oldItemAge = oldItemAge
        self.commandRunner = commandRunner
        self.suppliedDiskImagePaths = suppliedDiskImagePaths
    }

    func analyze() async -> [CleanupSuggestion] {
        let roots = roots
        let cutoff = referenceDate.addingTimeInterval(-oldItemAge)

        async let filesystemSuggestions = Task.detached(priority: .utility) {
            Self.analyzeFilesystem(roots: roots, cutoff: cutoff)
        }.value
        async let diskImageSuggestion = analyzeDiskImages(cutoff: cutoff)

        var suggestions = await filesystemSuggestions
        if let diskImageSuggestion = await diskImageSuggestion {
            suggestions.append(diskImageSuggestion)
        }

        return suggestions.sorted(by: Self.suggestionOrder)
    }

    private func analyzeDiskImages(cutoff: Date) async -> CleanupSuggestion? {
        let paths: [String]
        var isPartial = false

        if let suppliedDiskImagePaths {
            paths = suppliedDiskImagePaths
        } else {
            do {
                let result = try await commandRunner.run(
                    executable: "/usr/bin/mdfind",
                    arguments: [
                        "-0",
                        "-onlyin",
                        roots.homePath,
                        "kMDItemFSName == \"*.dmg\"cd"
                    ],
                    timeout: 20,
                    outputLimit: 16 * 1024 * 1024
                )
                isPartial = result.timedOut || result.exitCode != 0
                paths = Self.nullSeparatedPaths(result.stdout)
            } catch {
                paths = []
                isPartial = true
            }
        }

        let standardizedHome = URL(fileURLWithPath: roots.homePath, isDirectory: true)
            .standardizedFileURL.path
        var candidates: [CleanupCandidate] = []
        var inaccessibleCount = 0

        for path in Set(paths) {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard Self.isPath(url.path, inside: standardizedHome),
                  url.pathExtension.lowercased() == "dmg"
            else {
                continue
            }

            guard let measurement = Self.measureFile(url) else {
                inaccessibleCount += 1
                continue
            }
            guard let modifiedAt = measurement.modifiedAt, modifiedAt < cutoff else { continue }

            candidates.append(
                CleanupCandidate(
                    name: url.lastPathComponent,
                    path: url.path,
                    allocatedBytes: measurement.allocatedBytes,
                    modifiedAt: modifiedAt
                )
            )
        }

        candidates = Self.sortedCandidates(candidates)
        let totalBytes = candidates.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        guard totalBytes > 0 || isPartial || inaccessibleCount > 0 else { return nil }

        return CleanupSuggestion(
            category: .oldDiskImages,
            title: "Old disk images",
            detail: "DMG installers untouched for at least 90 days. Keep anything you still use to reinstall software.",
            estimatedBytes: totalBytes,
            totalCandidateCount: candidates.count,
            candidates: Array(candidates.prefix(500)),
            inaccessibleCount: inaccessibleCount,
            isPartial: isPartial || inaccessibleCount > 0
        )
    }

    private static func analyzeFilesystem(
        roots: CleanupRoots,
        cutoff: Date
    ) -> [CleanupSuggestion] {
        var suggestions: [CleanupSuggestion] = []

        if let downloads = analyzeOldDownloads(path: roots.downloadsPath, cutoff: cutoff) {
            suggestions.append(downloads)
        }
        if let artifacts = analyzeDeveloperArtifacts(roots: roots) {
            suggestions.append(artifacts)
        }
        if let derivedData = analyzeDerivedData(path: roots.xcodeDerivedDataPath) {
            suggestions.append(derivedData)
        }
        if let trash = analyzeTrash(path: roots.trashPath) {
            suggestions.append(trash)
        }

        return suggestions
    }

    private static func analyzeOldDownloads(path: String, cutoff: Date) -> CleanupSuggestion? {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let keys = resourceKeys
        let urls: [URL]

        do {
            urls = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
        } catch {
            guard fileManager.fileExists(atPath: path) else { return nil }
            return CleanupSuggestion(
                category: .oldDownloads,
                title: "Old Downloads",
                detail: "DiskViz could not read Downloads. Review macOS Files & Folders access.",
                estimatedBytes: 0,
                inaccessibleCount: 1,
                isPartial: true
            )
        }

        var candidates: [CleanupCandidate] = []
        var inaccessibleCount = 0

        for url in urls {
            if url.pathExtension.lowercased() == "dmg" {
                continue
            }
            let measurement = measure(url)
            inaccessibleCount += measurement.inaccessibleCount
            guard measurement.isEligible,
                  let newestDate = measurement.newestModificationDate,
                  newestDate < cutoff
            else {
                continue
            }

            candidates.append(
                CleanupCandidate(
                    name: url.lastPathComponent,
                    path: url.standardizedFileURL.path,
                    allocatedBytes: measurement.allocatedBytes,
                    modifiedAt: newestDate
                )
            )
        }

        candidates = sortedCandidates(candidates)
        let totalBytes = candidates.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        guard totalBytes > 0 || inaccessibleCount > 0 else { return nil }

        return CleanupSuggestion(
            category: .oldDownloads,
            title: "Old Downloads",
            detail: "Top-level items whose contents have not changed in at least 90 days.",
            estimatedBytes: totalBytes,
            totalCandidateCount: candidates.count,
            candidates: Array(candidates.prefix(500)),
            inaccessibleCount: inaccessibleCount,
            isPartial: inaccessibleCount > 0
        )
    }

    private static func analyzeDeveloperArtifacts(roots: CleanupRoots) -> CleanupSuggestion? {
        var candidateURLs = roots.packageCachePaths
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        var inaccessibleCount = 0

        for searchPath in deduplicatedRootPaths(roots.developerSearchPaths) {
            let searchRoot = URL(fileURLWithPath: searchPath, isDirectory: true)
            guard FileManager.default.fileExists(atPath: searchRoot.path) else { continue }

            var enumerationErrors = 0
            guard let enumerator = FileManager.default.enumerator(
                at: searchRoot,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in
                    enumerationErrors += 1
                    return true
                }
            ) else {
                inaccessibleCount += 1
                continue
            }

            while let url = enumerator.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: resourceKeys) else {
                    inaccessibleCount += 1
                    continue
                }
                if values.isSymbolicLink == true || values.isVolume == true {
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                guard values.isDirectory == true else { continue }

                if isRegeneratableArtifact(url) {
                    candidateURLs.append(url.standardizedFileURL)
                    enumerator.skipDescendants()
                } else if url.lastPathComponent == ".git" {
                    enumerator.skipDescendants()
                }
            }
            inaccessibleCount += enumerationErrors
        }

        candidateURLs = deduplicatedCandidateURLs(candidateURLs)
        var candidates: [CleanupCandidate] = []

        for url in candidateURLs {
            let measurement = measure(url)
            inaccessibleCount += measurement.inaccessibleCount
            guard measurement.isEligible, measurement.allocatedBytes > 0 else { continue }
            candidates.append(
                CleanupCandidate(
                    name: displayArtifactName(url),
                    path: url.path,
                    allocatedBytes: measurement.allocatedBytes,
                    modifiedAt: measurement.newestModificationDate
                )
            )
        }

        candidates = sortedCandidates(candidates)
        let totalBytes = candidates.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        guard totalBytes > 0 || inaccessibleCount > 0 else { return nil }

        return CleanupSuggestion(
            category: .developerArtifacts,
            title: "Developer artifacts & caches",
            detail: "Regeneratable dependencies, build output, and package caches. Projects may rebuild or download them again.",
            estimatedBytes: totalBytes,
            totalCandidateCount: candidates.count,
            candidates: Array(candidates.prefix(500)),
            inaccessibleCount: inaccessibleCount,
            isPartial: inaccessibleCount > 0
        )
    }

    private static func analyzeDerivedData(path: String) -> CleanupSuggestion? {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        )) ?? []
        var candidates: [CleanupCandidate] = []
        var inaccessibleCount = 0

        for url in urls {
            let measurement = measure(url)
            inaccessibleCount += measurement.inaccessibleCount
            guard measurement.isEligible, measurement.allocatedBytes > 0 else { continue }
            candidates.append(
                CleanupCandidate(
                    name: url.lastPathComponent,
                    path: url.standardizedFileURL.path,
                    allocatedBytes: measurement.allocatedBytes,
                    modifiedAt: measurement.newestModificationDate
                )
            )
        }

        candidates = sortedCandidates(candidates)
        let totalBytes = candidates.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        guard totalBytes > 0 || inaccessibleCount > 0 else { return nil }

        return CleanupSuggestion(
            category: .xcodeDerivedData,
            title: "Xcode DerivedData",
            detail: "Build indexes and products that Xcode can regenerate. Quit Xcode before cleanup.",
            estimatedBytes: totalBytes,
            totalCandidateCount: candidates.count,
            candidates: Array(candidates.prefix(500)),
            inaccessibleCount: inaccessibleCount,
            isPartial: inaccessibleCount > 0
        )
    }

    private static func analyzeTrash(path: String) -> CleanupSuggestion? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let measurement = measure(URL(fileURLWithPath: path, isDirectory: true))
        guard measurement.allocatedBytes > 0 || measurement.inaccessibleCount > 0 else { return nil }

        return CleanupSuggestion(
            category: .trash,
            title: "Trash",
            detail: "Space is reclaimed only when you empty Trash yourself in Finder.",
            estimatedBytes: measurement.allocatedBytes,
            estimateKind: .currentlyInTrash,
            inaccessibleCount: measurement.inaccessibleCount,
            isPartial: measurement.inaccessibleCount > 0
        )
    }

    private static func isRegeneratableArtifact(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent()
        let fileManager = FileManager.default

        switch name {
        case "node_modules":
            return fileManager.fileExists(atPath: parent.appendingPathComponent("package.json").path)
        case ".build":
            return fileManager.fileExists(atPath: parent.appendingPathComponent("Package.swift").path)
        case "target":
            return fileManager.fileExists(atPath: parent.appendingPathComponent("Cargo.toml").path)
        case ".next", ".nuxt", ".turbo", ".parcel-cache":
            return fileManager.fileExists(atPath: parent.appendingPathComponent("package.json").path)
        default:
            return false
        }
    }

    private static func displayArtifactName(_ url: URL) -> String {
        let parentName = url.deletingLastPathComponent().lastPathComponent
        return parentName.isEmpty ? url.lastPathComponent : "\(parentName) / \(url.lastPathComponent)"
    }

    private static func deduplicatedRootPaths(_ paths: [String]) -> [String] {
        let sorted = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            .sorted { $0.count < $1.count }
        var retained: [String] = []
        for path in sorted where !retained.contains(where: { isPath(path, inside: $0) }) {
            retained.append(path)
        }
        return retained
    }

    private static func deduplicatedCandidateURLs(_ urls: [URL]) -> [URL] {
        let sorted = Dictionary(grouping: urls, by: { $0.standardizedFileURL.path })
            .compactMap { $0.value.first }
            .sorted { $0.path.count < $1.path.count }
        var retained: [URL] = []
        for url in sorted where !retained.contains(where: { isPath(url.path, inside: $0.path) }) {
            retained.append(url)
        }
        return retained
    }

    private static func measureFile(_ url: URL) -> (allocatedBytes: Int64, modifiedAt: Date?)? {
        guard let values = try? url.resourceValues(forKeys: resourceKeys),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            return nil
        }
        return (
            Int64(max(0, values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)),
            values.contentModificationDate
        )
    }

    private static func measure(_ url: URL) -> DirectoryMeasurement {
        guard let rootValues = try? url.resourceValues(forKeys: resourceKeys),
              rootValues.isSymbolicLink != true
        else {
            return DirectoryMeasurement(inaccessibleCount: 1)
        }

        if rootValues.isRegularFile == true {
            return DirectoryMeasurement(
                allocatedBytes: Int64(max(
                    0,
                    rootValues.totalFileAllocatedSize ?? rootValues.fileAllocatedSize ?? 0
                )),
                newestModificationDate: rootValues.contentModificationDate
            )
        }
        guard rootValues.isDirectory == true else { return DirectoryMeasurement() }

        var measurement = DirectoryMeasurement(
            newestModificationDate: rootValues.contentModificationDate
        )
        var enumerationErrors = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in
                enumerationErrors += 1
                return true
            }
        ) else {
            measurement.inaccessibleCount = 1
            return measurement
        }

        while let child = enumerator.nextObject() as? URL {
            guard let values = try? child.resourceValues(forKeys: resourceKeys) else {
                measurement.inaccessibleCount += 1
                continue
            }
            if values.isSymbolicLink == true || values.isVolume == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isRegularFile == true {
                measurement.allocatedBytes += Int64(max(
                    0,
                    values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
                ))
            }
            if let modifiedAt = values.contentModificationDate,
               measurement.newestModificationDate == nil
                || modifiedAt > measurement.newestModificationDate! {
                measurement.newestModificationDate = modifiedAt
            }
        }
        measurement.inaccessibleCount += enumerationErrors
        return measurement
    }

    private static var resourceKeys: Set<URLResourceKey> {
        [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isVolumeKey,
            .contentModificationDateKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]
    }

    private static func nullSeparatedPaths(_ data: Data) -> [String] {
        data.split(separator: 0).compactMap { bytes in
            String(data: Data(bytes), encoding: .utf8)
        }
    }

    private static func sortedCandidates(_ candidates: [CleanupCandidate]) -> [CleanupCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.allocatedBytes != rhs.allocatedBytes {
                return lhs.allocatedBytes > rhs.allocatedBytes
            }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    private static func suggestionOrder(_ lhs: CleanupSuggestion, _ rhs: CleanupSuggestion) -> Bool {
        if lhs.estimatedBytes != rhs.estimatedBytes {
            return lhs.estimatedBytes > rhs.estimatedBytes
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private static func isPath(_ path: String, inside ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }
}

private struct DirectoryMeasurement {
    var allocatedBytes: Int64 = 0
    var newestModificationDate: Date?
    var inaccessibleCount: Int = 0

    var isEligible: Bool {
        inaccessibleCount == 0
    }
}
