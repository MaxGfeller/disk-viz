import SwiftUI

struct ContentView: View {
    @StateObject private var store = DiskUsageStore()
    @State private var zoomPath: [DiskNode] = []
    private let initialScanPath: String

    init(initialScanPath: String = "/") {
        self.initialScanPath = initialScanPath
        _store = StateObject(wrappedValue: DiskUsageStore(initialScanPath: initialScanPath))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScanHeaderView(store: store)
            Divider()

            ZStack {
                Rectangle()
                    .fill(.background)

                if store.loading && store.root == nil {
                    StatusView(
                        text: "Scanning \(store.scanPath)",
                        systemImage: "externaldrive",
                        showsProgress: true
                    )
                } else if let error = store.errorMessage, store.root == nil {
                    StatusView(
                        text: error,
                        systemImage: "exclamationmark.triangle",
                        color: .red
                    )
                } else if store.root != nil {
                    TreemapView(store: store, zoomPath: $zoomPath)
                } else {
                    StatusView(text: "Choose a folder to scan", systemImage: "folder")
                }
            }
        }
        .background(.background)
        .task {
            if store.root == nil && !store.scanning {
                store.scan(initialScanPath)
            }
        }
        .onReceive(store.$root.compactMap { $0 }) { root in
            reconcileZoomPath(with: root)
        }
        .onExitCommand {
            if zoomPath.count > 1 {
                zoomPath.removeLast()
            }
        }
    }

    private func reconcileZoomPath(with root: DiskNode) {
        if zoomPath.count <= 1 {
            zoomPath = [root]
            return
        }

        if store.scanning {
            return
        }

        var rebuilt = [root]
        var current = root

        for previousNode in zoomPath.dropFirst() {
            guard let match = current.children?.first(where: { $0.path == previousNode.path }) else {
                break
            }
            rebuilt.append(match)
            current = match
        }

        zoomPath = rebuilt
    }
}

private struct StatusView: View {
    var text: String
    var systemImage: String
    var color: Color = .secondary
    var showsProgress = false

    var body: some View {
        VStack(spacing: 12) {
            if showsProgress {
                ProgressView()
                    .controlSize(.regular)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(color.opacity(0.75))
            }

            Text(text)
                .font(.callout)
                .foregroundStyle(color)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(24)
    }
}
