import SwiftUI

struct ScanHeaderView: View {
    @ObservedObject var store: DiskUsageStore

    var body: some View {
        HStack(spacing: 10) {
            Label("Location", systemImage: "externaldrive")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)

            TextField("Folder path", text: $store.scanPath)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 280, idealWidth: 420, maxWidth: 520)
                .layoutPriority(1)
                .disabled(store.scanning)
                .onSubmit {
                    store.scan()
                }

            Button {
                store.chooseDirectoryAndScan()
            } label: {
                Label("Choose", systemImage: "folder")
            }
            .disabled(store.scanning)

            Button {
                store.scan()
            } label: {
                Label(store.scanning ? "Scanning" : "Scan", systemImage: store.scanning ? "hourglass" : "arrow.clockwise")
            }
            .disabled(store.scanning || store.scanPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)

            Spacer(minLength: 8)

            if store.scanning, let progress = store.progress, progress.dirsFound > 0 {
                ProgressView(value: progress.fractionComplete)
                    .progressViewStyle(.linear)
                    .frame(width: 110)

                Text("\(progress.percentComplete)%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }

            ViewThatFits(in: .horizontal) {
                LegendView()
                    .fixedSize(horizontal: true, vertical: false)
                EmptyView()
            }
        }
        .controlSize(.regular)
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .frame(minHeight: 52)
        .background(.bar)
    }
}
