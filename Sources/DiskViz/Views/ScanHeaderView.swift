import SwiftUI

struct ScanHeaderView: View {
    @ObservedObject var store: DiskUsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                TextField("Folder path", text: $store.scanPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 260, idealWidth: 520, maxWidth: .infinity)
                    .layoutPriority(1)
                    .disabled(store.scanning)
                    .onSubmit {
                        store.scan()
                    }

                Button {
                    store.chooseDirectoryAndScan()
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 16)
                }
                .help("Choose Folder")
                .disabled(store.scanning)

                Button {
                    store.scan()
                } label: {
                    Image(systemName: store.scanning ? "hourglass" : "arrow.clockwise")
                        .frame(width: 16)
                }
                .help(store.scanning ? "Scanning" : "Scan")
                .disabled(store.scanning || store.scanPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }

            HStack(spacing: 14) {
                if let volumeInfo = store.volumeInfo {
                    DiskVolumeSummaryView(info: volumeInfo)
                }

                if store.scanning, let progress = store.progress, progress.dirsFound > 0 {
                    ScanProgressSummaryView(progress: progress)
                }

                Spacer(minLength: 8)

                ViewThatFits(in: .horizontal) {
                    LegendView()
                        .fixedSize(horizontal: true, vertical: false)
                    EmptyView()
                }
            }
        }
        .controlSize(.regular)
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 70)
        .background(.bar)
        .onChange(of: store.scanPath) { _, _ in
            store.refreshVolumeInfo()
        }
    }
}

private struct DiskVolumeSummaryView: View {
    var info: DiskVolumeInfo

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "internaldrive")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text("\(ByteFormatter.string(from: info.usedBytes)) used of \(ByteFormatter.string(from: info.totalBytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)

            ProgressView(value: info.usedFraction)
                .progressViewStyle(.linear)
                .frame(width: 76)
        }
        .fixedSize(horizontal: true, vertical: false)
        .help("\(ByteFormatter.string(from: info.freeBytes)) available on \(info.path)")
    }
}

private struct ScanProgressSummaryView: View {
    var progress: ScanProgress

    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: progress.fractionComplete)
                .progressViewStyle(.linear)
                .frame(width: 92)

            Text("\(progress.percentComplete)% scanned")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
