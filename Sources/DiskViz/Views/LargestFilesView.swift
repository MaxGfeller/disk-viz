import Foundation
import SwiftUI

enum LargestFilesScope: String, CaseIterable, Identifiable {
    case currentFolder
    case entireScan

    var id: Self { self }
}

struct LargestFilesView: View {
    @ObservedObject var store: DiskUsageStore
    var focusPath: String?
    @Binding var scope: LargestFilesScope
    @Binding var selectedNode: DiskNode?
    @Binding var pendingTrash: DiskNode?

    @State private var filter = ""

    private var currentFolderPath: String {
        focusPath ?? store.root?.path ?? store.scanPath
    }

    private var scopedFiles: [DiskNode] {
        switch scope {
        case .currentFolder:
            return store.largestFiles(in: currentFolderPath)
        case .entireScan:
            return store.largestFiles
        }
    }

    private var displayedFiles: [DiskNode] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return scopedFiles }
        return scopedFiles.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            scopePicker
            Divider()

            if !scopedFiles.isEmpty || !filter.isEmpty {
                TextField("Filter files", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)

                Divider()
            }

            if displayedFiles.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(displayedFiles) { file in
                            LargestFileRow(
                                file: file,
                                isSelected: selectedNode?.path == file.path,
                                store: store,
                                pendingTrash: $pendingTrash
                            ) {
                                selectedNode = file
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
                .accessibilityIdentifier("largest-files-list")
            }

            Divider()
            safetyFooter
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: scope) { _, _ in
            reconcileSelection()
        }
        .onChange(of: focusPath) { _, _ in
            reconcileSelection()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Largest files")
                    .font(.headline)

                Text(listScopeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("largest-files-scope-label")
            }

            Spacer()

            if scopeIsUpdating {
                ProgressView()
                    .controlSize(.small)
            }

            Text("\(scopedFiles.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityIdentifier("largest-files-count")
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(.bar)
    }

    private var scopePicker: some View {
        Picker("File scope", selection: $scope) {
            Text("This Folder")
                .tag(LargestFilesScope.currentFolder)
            Text("Entire Scan")
                .tag(LargestFilesScope.entireScan)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityIdentifier("largest-files-scope-picker")
        .accessibilityValue(scope == .currentFolder ? "This Folder" : "Entire Scan")
    }

    private var listScopeLabel: String {
        let inaccessibleCount = store.progress?.inaccessibleDirs ?? 0
        let location = scope == .currentFolder
            ? "In \(currentFolderName)"
            : "Across entire scan"

        if store.isExpanding(currentFolderPath), scope == .currentFolder {
            if inaccessibleCount > 0 {
                return "\(location) · opening details; \(inaccessibleCount.formatted()) inaccessible"
            }
            return "\(location) · opening details"
        }
        if scope == .currentFolder,
           store.detailError(for: currentFolderPath) != nil {
            return "\(location) · folder details incomplete"
        }
        if scope == .currentFolder,
           store.hasIncompleteDetails(for: currentFolderPath) {
            return "\(location) · partial folder details"
        }
        if scope == .entireScan, store.expandingPath != nil, !store.sourceScanning {
            return "\(location) · refreshing folder details"
        }
        if store.sourceScanning {
            if inaccessibleCount > 0 {
                return "\(location) · updating; \(inaccessibleCount.formatted()) inaccessible"
            }
            return "\(location) · updating"
        }
        if store.scanStopped {
            if inaccessibleCount > 0 {
                return "\(location) · partial; \(inaccessibleCount.formatted()) inaccessible"
            }
            return "\(location) · partial results"
        }
        if hasIncompleteScanError {
            if inaccessibleCount > 0 {
                return "\(location) · partial after error; \(inaccessibleCount.formatted()) inaccessible"
            }
            return "\(location) · partial after error"
        }
        if inaccessibleCount > 0 {
            return "\(location) · \(inaccessibleCount.formatted()) folders inaccessible"
        }
        return location
    }

    private var currentFolderName: String {
        if currentFolderPath == "/" {
            return store.selectedSource?.name ?? "/"
        }
        let name = URL(fileURLWithPath: currentFolderPath).lastPathComponent
        return name.isEmpty ? currentFolderPath : name
    }

    private var scopeIsUpdating: Bool {
        switch scope {
        case .currentFolder:
            return store.sourceScanning || store.isExpanding(currentFolderPath)
        case .entireScan:
            return store.sourceScanning || store.expandingPath != nil
        }
    }

    private var hasIncompleteScanError: Bool {
        guard store.errorMessage != nil else { return false }
        guard let progress = store.progress else { return true }
        return progress.dirsCompleted < progress.dirsFound
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.number")
                .font(.system(size: 25))
                .foregroundStyle(.tertiary)

            Text(emptyStateTitle)
                .font(.callout)
                .foregroundStyle(.secondary)

            if scope == .currentFolder,
               let detailError = store.detailError(for: currentFolderPath) {
                Text(detailError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            } else if scope == .currentFolder,
               !store.hasLargestFilesIndex(for: currentFolderPath),
               !scopeIsUpdating {
                Text("Open this folder to index its contents in detail.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateTitle: String {
        if !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !scopedFiles.isEmpty {
            return "No matching files"
        }
        if scopeIsUpdating {
            return scope == .currentFolder
                ? "Finding large files in this folder…"
                : "Finding large files…"
        }
        return scope == .currentFolder
            ? "No files found in this folder"
            : "No files found"
    }

    private func reconcileSelection() {
        guard let selectedNode, !selectedNode.isDirectory else { return }

        let remainsVisible: Bool
        switch scope {
        case .currentFolder:
            remainsVisible = TreeOperations.isPath(
                selectedNode.path,
                equalToOrDescendantOf: currentFolderPath
            )
        case .entireScan:
            remainsVisible = store.largestFiles.contains { $0.path == selectedNode.path }
        }

        if !remainsVisible {
            self.selectedNode = nil
        }
    }

    private var safetyFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield")
            Text("Nothing is removed unless you choose Move to Trash.")
                .lineLimit(2)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(.bar)
    }
}

private struct LargestFileRow: View {
    var file: DiskNode
    var isSelected: Bool
    @ObservedObject var store: DiskUsageStore
    @Binding var pendingTrash: DiskNode?
    var onSelect: () -> Void

    @State private var hovered = false

    private var parentPath: String {
        URL(fileURLWithPath: file.path).deletingLastPathComponent().path
    }

    private var isManagedAsset: Bool {
        FileActionPolicy.manualDeletionRestriction(for: file.path) != nil
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(FileCategoryColor.color(for: file, sizeRatio: 0.78))
                        .frame(width: 5, height: 34)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)

                        Text(parentPath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if isManagedAsset {
                            Label("Managed by macOS", systemImage: "checkmark.shield")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer(minLength: 6)

                    Text(ByteFormatter.string(from: file.size))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: isManagedAsset ? 62 : 50,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(file.name))
            .accessibilityIdentifier("largest-file-row-\(file.path)")
            .accessibilityValue(Text("\(ByteFormatter.string(from: file.size)), in \(parentPath)"))
            .accessibilityHint(Text("Select this file."))
            .accessibilityAction(named: Text("Reveal in Finder")) {
                store.revealInFinder(file)
            }

            if hovered || isSelected {
                Button {
                    store.revealInFinder(file)
                } label: {
                    Image(systemName: "finder")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
                .accessibilityLabel(Text("Reveal \(file.name) in Finder"))
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: isManagedAsset ? 62 : 50)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.16)
                        : Color.primary.opacity(hovered ? 0.055 : 0)
                )
        )
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .help("\(file.path) — \(ByteFormatter.string(from: file.size))")
        .contextMenu {
            NodeActionsMenu(node: file, store: store, pendingTrash: $pendingTrash)
        }
    }
}
