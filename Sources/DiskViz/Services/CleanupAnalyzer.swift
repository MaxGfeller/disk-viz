import Darwin
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

        let filesystemWorker = Task.detached(priority: .utility) {
            Self.analyzeFilesystem(roots: roots, cutoff: cutoff)
        }

        return await withTaskCancellationHandler {
            async let filesystemSuggestions = filesystemWorker.value
            async let diskImageSuggestion = analyzeDiskImages(cutoff: cutoff)

            var suggestions = await filesystemSuggestions
            if let diskImageSuggestion = await diskImageSuggestion,
               let nonoverlapping = Self.removingDiskImageOverlaps(
                diskImageSuggestion,
                from: suggestions,
                trashPath: roots.trashPath
               ) {
                suggestions.append(nonoverlapping)
            }

            guard !Task.isCancelled else { return [] }
            return suggestions.sorted(by: Self.suggestionOrder)
        } onCancel: {
            filesystemWorker.cancel()
        }
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
            guard !Task.isCancelled else { return nil }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard Self.isPath(url.path, inside: standardizedHome),
                  Self.isSafeCleanupRoot(url, homePath: roots.homePath),
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
        guard !Task.isCancelled else { return [] }
        var suggestions: [CleanupSuggestion] = []

        if let downloads = analyzeOldDownloads(
            path: roots.downloadsPath,
            homePath: roots.homePath,
            cutoff: cutoff
        ) {
            suggestions.append(downloads)
        }
        guard !Task.isCancelled else { return [] }
        if let artifacts = analyzeDeveloperArtifacts(roots: roots) {
            suggestions.append(artifacts)
        }
        guard !Task.isCancelled else { return [] }
        if let derivedData = analyzeDerivedData(
            path: roots.xcodeDerivedDataPath,
            homePath: roots.homePath
        ) {
            suggestions.append(derivedData)
        }
        guard !Task.isCancelled else { return [] }
        if let trash = analyzeTrash(path: roots.trashPath, homePath: roots.homePath) {
            suggestions.append(trash)
        }

        return suggestions
    }

    private static func analyzeOldDownloads(
        path: String,
        homePath: String,
        cutoff: Date
    ) -> CleanupSuggestion? {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard isSafeCleanupRoot(root, homePath: homePath) else { return nil }
        var rootStat = stat()
        guard lstat(root.path, &rootStat) == 0 else { return nil }
        let names: [String]

        do {
            names = try fileManager.contentsOfDirectory(atPath: root.path)
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

        var inaccessibleCount = 0
        var eligibleEntries: [TopLevelDownloadEntry] = []
        eligibleEntries.reserveCapacity(names.count)

        for name in names {
            guard !Task.isCancelled else { break }
            let url = root.appendingPathComponent(name).standardizedFileURL
            if url.pathExtension.lowercased() == "dmg" {
                continue
            }
            var itemStat = stat()
            guard lstat(url.path, &itemStat) == 0 else {
                inaccessibleCount += 1
                continue
            }
            let itemType = itemStat.st_mode & mode_t(S_IFMT)
            guard itemStat.st_dev == rootStat.st_dev,
                  itemType == mode_t(S_IFREG) || itemType == mode_t(S_IFDIR)
            else {
                continue
            }

            let modifiedSeconds = max(
                itemStat.st_mtimespec.tv_sec,
                itemStat.st_birthtimespec.tv_sec
            )
            let modifiedAt = Date(timeIntervalSince1970: TimeInterval(modifiedSeconds))
            guard modifiedAt < cutoff else { continue }

            let directAllocatedBytes: Int64? = itemType == mode_t(S_IFREG)
                ? max(0, Int64(itemStat.st_blocks)) * 512
                : nil
            eligibleEntries.append(
                TopLevelDownloadEntry(
                    url: url,
                    modifiedAt: modifiedAt,
                    directAllocatedBytes: directAllocatedBytes
                )
            )
        }

        let directorySizes = nativeAllocatedSizes(
            for: eligibleEntries.compactMap { entry in
                entry.directAllocatedBytes == nil ? entry.url : nil
            }
        )
        var measuredEntries: [(entry: TopLevelDownloadEntry, size: Int64)] = []
        measuredEntries.reserveCapacity(eligibleEntries.count)
        for entry in eligibleEntries {
            guard let size = entry.directAllocatedBytes ?? directorySizes[entry.url.path] else {
                inaccessibleCount += 1
                continue
            }
            measuredEntries.append((entry, size))
        }

        measuredEntries.sort { lhs, rhs in
            if lhs.size != rhs.size { return lhs.size > rhs.size }
            return lhs.entry.url.path.localizedStandardCompare(rhs.entry.url.path) == .orderedAscending
        }
        let totalBytes = measuredEntries.reduce(Int64(0)) { $0 + $1.size }
        guard totalBytes > 0 || inaccessibleCount > 0 else { return nil }
        let candidates = measuredEntries.prefix(500).map { item in
            CleanupCandidate(
                name: item.entry.url.lastPathComponent,
                path: item.entry.url.path,
                allocatedBytes: item.size,
                modifiedAt: item.entry.modifiedAt
            )
        }

        return CleanupSuggestion(
            category: .oldDownloads,
            title: "Old Downloads",
            detail: "Top-level items last changed at least 90 days ago. Review folders before selecting them.",
            estimatedBytes: totalBytes,
            totalCandidateCount: measuredEntries.count,
            candidates: candidates,
            inaccessibleCount: inaccessibleCount,
            isPartial: inaccessibleCount > 0
        )
    }

    private static func analyzeDeveloperArtifacts(roots: CleanupRoots) -> CleanupSuggestion? {
        var candidateURLs = roots.packageCachePaths
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            .filter {
                FileManager.default.fileExists(atPath: $0.path)
                    && isSafeCleanupRoot($0, homePath: roots.homePath)
            }
        var inaccessibleCount = 0

        for searchPath in deduplicatedRootPaths(roots.developerSearchPaths) {
            guard !Task.isCancelled else { break }
            let searchRoot = URL(fileURLWithPath: searchPath, isDirectory: true)
            guard FileManager.default.fileExists(atPath: searchRoot.path),
                  isSafeCleanupRoot(searchRoot, homePath: roots.homePath)
            else { continue }

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

            while !Task.isCancelled, let url = enumerator.nextObject() as? URL {
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
        let allocatedSizes = nativeAllocatedSizes(for: candidateURLs)
        var candidates: [CleanupCandidate] = candidateURLs.compactMap { url in
            guard let size = allocatedSizes[url.path], size > 0 else {
                inaccessibleCount += 1
                return nil
            }
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            return CleanupCandidate(
                name: displayArtifactName(url),
                path: url.path,
                allocatedBytes: size,
                modifiedAt: modifiedAt
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

    private static func analyzeDerivedData(path: String, homePath: String) -> CleanupSuggestion? {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path),
              isSafeCleanupRoot(root, homePath: homePath)
        else { return nil }

        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        )) ?? []
        var inaccessibleCount = 0
        let candidateURLs = urls.compactMap { url -> URL? in
            guard let values = try? url.resourceValues(forKeys: resourceKeys),
                  values.isSymbolicLink != true,
                  values.isVolume != true,
                  (values.isDirectory == true || values.isRegularFile == true)
            else {
                return nil
            }
            return url.standardizedFileURL
        }
        let allocatedSizes = nativeAllocatedSizes(for: candidateURLs)
        var candidates: [CleanupCandidate] = candidateURLs.compactMap { url in
            guard let size = allocatedSizes[url.path], size > 0 else {
                inaccessibleCount += 1
                return nil
            }
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            return CleanupCandidate(
                name: url.lastPathComponent,
                path: url.path,
                allocatedBytes: size,
                modifiedAt: modifiedAt
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

    private static func analyzeTrash(path: String, homePath: String) -> CleanupSuggestion? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard isSafeCleanupRoot(url, homePath: homePath) else { return nil }
        let size = nativeAllocatedSizes(for: [url])[url.path]
        let inaccessibleCount = size == nil ? 1 : 0
        guard (size ?? 0) > 0 || inaccessibleCount > 0 else { return nil }

        return CleanupSuggestion(
            category: .trash,
            title: "Trash",
            detail: "Space is reclaimed only when you empty Trash yourself in Finder.",
            estimatedBytes: size ?? 0,
            estimateKind: .currentlyInTrash,
            inaccessibleCount: inaccessibleCount,
            isPartial: inaccessibleCount > 0
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
            [
                values.contentModificationDate,
                values.creationDate,
                values.addedToDirectoryDate
            ].compactMap { $0 }.max()
        )
    }

    private static func nativeAllocatedSizes(for urls: [URL]) -> [String: Int64] {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/du") else { return [:] }

        var sizes: [String: Int64] = [:]
        for chunk in nativeCommandChunks(urls) {
            guard !Task.isCancelled else { break }
            sizes.merge(nativeAllocatedSizes(forChunk: chunk)) { _, new in new }
        }
        return sizes
    }

    private static func nativeCommandChunks(_ urls: [URL]) -> [[URL]] {
        let maximumArgumentBytes = 96 * 1_024
        let maximumURLCount = 512
        var chunks: [[URL]] = []
        var current: [URL] = []
        var currentBytes = 0

        for url in urls {
            let argumentBytes = url.path.utf8.count + 1
            if !current.isEmpty,
               current.count >= maximumURLCount || currentBytes + argumentBytes > maximumArgumentBytes {
                chunks.append(current)
                current = []
                currentBytes = 0
            }
            current.append(url)
            currentBytes += argumentBytes
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func nativeAllocatedSizes(forChunk chunk: [URL]) -> [String: Int64] {
        guard !chunk.isEmpty else { return [:] }
        var sizes: [String: Int64] = [:]
        let process = Process()
        let output = Pipe()
        let buffer = NativeCommandOutput()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-skx"] + chunk.map(\.path)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in
            buffer.append(handle.availableData)
        }

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(60)
            while process.isRunning && Date() < deadline && !Task.isCancelled {
                Thread.sleep(forTimeInterval: 0.02)
            }
            let interrupted = process.isRunning
            if interrupted {
                stop(process)
            }
            guard !interrupted,
                  !Task.isCancelled,
                  process.terminationStatus == 0
            else {
                output.fileHandleForReading.readabilityHandler = nil
                return [:]
            }
            Thread.sleep(forTimeInterval: 0.02)
            output.fileHandleForReading.readabilityHandler = nil
            let data = buffer.data

            for line in String(decoding: data, as: UTF8.self)
                .split(whereSeparator: { $0.isNewline }) {
                let columns = line.split(
                    maxSplits: 1,
                    whereSeparator: { $0 == " " || $0 == "\t" }
                )
                guard columns.count == 2,
                      let kilobytes = Int64(columns[0])
                else {
                    continue
                }
                let path = URL(fileURLWithPath: String(columns[1])).standardizedFileURL.path
                sizes[path] = max(0, kilobytes) * 1_024
            }
        } catch {
            if process.isRunning { stop(process) }
            output.fileHandleForReading.readabilityHandler = nil
            return [:]
        }
        return sizes
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let gracefulDeadline = Date().addingTimeInterval(0.4)
        while process.isRunning && Date() < gracefulDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(0.4)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }

    private static var resourceKeys: Set<URLResourceKey> {
        [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isVolumeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .addedToDirectoryDateKey,
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

    private static func removingDiskImageOverlaps(
        _ diskImages: CleanupSuggestion,
        from existing: [CleanupSuggestion],
        trashPath: String
    ) -> CleanupSuggestion? {
        let containerPaths = existing.flatMap(\.candidates).compactMap { candidate -> String? in
            let values = try? URL(fileURLWithPath: candidate.path)
                .resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true ? candidate.canonicalPath : nil
        } + [
            URL(fileURLWithPath: trashPath, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
        ]
        let candidates = diskImages.candidates.filter { image in
            !containerPaths.contains { isPath(image.canonicalPath, inside: $0) }
        }
        let totalBytes = candidates.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        guard totalBytes > 0 || diskImages.isPartial else { return nil }

        var result = diskImages
        result.candidates = candidates
        result.totalCandidateCount = candidates.count
        result.estimatedBytes = totalBytes
        return result
    }

    private static func isSafeCleanupRoot(_ url: URL, homePath: String) -> Bool {
        let standardized = url.standardizedFileURL
        let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .isSymbolicLinkKey,
            .isVolumeKey,
            .volumeIdentifierKey
        ]
        guard let values = try? standardized.resourceValues(forKeys: keys),
              let homeValues = try? home.resourceValues(forKeys: [.volumeIdentifierKey]),
              let volume = values.volumeIdentifier.map({ String(describing: $0) }),
              let homeVolume = homeValues.volumeIdentifier.map({ String(describing: $0) })
        else {
            return false
        }

        return canonical.path != home.path
            && isPath(canonical.path, inside: home.path)
            && values.isSymbolicLink != true
            && values.isVolume != true
            && volume == homeVolume
    }

    private static func isPath(_ path: String, inside ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }
}

private struct TopLevelDownloadEntry {
    var url: URL
    var modifiedAt: Date
    var directAllocatedBytes: Int64?
}

private final class NativeCommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
}
