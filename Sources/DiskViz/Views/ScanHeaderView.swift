import SwiftUI

struct ScanHeaderView: View {
    @ObservedObject var store: DiskUsageStore

    private var internalSources: [ScanSource] {
        sortedSources(
            store.scanSources.filter { $0.kind == .volume && $0.isInternal }
        )
    }

    private var externalSources: [ScanSource] {
        sortedSources(
            store.scanSources.filter { $0.kind == .volume && $0.isExternal }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                ScanSourceMenu(
                    selectedSource: store.selectedSource,
                    internalSources: internalSources,
                    externalSources: externalSources,
                    disabled: store.scanning,
                    onSelect: store.selectAndScan,
                    onChooseFolder: store.chooseDirectoryAndScan
                )

                Spacer(minLength: 12)

                if let volumeInfo = store.volumeInfo {
                    DiskVolumeSummaryView(info: volumeInfo)
                }

                scanControl
            }

            ScanStatusRow(
                scanning: store.scanning,
                scanStopped: store.scanStopped,
                progress: store.progress,
                errorMessage: store.errorMessage,
                sourceName: store.selectedSource?.name
            )
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 72)
        .background(.bar)
    }

    @ViewBuilder
    private var scanControl: some View {
        if store.scanning {
            Button {
                store.stopScan()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(".", modifiers: .command)
            .help("Stop scanning and keep the partial results")
            .accessibilityIdentifier("scan-stop-button")
        } else {
            Button {
                store.scan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(store.scanPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut("r", modifiers: .command)
            .help("Scan this source again")
            .accessibilityIdentifier("scan-rescan-button")
        }
    }

    private func sortedSources(_ sources: [ScanSource]) -> [ScanSource] {
        sources.sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.path < rhs.path
        }
    }
}

private struct ScanSourceMenu: View {
    var selectedSource: ScanSource?
    var internalSources: [ScanSource]
    var externalSources: [ScanSource]
    var disabled: Bool
    var onSelect: (ScanSource) -> Void
    var onChooseFolder: () -> Void

    var body: some View {
        Menu {
            Section("Internal Disk") {
                if internalSources.isEmpty {
                    Button("No internal disks found") {}
                        .disabled(true)
                } else {
                    ForEach(internalSources) { source in
                        sourceButton(source)
                    }
                }
            }

            Section("Other Volumes") {
                if externalSources.isEmpty {
                    Button("No other volumes mounted") {}
                        .disabled(true)
                } else {
                    ForEach(externalSources) { source in
                        sourceButton(source)
                    }
                }
            }

            Divider()

            Button(action: onChooseFolder) {
                Label("Choose Folder…", systemImage: "folder")
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: sourceIcon)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(selectedSource?.name ?? "Choose Scan Source")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(sourceDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(minWidth: 190, maxWidth: 280, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(disabled)
        .help(selectedSource?.path ?? "Choose an internal disk, another volume, or a folder")
        .accessibilityIdentifier("scan-source-menu")
    }

    @ViewBuilder
    private func sourceButton(_ source: ScanSource) -> some View {
        Button {
            onSelect(source)
        } label: {
            Label(
                "\(source.name) — \(ByteFormatter.string(from: source.freeBytes)) free",
                systemImage: selectedSource?.id == source.id
                    ? "checkmark"
                    : (source.isInternal ? "internaldrive" : "externaldrive")
            )
        }
    }

    private var sourceIcon: String {
        guard let selectedSource else { return "internaldrive" }
        if selectedSource.kind == .customFolder {
            return "folder"
        }
        return selectedSource.isInternal ? "internaldrive" : "externaldrive"
    }

    private var sourceDescription: String {
        guard let selectedSource else { return "Internal disk selected by default" }
        if selectedSource.kind == .customFolder {
            return "Folder"
        }
        return selectedSource.isInternal ? "Internal Disk" : "External Volume"
    }
}

private struct DiskVolumeSummaryView: View {
    var info: DiskVolumeInfo

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("\(ByteFormatter.string(from: info.freeBytes)) free")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(freeSpaceColor)

                Text("• \(ByteFormatter.string(from: info.usedBytes)) used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)

            ProgressView(value: info.usedFraction)
                .progressViewStyle(.linear)
                .tint(freeSpaceColor)
                .frame(width: 88)
                .accessibilityLabel("Disk space used")
                .accessibilityValue("\(ByteFormatter.string(from: info.usedBytes)) of \(ByteFormatter.string(from: info.totalBytes))")
        }
        .fixedSize(horizontal: true, vertical: false)
        .help(
            "\(ByteFormatter.string(from: info.freeBytes)) free of "
                + "\(ByteFormatter.string(from: info.totalBytes)) on \(info.path)"
        )
    }

    private var freeSpaceColor: Color {
        info.usedFraction >= 0.95 ? .red : (info.usedFraction >= 0.85 ? .orange : .accentColor)
    }
}

private struct ScanStatusRow: View {
    var scanning: Bool
    var scanStopped: Bool
    var progress: ScanProgress?
    var errorMessage: String?
    var sourceName: String?

    var body: some View {
        HStack(spacing: 8) {
            statusIndicator
            statusText

            if let progress {
                ScanCountersView(progress: progress)
            }

            Spacer(minLength: 8)

            if let inaccessibleCount = progress?.inaccessibleDirs, inaccessibleCount > 0 {
                Label(
                    inaccessibleLabel(inaccessibleCount),
                    systemImage: "lock.trianglebadge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .help("Some folders could not be read, so these results may be incomplete.")
            }
        }
        .frame(minHeight: 18)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scan-status")
        .help(currentPathHelp)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if scanning {
            ProgressView()
                .controlSize(.small)
        } else if scanStopped {
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.orange)
        } else if errorMessage != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else if progress != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        if scanning {
            Text(progress == nil ? "Preparing scan…" : "Scanning…")
                .foregroundStyle(.primary)
        } else if scanStopped {
            Text("Scan stopped — showing partial results")
                .foregroundStyle(.orange)
        } else if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .help(errorMessage)
        } else if progress != nil {
            Text("Scan complete")
                .foregroundStyle(.secondary)
        } else {
            Text(sourceName.map { "Ready to scan \($0)" } ?? "Choose a source to scan")
                .foregroundStyle(.secondary)
        }
    }

    private var currentPathHelp: String {
        guard scanning, let currentPath = progress?.currentPath, !currentPath.isEmpty else {
            return ""
        }
        return "Currently scanning \(currentPath)"
    }

    private func inaccessibleLabel(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "folder" : "folders") inaccessible"
    }
}

private struct ScanCountersView: View {
    var progress: ScanProgress

    var body: some View {
        HStack(spacing: 6) {
            separator
            Text(countLabel(progress.dirsCompleted, singular: "folder"))
            separator
            Text(countLabel(progress.filesFound, singular: "file"))
            separator
            Text("\(ByteFormatter.string(from: progress.bytesFound)) indexed")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var separator: some View {
        Text("•")
            .foregroundStyle(.tertiary)
    }

    private func countLabel(_ count: Int, singular: String) -> String {
        "\(count.formatted()) \(count == 1 ? singular : singular + "s")"
    }
}
