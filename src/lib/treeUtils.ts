import type { TreeNode } from "./types";

/**
 * Returns a new tree with the node at `targetPath` removed
 * and all ancestor sizes recalculated.
 * Returns null if the root itself is the target.
 */
export function removeNode(
  root: TreeNode,
  targetPath: string
): TreeNode | null {
  if (root.path === targetPath) return null;
  return pruneRecursive(root, targetPath);
}

function pruneRecursive(node: TreeNode, targetPath: string): TreeNode {
  if (!node.children) return node;

  const newChildren: TreeNode[] = [];
  for (const child of node.children) {
    if (child.path === targetPath) continue; // remove this child
    newChildren.push(pruneRecursive(child, targetPath));
  }

  const newSize = newChildren.reduce((sum, c) => sum + c.size, 0);
  return { ...node, children: newChildren, size: newSize };
}
