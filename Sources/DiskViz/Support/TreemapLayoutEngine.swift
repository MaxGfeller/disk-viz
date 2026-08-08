import CoreGraphics
import Foundation

struct TreemapLayoutNode: Identifiable {
    var id: String
    var node: DiskNode
    var rect: CGRect
    var depth: Int
    var value: Double
    var maxSiblingValue: Double
    var children: [TreemapLayoutNode]

    var isLeaf: Bool {
        children.isEmpty
    }

    var flattened: [TreemapLayoutNode] {
        [self] + children.flatMap(\.flattened)
    }
}

enum TreemapLayoutEngine {
    private static let rootChildLimit = 80
    private static let targetRatio: CGFloat = 1.2

    static func layout(root: DiskNode, width: CGFloat, height: CGFloat) -> TreemapLayoutNode? {
        guard width > 0, height > 0 else { return nil }

        let children = visibleChildren(of: root).map {
            TreemapItem(node: $0, depth: 1)
        }
        let rootValue = children.isEmpty
            ? max(Double(root.size), 0)
            : children.reduce(0) { $0 + $1.value }
        let rootItem = TreemapItem(
            node: root,
            depth: 0,
            value: rootValue,
            children: children
        )
        rootItem.rect = CGRect(x: 0, y: 0, width: width, height: height)
        layoutChildren(of: rootItem)

        return materialize(rootItem, maxSiblingValue: rootItem.value)
    }

    private static func visibleChildren(of root: DiskNode) -> [DiskNode] {
        let sortedChildren = (root.children ?? [])
            .filter { $0.size > 0 }
            .sorted(by: compareBySizeDescending)
        guard sortedChildren.count > rootChildLimit else {
            return sortedChildren
        }

        var visible = Array(sortedChildren.prefix(rootChildLimit))
        let dropped = sortedChildren.dropFirst(rootChildLimit)
        let droppedSize = dropped.reduce(Int64(0)) { $0 + $1.size }
        if droppedSize > 0 {
            visible.append(
                DiskNode(
                    name: "(\(dropped.count) smaller items)",
                    path: root.path.appendingPathComponent("__layout_other_0__"),
                    size: droppedSize,
                    kind: .file
                )
            )
        }

        return visible.sorted(by: compareBySizeDescending)
    }

    private static func compareBySizeDescending(_ lhs: DiskNode, _ rhs: DiskNode) -> Bool {
        if lhs.size != rhs.size {
            return lhs.size > rhs.size
        }

        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }

        return lhs.path < rhs.path
    }

    private static func layoutChildren(of item: TreemapItem) {
        let children = item.children
        guard !children.isEmpty else { return }

        let totalValue = children.reduce(0) { $0 + max($1.value, 0) }
        guard totalValue > 0 else {
            children.forEach { $0.rect = .zero }
            return
        }

        let scale = Double(item.rect.width * item.rect.height) / totalValue
        let entries = children.map {
            SquarifyEntry(item: $0, area: CGFloat(max($0.value * scale, 0)))
        }

        squarify(entries, in: item.rect)
    }

    private static func squarify(_ entries: [SquarifyEntry], in rect: CGRect) {
        var remainingEntries = entries.filter { $0.area > 0 }
        var remainingRect = rect
        var row: [SquarifyEntry] = []

        while let next = remainingEntries.first {
            let side = max(.leastNonzeroMagnitude, min(remainingRect.width, remainingRect.height))
            let candidate = row + [next]

            if row.isEmpty || worstAspectRatio(candidate, side: side) <= worstAspectRatio(row, side: side) {
                row = candidate
                remainingEntries.removeFirst()
            } else {
                remainingRect = layout(row: row, in: remainingRect)
                row.removeAll()
            }
        }

        if !row.isEmpty {
            _ = layout(row: row, in: remainingRect)
        }
    }

    @discardableResult
    private static func layout(row: [SquarifyEntry], in rect: CGRect) -> CGRect {
        let rowArea = row.reduce(CGFloat(0)) { $0 + $1.area }
        guard rowArea > 0, rect.width > 0, rect.height > 0 else { return rect }

        if rect.width >= rect.height {
            let rowHeight = min(rect.height, rowArea / rect.width)
            var x = rect.minX

            for (index, entry) in row.enumerated() {
                let isLast = index == row.count - 1
                let width = isLast
                    ? rect.maxX - x
                    : entry.area / max(rowHeight, .leastNonzeroMagnitude)
                entry.item.rect = CGRect(
                    x: x,
                    y: rect.minY,
                    width: max(0, width),
                    height: rowHeight
                )
                x += width
            }

            return CGRect(
                x: rect.minX,
                y: rect.minY + rowHeight,
                width: rect.width,
                height: max(0, rect.height - rowHeight)
            )
        } else {
            let rowWidth = min(rect.width, rowArea / rect.height)
            var y = rect.minY

            for (index, entry) in row.enumerated() {
                let isLast = index == row.count - 1
                let height = isLast
                    ? rect.maxY - y
                    : entry.area / max(rowWidth, .leastNonzeroMagnitude)
                entry.item.rect = CGRect(
                    x: rect.minX,
                    y: y,
                    width: rowWidth,
                    height: max(0, height)
                )
                y += height
            }

            return CGRect(
                x: rect.minX + rowWidth,
                y: rect.minY,
                width: max(0, rect.width - rowWidth),
                height: rect.height
            )
        }
    }

    private static func worstAspectRatio(_ row: [SquarifyEntry], side: CGFloat) -> CGFloat {
        guard !row.isEmpty else { return .greatestFiniteMagnitude }

        let areas = row.map { max($0.area, .leastNonzeroMagnitude) }
        let sum = areas.reduce(CGFloat(0), +)
        guard sum > 0 else { return .greatestFiniteMagnitude }

        let minArea = areas.min() ?? .leastNonzeroMagnitude
        let maxArea = areas.max() ?? .leastNonzeroMagnitude
        let sideSquared = side * side
        let sumSquared = sum * sum

        return max(
            (sideSquared * maxArea * targetRatio) / sumSquared,
            sumSquared / (sideSquared * minArea * targetRatio)
        )
    }

    private static func materialize(
        _ item: TreemapItem,
        maxSiblingValue: Double
    ) -> TreemapLayoutNode {
        let childMax = item.children.map(\.value).max() ?? item.value
        return TreemapLayoutNode(
            id: "\(item.node.path)#\(item.depth)",
            node: item.node,
            rect: item.rect,
            depth: item.depth,
            value: item.value,
            maxSiblingValue: max(maxSiblingValue, 1),
            children: item.children.map {
                materialize($0, maxSiblingValue: max(childMax, 1))
            }
        )
    }
}

private final class TreemapItem {
    var node: DiskNode
    var rect: CGRect = .zero
    var depth: Int
    var value: Double
    var children: [TreemapItem]

    init(
        node: DiskNode,
        depth: Int,
        value: Double? = nil,
        children: [TreemapItem] = []
    ) {
        self.node = node
        self.depth = depth
        self.value = value ?? max(Double(node.size), 0)
        self.children = children
    }
}

private struct SquarifyEntry {
    var item: TreemapItem
    var area: CGFloat
}

private extension String {
    func appendingPathComponent(_ component: String) -> String {
        (self as NSString).appendingPathComponent(component)
    }
}
