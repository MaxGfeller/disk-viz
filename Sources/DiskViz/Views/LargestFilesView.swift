import SwiftUI

struct LargestFilesView: View {
    @ObservedObject var store: DiskUsageStore
    @Binding var selectedNode: DiskNode?
    @Binding var pendingTrash: DiskNode?

    @State private var filter = ""

    private var displayedFiles: [DiskNode] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.largestFiles }
        return store.largestFiles.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if store.largestFiles.isEmpty {
                emptyState
            } else {
                TextField("Filter files", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)

                Divider()

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
            }

            Divider()
            safetyFooter
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Largest files")
                    .font(.headline)

                Text(listScopeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if store.scanning {
                ProgressView()
                    .controlSize(.small)
            }

            Text("\(store.largestFiles.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(.bar)
    }

    private var listScopeLabel: String {
        if store.scanning {
            return "Updating across all folders"
        }
        if store.scanStopped {
            return "Partial results from stopped scan"
        }
        return "Across the complete scan"
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.number")
                .font(.system(size: 25))
                .foregroundStyle(.tertiary)

            Text(store.scanning ? "Finding large files…" : "No files found")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2)
                .fill(FileCategoryColor.color(for: file, sizeRatio: 0.78))
                .frame(width: 5, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                Text(URL(fileURLWithPath: file.path).deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            Text(ByteFormatter.string(from: file.size))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if hovered || isSelected {
                Button {
                    store.revealInFinder(file)
                } label: {
                    Image(systemName: "finder")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 50)
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
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .help("\(file.path) — \(ByteFormatter.string(from: file.size))")
        .contextMenu {
            NodeActionsMenu(node: file, store: store, pendingTrash: $pendingTrash)
        }
    }
}
