import AppKit
import SwiftUI

struct TreemapView: View {
    @ObservedObject var store: DiskUsageStore
    @Binding var focusPath: String?
    @Binding var selectedNode: DiskNode?
    @Binding var pendingTrash: DiskNode?

    private var navigationPath: [DiskNode] {
        guard let root = store.root else { return [] }
        return TreeOperations.buildZoomPath(
            root: root,
            targetPath: focusPath ?? root.path
        )
    }

    private var currentNode: DiskNode? {
        navigationPath.last ?? store.root
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()

            GeometryReader { proxy in
                if let currentNode,
                   let layout = TreemapLayoutEngine.layout(
                       root: currentNode,
                       width: max(0, proxy.size.width - 16),
                       height: max(0, proxy.size.height - 16)
                   ) {
                    ZStack(alignment: .topLeading) {
                        TreemapBackdrop()

                        if layout.children.isEmpty {
                            EmptyDirectoryView(node: currentNode, isScanning: store.scanning)
                        } else {
                            ForEach(layout.children) { child in
                                TreemapTile(
                                    layoutNode: child,
                                    isSelected: selectedNode?.path == child.node.path,
                                    store: store,
                                    pendingTrash: $pendingTrash,
                                    onActivate: activate
                                )
                            }
                        }
                    }
                    .frame(width: proxy.size.width - 16, height: proxy.size.height - 16)
                    .padding(8)
                    .clipped()
                }
            }

            if let selectedNode, !isSyntheticDiskNode(selectedNode) {
                Divider()
                SelectedNodeBar(
                    node: selectedNode,
                    store: store,
                    pendingTrash: $pendingTrash,
                    onOpen: activate
                )
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var navigationBar: some View {
        HStack(spacing: 10) {
            Button(action: navigateUp) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(navigationPath.count <= 1)
            .help("Go to Parent Folder (Esc)")

            BreadcrumbView(path: navigationPath) { index in
                focusPath = navigationPath[index].path
                selectedNode = nil
            }

            Spacer(minLength: 12)

            if let currentNode {
                Text("\(currentNode.children?.count ?? 0) items")
                    .foregroundStyle(.tertiary)
                Text(ByteFormatter.string(from: currentNode.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.bar)
    }

    private func activate(_ node: DiskNode) {
        guard !isSyntheticDiskNode(node) else { return }
        selectedNode = node

        guard node.isDirectory else { return }
        if node.hasChildren {
            focusPath = node.path
            selectedNode = nil
        } else if node.truncated && !store.scanning {
            store.scan(node.path)
        }
    }

    private func navigateUp() {
        guard navigationPath.count > 1 else { return }
        focusPath = navigationPath[navigationPath.count - 2].path
        selectedNode = nil
    }
}

private struct TreemapBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)

            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.035),
                    Color.clear,
                    Color.primary.opacity(0.018)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TreemapTile: View {
    var layoutNode: TreemapLayoutNode
    var isSelected: Bool
    @ObservedObject var store: DiskUsageStore
    @Binding var pendingTrash: DiskNode?
    var onActivate: (DiskNode) -> Void

    @State private var hovered = false

    private var visualRect: CGRect {
        let amount = min(2, max(0, min(layoutNode.rect.width, layoutNode.rect.height) / 8))
        return layoutNode.rect.insetBy(dx: amount, dy: amount)
    }

    private var sizeRatio: Double {
        guard layoutNode.maxSiblingValue > 0 else { return 0 }
        return min(1, max(0, layoutNode.value / layoutNode.maxSiblingValue))
    }

    private var tileColor: Color {
        if layoutNode.node.isDirectory {
            let brightness = 0.76 - (sizeRatio * 0.34)
            return Color(hue: 0.58, saturation: 0.58, brightness: brightness)
        }
        return FileCategoryColor.color(for: layoutNode.node, sizeRatio: sizeRatio)
    }

    var body: some View {
        let rect = visualRect

        Button {
            onActivate(layoutNode.node)
        } label: {
            RoundedRectangle(cornerRadius: min(8, max(3, rect.height / 10)), style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tileColor.opacity(0.98), tileColor.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: min(8, max(3, rect.height / 10)), style: .continuous)
                        .strokeBorder(
                            isSelected
                                ? Color.accentColor
                                : Color.white.opacity(hovered ? 0.75 : 0.20),
                            lineWidth: isSelected ? 3 : (hovered ? 2 : 1)
                        )
                }
                .overlay(alignment: .topLeading) {
                    tileLabel(in: rect)
                }
                .shadow(color: .black.opacity(hovered ? 0.20 : 0.08), radius: hovered ? 5 : 1, y: 1)
                .frame(width: rect.width, height: rect.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(x: rect.midX, y: rect.midY)
        .contentShape(Rectangle())
        .accessibilityLabel(Text(layoutNode.node.name))
        .accessibilityValue(
            Text("\(ByteFormatter.string(from: layoutNode.node.size)), \(layoutNode.node.isDirectory ? "folder" : "file")")
        )
        .accessibilityHint(Text(accessibilityHint))
        .accessibilityAction(named: Text("Reveal in Finder")) {
            store.revealInFinder(layoutNode.node)
        }
        .scaleEffect(hovered && rect.width > 28 && rect.height > 28 ? 0.992 : 1)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onHover { hovered = $0 }
        .help("\(layoutNode.node.name) — \(ByteFormatter.string(from: layoutNode.node.size))")
        .contextMenu {
            NodeActionsMenu(
                node: layoutNode.node,
                store: store,
                pendingTrash: $pendingTrash
            )
        }
    }

    private var accessibilityHint: String {
        let node = layoutNode.node
        if node.isDirectory && node.hasChildren {
            return "Open this folder in the treemap."
        }
        if node.isDirectory && node.truncated && !store.scanning {
            return "Scan this folder in more detail."
        }
        return node.isDirectory ? "Select this folder." : "Select this file."
    }

    @ViewBuilder
    private func tileLabel(in rect: CGRect) -> some View {
        if rect.width > 54 && rect.height > 24 {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: layoutNode.node.isDirectory ? "folder.fill" : "doc.fill")
                        .font(.system(size: 10, weight: .semibold))

                    Text(layoutNode.node.name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }

                if rect.width > 82 && rect.height > 44 {
                    Text(ByteFormatter.string(from: layoutNode.node.size))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .opacity(0.82)
                }
            }
            .foregroundStyle(Color.white)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            .padding(.horizontal, min(9, max(4, rect.width / 12)))
            .padding(.top, min(8, max(4, rect.height / 12)))
            .frame(maxWidth: max(0, rect.width - 8), alignment: .leading)
            .allowsHitTesting(false)
        }
    }
}

private struct SelectedNodeBar: View {
    var node: DiskNode
    @ObservedObject var store: DiskUsageStore
    @Binding var pendingTrash: DiskNode?
    var onOpen: (DiskNode) -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(FileCategoryColor.color(for: node, sizeRatio: 0.8))
                .frame(width: 7, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(node.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(ByteFormatter.string(from: node.size))
                .font(.callout.weight(.medium))
                .monospacedDigit()

            if node.isDirectory && node.hasChildren {
                Button("Open") {
                    onOpen(node)
                }
            }

            Button {
                store.revealInFinder(node)
            } label: {
                Label("Reveal", systemImage: "finder")
            }

            Menu {
                NodeActionsMenu(node: node, store: store, pendingTrash: $pendingTrash)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 54)
        .background(.bar)
    }
}

private struct EmptyDirectoryView: View {
    var node: DiskNode
    var isScanning: Bool

    var body: some View {
        VStack(spacing: 10) {
            if isScanning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "folder")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
            }

            Text(isScanning ? "Discovering contents…" : "No visible contents")
                .font(.callout)
                .foregroundStyle(.secondary)

            if node.truncated {
                Text("Open this folder to scan it in more detail.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
