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

            ZStack {
                Color(red: 0.10, green: 0.10, blue: 0.18)

                if store.loading && store.root == nil {
                    StatusView(text: "Scanning...", showsProgress: true)
                } else if let error = store.errorMessage, store.root == nil {
                    StatusView(text: "Error: \(error)", color: .red)
                } else if store.root != nil {
                    TreemapView(store: store, zoomPath: $zoomPath)
                } else {
                    StatusView(text: "Enter a directory path and click Scan")
                }
            }
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.18))
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
    var color: Color = .white.opacity(0.35)
    var showsProgress = false

    var body: some View {
        HStack(spacing: 10) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            }

            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
        }
    }
}
