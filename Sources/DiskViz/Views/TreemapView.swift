import AppKit
import SwiftUI

struct TreemapView: View {
    private static let collapsedStorageKey = "disk-viz-collapsed"

    @ObservedObject var store: DiskUsageStore
    @Binding var zoomPath: [DiskNode]

    @State private var collapsedPaths = TreemapView.loadCollapsedPaths()
    @State private var pendingDelete: DiskNode?

    private var currentNode: DiskNode? {
        zoomPath.last ?? store.root
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            GeometryReader { proxy in
                if let currentNode {
                    let display = TreeOperations.withCollapsed(
                        currentNode,
                        collapsedPaths: collapsedPaths
                    )

                    if let layout = TreemapLayoutEngine.layout(
                        root: display.node,
                        width: proxy.size.width,
                        height: proxy.size.height
                    ) {
                        let nodes = layout.flattened
                        let groups = nodes
                            .filter { $0.depth > 0 && !$0.isLeaf }
                            .sorted { $0.depth < $1.depth }
                        let leaves = nodes.filter(\.isLeaf)

                        ZStack(alignment: .topLeading) {
                            Color(nsColor: .controlBackgroundColor)

                            ForEach(groups) { group in
                                DirectoryGroupView(
                                    layoutNode: group,
                                    collapsedPaths: $collapsedPaths,
                                    pendingDelete: $pendingDelete,
                                    onNodeClick: handleNodeClick
                                )
                            }

                            ForEach(leaves) { leaf in
                                TreemapLeafView(
                                    layoutNode: leaf,
                                    collapsedPaths: $collapsedPaths,
                                    originalSize: display.originalSizes[leaf.node.path],
                                    pendingDelete: $pendingDelete,
                                    onNodeClick: handleNodeClick
                                )
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                    }
                }
            }
        }
        .onChange(of: collapsedPaths) { _, newValue in
            UserDefaults.standard.set(Array(newValue), forKey: Self.collapsedStorageKey)
        }
        .alert(item: $pendingDelete) { node in
            Alert(
                title: Text("Delete \(node.name)?"),
                message: Text(node.path),
                primaryButton: .destructive(Text("Delete")) {
                    store.delete(node)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var header: some View {
        HStack {
            BreadcrumbView(path: zoomPath) { index in
                zoomPath = Array(zoomPath.prefix(index + 1))
            }

            Spacer(minLength: 12)

            if store.scanning {
                ProgressView()
                    .controlSize(.small)

                if let progress = store.progress, progress.dirsFound > 0 {
                    Text("\(progress.percentComplete)%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Text("Total: \(ByteFormatter.string(from: currentNode?.size ?? 0))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(.bar)
    }

    private func handleNodeClick(_ node: DiskNode) {
        guard !node.path.contains("__layout_other_") else { return }
        guard node.isDirectory else { return }

        if collapsedPaths.contains(node.path) {
            collapsedPaths.remove(node.path)
            return
        }

        if node.truncated || !(node.children?.isEmpty == false) {
            if !store.scanning {
                store.scan(node.path)
            }
            return
        }

        if let root = store.root {
            zoomPath = TreeOperations.buildZoomPath(root: root, targetPath: node.path)
        }
    }

    private static func loadCollapsedPaths() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedStorageKey) ?? [])
    }
}

private struct DirectoryGroupView: View {
    var layoutNode: TreemapLayoutNode
    @Binding var collapsedPaths: Set<String>
    @Binding var pendingDelete: DiskNode?
    var onNodeClick: (DiskNode) -> Void

    var body: some View {
        let rect = layoutNode.rect

        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.primary.opacity(0.04))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(.secondary.opacity(0.20), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                if rect.width > 50 && rect.height > 18 {
                    Text("\(layoutNode.node.name) (\(ByteFormatter.string(from: Int64(layoutNode.value))))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 4)
                        .padding(.top, 3)
                        .frame(maxWidth: max(0, rect.width - 8), alignment: .leading)
                        .clipped()
                        .allowsHitTesting(false)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .contentShape(Rectangle())
            .onTapGesture {
                onNodeClick(layoutNode.node)
            }
            .contextMenu {
                NodeContextMenu(
                    node: layoutNode.node,
                    isCollapsed: collapsedPaths.contains(layoutNode.node.path),
                    pendingDelete: $pendingDelete,
                    onToggleCollapse: toggleCollapse
                )
            }
    }

    private func toggleCollapse(_ node: DiskNode) {
        if collapsedPaths.contains(node.path) {
            collapsedPaths.remove(node.path)
        } else {
            collapsedPaths.insert(node.path)
        }
    }
}

private struct TreemapLeafView: View {
    var layoutNode: TreemapLayoutNode
    @Binding var collapsedPaths: Set<String>
    var originalSize: Int64?
    @Binding var pendingDelete: DiskNode?
    var onNodeClick: (DiskNode) -> Void

    @State private var hovered = false

    private var isCollapsed: Bool {
        collapsedPaths.contains(layoutNode.node.path)
    }

    private var displaySize: Int64 {
        originalSize ?? Int64(layoutNode.value)
    }

    var body: some View {
        let rect = layoutNode.rect
        let sizeRatio = layoutNode.maxSiblingValue > 0
            ? layoutNode.value / layoutNode.maxSiblingValue
            : 0
        let labelColor: Color = sizeRatio > 0.55 ? .white : .primary

        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(isCollapsed ? Color.accentColor.opacity(0.12) : FileCategoryColor.color(for: layoutNode.node, sizeRatio: sizeRatio))
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(
                        isCollapsed
                            ? Color.accentColor
                            : (hovered ? .primary.opacity(0.75) : Color(nsColor: .separatorColor).opacity(0.45)),
                        style: StrokeStyle(
                            lineWidth: isCollapsed ? 1 : (hovered ? 2 : 0.5),
                            dash: isCollapsed ? [4, 2] : []
                        )
                    )
            }
            .overlay(alignment: .topLeading) {
                labels(for: rect, color: labelColor)
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture {
                onNodeClick(layoutNode.node)
            }
            .help("\(layoutNode.node.name) - \(ByteFormatter.string(from: displaySize))\(isCollapsed ? " (collapsed)" : "")")
            .contextMenu {
                NodeContextMenu(
                    node: layoutNode.node,
                    isCollapsed: isCollapsed,
                    pendingDelete: $pendingDelete,
                    onToggleCollapse: toggleCollapse
                )
            }
    }

    @ViewBuilder
    private func labels(for rect: CGRect, color: Color) -> some View {
        if rect.width > 40 && rect.height > 16 {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(isCollapsed ? "> " : "")\(truncatedName(width: rect.width))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isCollapsed ? Color.accentColor : color)
                    .lineLimit(1)

                if rect.width > 60 && rect.height > 30 {
                    Text(ByteFormatter.string(from: displaySize))
                        .font(.system(size: 10))
                        .foregroundStyle((isCollapsed ? Color.accentColor : color).opacity(0.72))
                        .lineLimit(1)
                }
            }
            .padding(.leading, 4)
            .padding(.top, 3)
            .frame(maxWidth: max(0, rect.width - 8), alignment: .leading)
            .allowsHitTesting(false)
        }
    }

    private func truncatedName(width: CGFloat) -> String {
        let prefixWidth = isCollapsed ? 2 : 0
        let maxLength = max(0, Int(width / 7) - prefixWidth)
        let name = layoutNode.node.name

        guard maxLength >= 3 else { return "" }
        guard name.count > maxLength else { return name }

        let endIndex = name.index(name.startIndex, offsetBy: maxLength - 3)
        return String(name[..<endIndex]) + "..."
    }

    private func toggleCollapse(_ node: DiskNode) {
        if collapsedPaths.contains(node.path) {
            collapsedPaths.remove(node.path)
        } else {
            collapsedPaths.insert(node.path)
        }
    }
}

private struct NodeContextMenu: View {
    var node: DiskNode
    var isCollapsed: Bool
    @Binding var pendingDelete: DiskNode?
    var onToggleCollapse: (DiskNode) -> Void

    private var canDelete: Bool {
        !node.path.hasSuffix("/__other__") && !node.path.contains("__layout_other_")
    }

    var body: some View {
        Text(node.name)
        Text(ByteFormatter.string(from: node.size))

        if node.isDirectory {
            Divider()
            Button(isCollapsed ? "Expand" : "Collapse") {
                onToggleCollapse(node)
            }
        }

        if canDelete {
            Divider()
            Button("Delete", role: .destructive) {
                pendingDelete = node
            }
        }
    }
}
