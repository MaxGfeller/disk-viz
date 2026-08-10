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

    static func node(in root: DiskNode, atPath targetPath: String) -> DiskNode? {
        if root.path == targetPath {
            return root
        }

        guard isDescendantPath(targetPath, of: root.path) else {
            return nil
        }

        for child in root.children ?? [] {
            if let match = node(in: child, atPath: targetPath) {
                return match
            }
        }

        return nil
    }

    static func replacingNode(
        in root: DiskNode,
        atPath targetPath: String,
        with replacement: DiskNode
    ) -> DiskNode? {
        guard replacement.path == targetPath else {
            return nil
        }

        if root.path == targetPath {
            return replacement
        }

        guard
            isDescendantPath(targetPath, of: root.path),
            let children = root.children
        else {
            return nil
        }

        for (index, child) in children.enumerated() {
            guard let updatedChild = replacingNode(
                in: child,
                atPath: targetPath,
                with: replacement
            ) else {
                continue
            }

            var updatedChildren = children
            updatedChildren[index] = updatedChild

            var updatedRoot = root
            updatedRoot.children = updatedChildren
            updatedRoot.size = updatedChildren.reduce(Int64(0)) { $0 + $1.size }
            return updatedRoot
        }

        return nil
    }

    /// Keeps an already-open navigation branch reachable when a newer streaming
    /// snapshot folds that branch into its bounded "smaller items" aggregate.
    /// Existing nodes always win; only missing path components are restored.
    static func pinningBranch(in root: DiskNode, ancestry: [DiskNode]) -> DiskNode? {
        guard
            let first = ancestry.first,
            first.path == root.path,
            ancestry.indices.dropLast().allSatisfy({ index in
                isImmediateChildPath(ancestry[index + 1].path, of: ancestry[index].path)
            })
        else {
            return nil
        }

        return pinningBranch(in: root, ancestry: ancestry, index: 0)
    }

    static func isPath(_ path: String, equalToOrDescendantOf ancestor: String) -> Bool {
        path == ancestor || isDescendantPath(path, of: ancestor)
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

    private static func pinningBranch(
        in node: DiskNode,
        ancestry: [DiskNode],
        index: Int
    ) -> DiskNode? {
        guard node.path == ancestry[index].path else { return nil }
        guard index + 1 < ancestry.count else { return node }

        let wanted = ancestry[index + 1]
        var children = node.children ?? []

        if let childIndex = children.firstIndex(where: { $0.path == wanted.path }) {
            guard let updatedChild = pinningBranch(
                in: children[childIndex],
                ancestry: ancestry,
                index: index + 1
            ) else {
                return nil
            }
            children[childIndex] = updatedChild
        } else {
            let restoredBranch = minimalBranch(from: ancestry, index: index + 1)
            let aggregatePath = appendingPathComponent("__other__", to: node.path)

            if let aggregateIndex = children.firstIndex(where: { $0.path == aggregatePath }) {
                if children[aggregateIndex].size > restoredBranch.size {
                    children[aggregateIndex].size -= restoredBranch.size
                } else {
                    children.remove(at: aggregateIndex)
                }
            } else if children.isEmpty, node.size > restoredBranch.size {
                children.append(
                    DiskNode(
                        name: "(other scanned items)",
                        path: aggregatePath,
                        size: node.size - restoredBranch.size,
                        kind: .file
                    )
                )
            }

            children.append(restoredBranch)
        }

        children.sort(by: compareBySizeDescendingWithAggregateLast)
        var updated = node
        updated.children = children
        updated.size = children.reduce(Int64(0)) { $0 + $1.size }
        return updated
    }

    private static func minimalBranch(from ancestry: [DiskNode], index: Int) -> DiskNode {
        guard index + 1 < ancestry.count else { return ancestry[index] }

        let child = minimalBranch(from: ancestry, index: index + 1)
        var node = ancestry[index]
        var children = [child]
        if node.size > child.size {
            children.append(
                DiskNode(
                    name: "(other scanned items)",
                    path: appendingPathComponent("__other__", to: node.path),
                    size: node.size - child.size,
                    kind: .file
                )
            )
        }
        children.sort(by: compareBySizeDescendingWithAggregateLast)
        node.children = children
        node.size = max(node.size, child.size)
        return node
    }

    private static func isImmediateChildPath(_ child: String, of parent: String) -> Bool {
        let childURL = URL(fileURLWithPath: child).standardizedFileURL
        let parentURL = URL(fileURLWithPath: parent, isDirectory: true).standardizedFileURL
        return childURL.deletingLastPathComponent().path == parentURL.path
    }

    private static func appendingPathComponent(_ component: String, to parent: String) -> String {
        (parent as NSString).appendingPathComponent(component)
    }

    private static func compareBySizeDescendingWithAggregateLast(
        _ lhs: DiskNode,
        _ rhs: DiskNode
    ) -> Bool {
        let lhsIsAggregate = lhs.path.hasSuffix("/__other__")
        let rhsIsAggregate = rhs.path.hasSuffix("/__other__")
        if lhsIsAggregate != rhsIsAggregate {
            return !lhsIsAggregate
        }
        if lhs.size != rhs.size {
            return lhs.size > rhs.size
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
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
