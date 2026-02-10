import { useState } from "react";
import type { LayoutNode } from "../hooks/useTreemapLayout";
import { nodeColor } from "../lib/colors";
import { formatBytes } from "../lib/format";

interface Props {
  node: LayoutNode;
  maxSiblingSize: number;
  onClick: (node: LayoutNode) => void;
  onContextMenu: (node: LayoutNode, e: React.MouseEvent) => void;
  collapsed?: boolean;
  originalSize?: number;
}

export function TreemapRect({
  node,
  maxSiblingSize,
  onClick,
  onContextMenu,
  collapsed,
  originalSize,
}: Props) {
  const [hovered, setHovered] = useState(false);

  const w = node.x1 - node.x0;
  const h = node.y1 - node.y0;

  if (w < 1 || h < 1) return null;

  const sizeRatio = maxSiblingSize > 0 ? (node.value ?? 0) / maxSiblingSize : 0;
  const color = nodeColor(node.data, sizeRatio);
  const isDir = node.data.type === "directory";
  const showLabel = w > 40 && h > 16;
  const showSize = w > 60 && h > 30;
  const displaySize = originalSize ?? node.value ?? 0;

  return (
    <g
      onClick={(e) => {
        e.stopPropagation();
        if (isDir) onClick(node);
      }}
      onContextMenu={(e) => {
        e.preventDefault();
        e.stopPropagation();
        onContextMenu(node, e);
      }}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      style={{ cursor: isDir ? "pointer" : "default" }}
    >
      <rect
        x={node.x0}
        y={node.y0}
        width={w}
        height={h}
        fill={collapsed ? "rgba(255,255,255,0.06)" : color}
        stroke={
          collapsed
            ? "#7ec8e3"
            : hovered
              ? "#fff"
              : "rgba(0,0,0,0.3)"
        }
        strokeWidth={collapsed ? 1 : hovered ? 2 : 0.5}
        strokeDasharray={collapsed ? "4 2" : undefined}
      />
      {showLabel && (
        <text
          x={node.x0 + 4}
          y={node.y0 + 14}
          className={collapsed ? "rect-label-collapsed" : "rect-label"}
          style={{ pointerEvents: "none" }}
        >
          {collapsed ? "\u25B6 " : ""}
          {truncate(node.data.name, Math.floor(w / 7) - (collapsed ? 2 : 0))}
        </text>
      )}
      {showSize && (
        <text
          x={node.x0 + 4}
          y={node.y0 + 28}
          className="rect-size"
          style={{ pointerEvents: "none" }}
        >
          {formatBytes(displaySize)}
        </text>
      )}
      {hovered && (
        <title>
          {node.data.name} — {formatBytes(displaySize)}
          {collapsed ? " (collapsed)" : ""}
        </title>
      )}
    </g>
  );
}

function truncate(s: string, maxLen: number): string {
  if (maxLen < 3) return "";
  return s.length <= maxLen ? s : s.slice(0, maxLen - 1) + "\u2026";
}
