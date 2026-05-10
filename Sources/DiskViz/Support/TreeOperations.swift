import Foundation

enum TreeOperations {
    private static let collapsedSizeFraction = 0.01

    static func removeNode(from root: DiskNode, targetPath: String) -> DiskNode? {
        guard root.path != targetPath else { return nil }
        return removeNodeRecursive(root, targetPath: targetPath)
    }

    static func buildZoomPath(root: DiskNode, targetPath: String) -> [DiskNode] {
        var result = [root]
        var current = root

        while current.path != targetPath {
            guard let children = current.children else { break }
            guard let next = children.first(where: { child in
                child.path == targetPath || isDescendantPath(targetPath, of: child.path)
            }) else {
                break
            }

            result.append(next)
            if next.path == targetPath { break }
            current = next
        }

        return result
    }

    static func withCollapsed(
        _ node: DiskNode,
        collapsedPaths: Set<String>
    ) -> (node: DiskNode, originalSizes: [String: Int64]) {
        var sizes: [String: Int64] = [:]
        let displayNode = collapsedNode(node, collapsedPaths: collapsedPaths, sizes: &sizes)
        return (displayNode, sizes)
    }

    private static func removeNodeRecursive(_ node: DiskNode, targetPath: String) -> DiskNode {
        guard let children = node.children else { return node }

        let newChildren = children.compactMap { child -> DiskNode? in
            if child.path == targetPath { return nil }
            return removeNodeRecursive(child, targetPath: targetPath)
        }
        var updated = node
        updated.children = newChildren
        updated.size = newChildren.reduce(0) { $0 + $1.size }
        return updated
    }

    private static func collapsedNode(
        _ node: DiskNode,
        collapsedPaths: Set<String>,
        sizes: inout [String: Int64]
    ) -> DiskNode {
        guard let children = node.children, !children.isEmpty else { return node }

        var hasCollapsedChild = false
        let processed = children.map { child -> DiskNode in
            if collapsedPaths.contains(child.path) {
                hasCollapsedChild = true
                sizes[child.path] = child.size
                var collapsed = child
                collapsed.children = nil
                collapsed.size = 0
                return collapsed
            }
            return collapsedNode(child, collapsedPaths: collapsedPaths, sizes: &sizes)
        }

        guard hasCollapsedChild else {
            var updated = node
            updated.children = processed
            return updated
        }

        let collapsedCount = processed.filter { collapsedPaths.contains($0.path) }.count
        let nonCollapsedTotal = processed
            .filter { !collapsedPaths.contains($0.path) }
            .reduce(Int64(0)) { $0 + $1.size }
        let collapsedSize = max(
            Int64(1),
            Int64((Double(nonCollapsedTotal) * collapsedSizeFraction) / Double(max(collapsedCount, 1)))
        )

        let finalChildren = processed.map { child -> DiskNode in
            guard collapsedPaths.contains(child.path) else { return child }
            var updated = child
            updated.size = collapsedSize
            return updated
        }

        var updated = node
        updated.children = finalChildren
        updated.size = finalChildren.reduce(0) { $0 + $1.size }
        return updated
    }

    private static func isDescendantPath(_ path: String, of ancestor: String) -> Bool {
        if ancestor == "/" {
            return path.hasPrefix("/") && path != "/"
        }
        return path.hasPrefix(ancestor + "/")
    }
}
