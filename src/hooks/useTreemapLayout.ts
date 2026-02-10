import { useMemo } from "react";
import { hierarchy, treemap, treemapSquarify } from "d3-hierarchy";
import type { TreeNode } from "../lib/types";
import type { HierarchyRectangularNode } from "d3-hierarchy";

export type LayoutNode = HierarchyRectangularNode<TreeNode>;

const MAX_RECTS = 500;

export function useTreemapLayout(
  root: TreeNode | null,
  width: number,
  height: number
): LayoutNode | null {
  return useMemo(() => {
    if (!root || width <= 0 || height <= 0) return null;

    // Prune small children to cap rendered rects
    const pruned = pruneTree(root, MAX_RECTS);

    const h = hierarchy(pruned)
      .sum((d) => (!d.children || d.children.length === 0) ? d.size : 0)
      .sort((a, b) => (b.value ?? 0) - (a.value ?? 0));

    const layout = treemap<TreeNode>()
      .size([width, height])
      .paddingTop(20)
      .paddingRight(2)
      .paddingBottom(2)
      .paddingLeft(2)
      .paddingInner(1)
      .tile(treemapSquarify.ratio(1.2));

    return layout(h);
  }, [root, width, height]);
}

/** Keep only the largest children, up to `maxNodes` total leaves. */
function pruneTree(node: TreeNode, maxNodes: number): TreeNode {
  if (!node.children || node.children.length === 0) return node;

  // Children are already sorted by size desc from scanner
  const children: TreeNode[] = [];
  let leafCount = 0;

  for (const child of node.children) {
    if (leafCount >= maxNodes) break;
    if (child.type === "file") {
      children.push(child);
      leafCount++;
    } else {
      const pruned = pruneTree(child, maxNodes - leafCount);
      const leaves = countLeaves(pruned);
      children.push(pruned);
      leafCount += leaves;
    }
  }

  return { ...node, children };
}

function countLeaves(node: TreeNode): number {
  if (!node.children || node.children.length === 0) return 1;
  return node.children.reduce((sum, c) => sum + countLeaves(c), 0);
}
