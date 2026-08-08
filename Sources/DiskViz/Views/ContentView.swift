import SwiftUI

struct ContentView: View {
    @StateObject private var store: DiskUsageStore
    @State private var focusPath: String?
    @State private var selectedNode: DiskNode?
    @State private var pendingTrash: DiskNode?

    init(initialScanPath: String = "/") {
        _store = StateObject(wrappedValue: DiskUsageStore(initialScanPath: initialScanPath))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScanHeaderView(store: store)
            Divider()

            workspace
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            if store.root == nil && !store.scanning {
                store.scan()
            }
        }
        .onReceive(store.$root.compactMap { $0 }) { root in
            reconcileNavigation(with: root)
        }
        .onExitCommand(perform: navigateToParent)
        .alert(item: $pendingTrash) { node in
            Alert(
                title: Text("Move \(node.name) to Trash?"),
                message: Text("\(ByteFormatter.string(from: node.size))\n\(node.path)\n\nYou can restore this item from Trash."),
                primaryButton: .destructive(Text("Move to Trash")) {
                    store.moveToTrash(node)
                },
                secondaryButton: .cancel()
            )
        }
    }

    @ViewBuilder
    private var workspace: some View {
        if store.loading && store.root == nil {
            StatusView(
                title: "Indexing \(store.selectedSource?.name ?? "disk")",
                detail: "Large folders will appear as soon as they are discovered.",
                systemImage: "internaldrive",
                showsProgress: true
            )
        } else if let error = store.errorMessage, store.root == nil {
            StatusView(
                title: "Scan couldn’t start",
                detail: error,
                systemImage: "exclamationmark.triangle.fill",
                color: .orange
            )
        } else if store.root != nil {
            HSplitView {
                TreemapView(
                    store: store,
                    focusPath: $focusPath,
                    selectedNode: $selectedNode,
                    pendingTrash: $pendingTrash
                )
                .frame(minWidth: 560)

                LargestFilesView(
                    store: store,
                    selectedNode: $selectedNode,
                    pendingTrash: $pendingTrash
                )
                .frame(minWidth: 290, idealWidth: 340, maxWidth: 430)
            }
        } else {
            StatusView(
                title: "Choose a disk or folder",
                detail: "DiskViz scans the internal disk by default. Other volumes are always opt-in.",
                systemImage: "externaldrive.badge.plus"
            )
        }
    }

    private func reconcileNavigation(with root: DiskNode) {
        guard let focusPath else {
            self.focusPath = root.path
            return
        }

        if !TreeOperations.isPath(focusPath, equalToOrDescendantOf: root.path) {
            self.focusPath = root.path
            selectedNode = nil
            return
        }

        if let selectedNode,
           let refreshed = TreeOperations.node(in: root, atPath: selectedNode.path) {
            self.selectedNode = refreshed
        } else if !store.scanning {
            selectedNode = nil
        }
    }

    private func navigateToParent() {
        guard
            let root = store.root,
            let focusPath,
            focusPath != root.path
        else {
            return
        }

        let path = TreeOperations.buildZoomPath(root: root, targetPath: focusPath)
        if path.count > 1 {
            self.focusPath = path[path.count - 2].path
            selectedNode = nil
        }
    }
}

private struct StatusView: View {
    var title: String
    var detail: String
    var systemImage: String
    var color: Color = .secondary
    var showsProgress = false

    var body: some View {
        VStack(spacing: 14) {
            if showsProgress {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(color.opacity(0.80))
            }

            VStack(spacing: 5) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(detail)
                    .font(.callout)
                    .foregroundStyle(color)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 520)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
