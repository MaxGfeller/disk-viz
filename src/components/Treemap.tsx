import { useRef, useState, useEffect, useCallback, useMemo } from "react";
import type { TreeNode } from "../lib/types";
import { useTreemapLayout, type LayoutNode } from "../hooks/useTreemapLayout";
import { TreemapRect } from "./TreemapRect";
import { Breadcrumb } from "./Breadcrumb";
import { ContextMenu } from "./ContextMenu";
import { formatBytes } from "../lib/format";

interface Props {
  data: TreeNode;
  onRescan: (path: string) => void;
  onDelete: (path: string) => void;
  scanning?: boolean;
  scanProgress?: { dirsFound: number; dirsCompleted: number } | null;
}

interface ContextMenuState {
  node: LayoutNode;
  x: number;
  y: number;
}

/** Track original sizes so collapsed rects still show their real size. */
type SizeMap = Map<string, number>;

const COLLAPSED_STORAGE_KEY = "disk-viz-collapsed";

function loadCollapsed(): Set<string> {
  try {
    const stored = localStorage.getItem(COLLAPSED_STORAGE_KEY);
    return stored ? new Set(JSON.parse(stored)) : new Set();
  } catch {
    return new Set();
  }
}

function saveCollapsed(paths: Set<string>) {
  localStorage.setItem(COLLAPSED_STORAGE_KEY, JSON.stringify([...paths]));
}

/** Walk the tree from root to find the full path of ancestor nodes to targetPath. */
function buildZoomPath(root: TreeNode, targetPath: string): TreeNode[] {
  const result: TreeNode[] = [root];
  let current = root;
  while (current.path !== targetPath) {
    if (!current.children) break;
    const next = current.children.find(
      (c) => c.path === targetPath || targetPath.startsWith(c.path + "/")
    );
    if (!next) break;
    result.push(next);
    if (next.path === targetPath) break;
    current = next;
  }
  return result;
}

export function Treemap({ data, onRescan, onDelete, scanning, scanProgress }: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [dimensions, setDimensions] = useState({ width: 0, height: 0 });
  const [contextMenu, setContextMenu] = useState<ContextMenuState | null>(null);
  const [collapsedPaths, setCollapsedPaths] = useState<Set<string>>(loadCollapsed);

  // Persist collapsed paths to localStorage
  useEffect(() => {
    saveCollapsed(collapsedPaths);
  }, [collapsedPaths]);

  // Drill-down state: path of nodes from root to current zoom
  const [zoomPath, setZoomPath] = useState<TreeNode[]>([data]);

  // When data changes, rebuild zoom path from new tree —
  // but SKIP during streaming to avoid resetting user navigation.
  useEffect(() => {
    setZoomPath((prev) => {
      if (prev.length <= 1) return [data]; // root level: always update
      if (scanning) return prev; // user navigated deeper: freeze during scan
      // Non-scanning update (deletion, rescan finished): rebuild path
      const newPath: TreeNode[] = [data];
      let current = data;
      for (let i = 1; i < prev.length; i++) {
        const match = current.children?.find(
          (c) => c.path === prev[i].path
        );
        if (!match) break;
        newPath.push(match);
        current = match;
      }
      return newPath;
    });
  }, [data, scanning]);

  // Track container size
  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;

    const obs = new ResizeObserver((entries) => {
      const { width, height } = entries[0].contentRect;
      setDimensions({ width, height });
    });
    obs.observe(el);
    return () => obs.disconnect();
  }, []);

  const currentNode = zoomPath[zoomPath.length - 1];

  // Build display tree with collapsed directories shrunk
  const { displayNode, originalSizes } = useMemo(() => {
    if (collapsedPaths.size === 0)
      return { displayNode: currentNode, originalSizes: new Map() as SizeMap };
    const sizes: SizeMap = new Map();
    const node = withCollapsed(currentNode, collapsedPaths, sizes);
    return { displayNode: node, originalSizes: sizes };
  }, [currentNode, collapsedPaths]);

  const layout = useTreemapLayout(
    displayNode,
    dimensions.width,
    dimensions.height
  );

  const handleDrillDown = useCallback(
    (layoutNode: LayoutNode) => {
      if (layoutNode.data.type !== "directory") return;
      // Clicking a collapsed directory expands it
      if (collapsedPaths.has(layoutNode.data.path)) {
        setCollapsedPaths((prev) => {
          const next = new Set(prev);
          next.delete(layoutNode.data.path);
          return next;
        });
        return;
      }
      if (layoutNode.data.truncated || !layoutNode.data.children) {
        if (!scanning) onRescan(layoutNode.data.path);
        return;
      }
      if (layoutNode.children) {
        setZoomPath(buildZoomPath(data, layoutNode.data.path));
      }
    },
    [data, onRescan, scanning, collapsedPaths]
  );

  const handleBreadcrumb = useCallback((index: number) => {
    setZoomPath((prev) => prev.slice(0, index + 1));
  }, []);

  const handleContextMenu = useCallback(
    (node: LayoutNode, e: React.MouseEvent) => {
      setContextMenu({ node, x: e.clientX, y: e.clientY });
    },
    []
  );

  const closeContextMenu = useCallback(() => setContextMenu(null), []);

  const handleDeleteConfirm = useCallback(async () => {
    if (!contextMenu) return;
    const path = contextMenu.node.data.path;
    setContextMenu(null);
    try {
      const res = await fetch("/api/delete", {
        method: "DELETE",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path }),
      });
      if (!res.ok) {
        const body = await res
          .json()
          .catch(() => ({ error: res.statusText }));
        alert(`Delete failed: ${body.error || res.statusText}`);
        return;
      }
      onDelete(path);
    } catch (err: any) {
      alert(`Delete failed: ${err.message}`);
    }
  }, [contextMenu, onDelete]);

  const handleToggleCollapse = useCallback(() => {
    if (!contextMenu) return;
    const path = contextMenu.node.data.path;
    setContextMenu(null);
    setCollapsedPaths((prev) => {
      const next = new Set(prev);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });
  }, [contextMenu]);

  // Escape to go up
  useEffect(() => {
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === "Escape" && zoomPath.length > 1) {
        setZoomPath((prev) => prev.slice(0, -1));
      }
    };
    window.addEventListener("keydown", handleKey);
    return () => window.removeEventListener("keydown", handleKey);
  }, [zoomPath.length]);

  const renderNodes = (node: LayoutNode): React.ReactNode[] => {
    const result: React.ReactNode[] = [];

    if (!node.children) {
      // Leaf (file or truncated/collapsed directory)
      const parent = node.parent;
      const maxSibling = parent
        ? Math.max(...parent.children!.map((c) => c.value ?? 0))
        : node.value ?? 1;
      const isCollapsed = collapsedPaths.has(node.data.path);
      result.push(
        <TreemapRect
          key={node.data.path}
          node={node}
          maxSiblingSize={maxSibling}
          onClick={handleDrillDown}
          onContextMenu={handleContextMenu}
          collapsed={isCollapsed}
          originalSize={
            isCollapsed ? originalSizes.get(node.data.path) : undefined
          }
        />
      );
      return result;
    }

    // Directory with children — render background
    if (node.depth > 0) {
      const w = node.x1 - node.x0;
      const h = node.y1 - node.y0;
      if (w > 1 && h > 1) {
        result.push(
          <g key={node.data.path + "-group"}>
            <rect
              x={node.x0}
              y={node.y0}
              width={w}
              height={h}
              fill="rgba(255,255,255,0.04)"
              stroke="rgba(255,255,255,0.15)"
              strokeWidth={1}
              onClick={(e) => {
                e.stopPropagation();
                handleDrillDown(node);
              }}
              onContextMenu={(e) => {
                e.preventDefault();
                e.stopPropagation();
                handleContextMenu(node, e);
              }}
              style={{ cursor: "pointer" }}
            />
            {w > 50 && (
              <text
                x={node.x0 + 4}
                y={node.y0 + 14}
                className="dir-label"
                style={{ pointerEvents: "none" }}
              >
                {node.data.name} ({formatBytes(node.value ?? 0)})
              </text>
            )}
          </g>
        );
      }
    }

    // Render children
    for (const child of node.children) {
      result.push(...renderNodes(child));
    }

    return result;
  };

  return (
    <div className="treemap-container">
      <div className="treemap-header">
        <Breadcrumb path={zoomPath} onNavigate={handleBreadcrumb} />
        <span className="treemap-total">
          {scanning && <span className="spinner-small" />}
          {scanning && scanProgress && scanProgress.dirsFound > 0 && (
            <span className="scan-progress">
              {Math.round((scanProgress.dirsCompleted / scanProgress.dirsFound) * 100)}%
              {" "}
            </span>
          )}
          Total: {formatBytes(currentNode.size)}
        </span>
      </div>
      <div className="treemap-svg-wrap" ref={containerRef}>
        {layout && dimensions.width > 0 && (
          <svg width={dimensions.width} height={dimensions.height}>
            {renderNodes(layout)}
          </svg>
        )}
      </div>
      {contextMenu && (
        <ContextMenu
          node={contextMenu.node}
          x={contextMenu.x}
          y={contextMenu.y}
          onDelete={handleDeleteConfirm}
          onClose={closeContextMenu}
          isCollapsed={collapsedPaths.has(contextMenu.node.data.path)}
          onToggleCollapse={handleToggleCollapse}
        />
      )}
    </div>
  );
}

/**
 * Create a modified tree where collapsed directories are replaced with
 * small leaf nodes. The rest of the siblings expand to fill the space.
 */
function withCollapsed(
  node: TreeNode,
  collapsed: Set<string>,
  sizes: SizeMap
): TreeNode {
  if (!node.children || node.children.length === 0) return node;

  let hasCollapsed = false;
  const processed = node.children.map((c) => {
    if (collapsed.has(c.path)) {
      hasCollapsed = true;
      sizes.set(c.path, c.size);
      return { ...c, children: undefined, size: 0 } as TreeNode;
    }
    return withCollapsed(c, collapsed, sizes);
  });

  if (!hasCollapsed && processed.every((c, i) => c === node.children![i])) {
    return node; // no changes in this subtree
  }

  // All collapsed nodes together get ~1% of the space — just enough for labels
  const nonCollapsedTotal = processed
    .filter((c) => !collapsed.has(c.path))
    .reduce((s, c) => s + c.size, 0);
  const collapsedCount = processed.filter((c) => collapsed.has(c.path)).length;
  const collapsedSize = Math.max(1, (nonCollapsedTotal * 0.01) / collapsedCount);

  const final = processed.map((c) =>
    collapsed.has(c.path) ? { ...c, size: collapsedSize } : c
  );
  const totalSize = final.reduce((s, c) => s + c.size, 0);
  return { ...node, children: final, size: totalSize };
}
