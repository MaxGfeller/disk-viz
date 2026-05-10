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
    private static let midChildLimit = 16
    private static let deepChildLimit = 8
    private static let maxVisibleDepth = 3
    private static let targetRatio: CGFloat = 1.2
    private static let paddingTop: CGFloat = 20
    private static let paddingRight: CGFloat = 2
    private static let paddingBottom: CGFloat = 2
    private static let paddingLeft: CGFloat = 2
    private static let paddingInner: CGFloat = 1

    static func layout(root: DiskNode, width: CGFloat, height: CGFloat) -> TreemapLayoutNode? {
        guard width > 0, height > 0 else { return nil }

        let pruned = pruneTree(root, depth: 0)
        let item = TreemapItem(node: pruned, depth: 0)
        item.rect = CGRect(x: 0, y: 0, width: width, height: height)
        layoutChildren(of: item)

        return materialize(item, maxSiblingValue: item.value)
    }

    private static func pruneTree(_ node: DiskNode, depth: Int) -> DiskNode {
        guard let children = node.children, !children.isEmpty else { return node }

        if depth >= maxVisibleDepth {
            var collapsed = node
            collapsed.children = nil
            collapsed.truncated = true
            return collapsed
        }

        let sortedChildren = children.sorted { lhs, rhs in
            lhs.size == rhs.size
                ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                : lhs.size > rhs.size
        }

        let limit = childLimit(forDepth: depth)
        var kept = sortedChildren.prefix(limit).map { child in
            pruneTree(child, depth: depth + 1)
        }

        let dropped = sortedChildren.dropFirst(limit)
        let droppedSize = dropped.reduce(Int64(0)) { $0 + $1.size }
        if !dropped.isEmpty && droppedSize > 0 {
            kept.append(
                DiskNode(
                    name: "(\(dropped.count) smaller items)",
                    path: node.path.appendingPathComponent("__layout_other_\(depth)__"),
                    size: droppedSize,
                    kind: .file
                )
            )
        }

        var updated = node
        updated.children = kept
        updated.size = kept.reduce(Int64(0)) { $0 + $1.size }
        return updated
    }

    private static func childLimit(forDepth depth: Int) -> Int {
        switch depth {
        case 0:
            rootChildLimit
        case 1:
            midChildLimit
        default:
            deepChildLimit
        }
    }

    private static func layoutChildren(of item: TreemapItem) {
        guard let children = item.children, !children.isEmpty else { return }

        let contentRect = CGRect(
            x: item.rect.minX + paddingLeft,
            y: item.rect.minY + paddingTop,
            width: max(0, item.rect.width - paddingLeft - paddingRight),
            height: max(0, item.rect.height - paddingTop - paddingBottom)
        )

        guard contentRect.width > 0, contentRect.height > 0 else {
            children.forEach { $0.rect = .zero }
            return
        }

        let totalValue = children.reduce(0) { $0 + max($1.value, 0) }
        guard totalValue > 0 else {
            children.forEach { $0.rect = .zero }
            return
        }

        let scale = Double(contentRect.width * contentRect.height) / totalValue
        let entries = children.map {
            SquarifyEntry(item: $0, area: CGFloat(max($0.value * scale, 0)))
        }

        squarify(entries, in: contentRect)

        for child in children {
            child.rect = inset(rect: child.rect, by: paddingInner / 2)
            layoutChildren(of: child)
        }
    }

    private static func squarify(_ entries: [SquarifyEntry], in rect: CGRect) {
        var remainingEntries = entries.filter { $0.area > 0 }
        var remainingRect = rect
        var row: [SquarifyEntry] = []

        while let next = remainingEntries.first {
            let side = max(1, min(remainingRect.width, remainingRect.height))
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
                let width = isLast ? rect.maxX - x : entry.area / max(rowHeight, 1)
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
                let height = isLast ? rect.maxY - y : entry.area / max(rowWidth, 1)
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

    private static func inset(rect: CGRect, by amount: CGFloat) -> CGRect {
        guard rect.width > amount * 2, rect.height > amount * 2 else { return rect }
        return rect.insetBy(dx: amount, dy: amount)
    }

    private static func materialize(
        _ item: TreemapItem,
        maxSiblingValue: Double
    ) -> TreemapLayoutNode {
        let childMax = item.children?.map(\.value).max() ?? item.value
        return TreemapLayoutNode(
            id: "\(item.node.path)#\(item.depth)",
            node: item.node,
            rect: item.rect,
            depth: item.depth,
            value: item.value,
            maxSiblingValue: max(maxSiblingValue, 1),
            children: item.children?.map {
                materialize($0, maxSiblingValue: max(childMax, 1))
            } ?? []
        )
    }
}

private final class TreemapItem {
    var node: DiskNode
    var rect: CGRect = .zero
    var depth: Int
    var value: Double
    var children: [TreemapItem]?

    init(node: DiskNode, depth: Int) {
        self.node = node
        self.depth = depth
        self.children = node.children?.map { TreemapItem(node: $0, depth: depth + 1) }
        if let children, !children.isEmpty {
            self.value = children.reduce(0) { $0 + $1.value }
        } else {
            self.value = max(Double(node.size), 0)
        }
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
