import { useState, useEffect, useLayoutEffect, useRef } from "react";
import type { LayoutNode } from "../hooks/useTreemapLayout";
import { formatBytes } from "../lib/format";

interface Props {
  node: LayoutNode;
  x: number;
  y: number;
  onDelete: () => void;
  onClose: () => void;
  isCollapsed: boolean;
  onToggleCollapse: () => void;
}

export function ContextMenu({
  node,
  x,
  y,
  onDelete,
  onClose,
  isCollapsed,
  onToggleCollapse,
}: Props) {
  const [confirming, setConfirming] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState({ left: x, top: y });

  // Clamp to viewport after first render
  useLayoutEffect(() => {
    const el = menuRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    const pad = 8;
    let left = x;
    let top = y;
    if (left + rect.width > window.innerWidth - pad) {
      left = window.innerWidth - rect.width - pad;
    }
    if (top + rect.height > window.innerHeight - pad) {
      top = window.innerHeight - rect.height - pad;
    }
    if (left < pad) left = pad;
    if (top < pad) top = pad;
    setPos({ left, top });
  }, [x, y]);

  // Close on click-outside
  useEffect(() => {
    const handleClick = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        onClose();
      }
    };
    document.addEventListener("mousedown", handleClick);
    return () => document.removeEventListener("mousedown", handleClick);
  }, [onClose]);

  // Close on Escape
  useEffect(() => {
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", handleKey);
    return () => window.removeEventListener("keydown", handleKey);
  }, [onClose]);

  // Close on scroll
  useEffect(() => {
    const handleScroll = () => onClose();
    window.addEventListener("scroll", handleScroll, true);
    return () => window.removeEventListener("scroll", handleScroll, true);
  }, [onClose]);

  const isDir = node.data.type === "directory";

  return (
    <div
      ref={menuRef}
      className="context-menu"
      style={{ left: pos.left, top: pos.top }}
    >
      <div className="context-menu-header">
        <span className="context-menu-name">{node.data.name}</span>
        <span className="context-menu-size">
          {formatBytes(node.value ?? 0)} {isDir ? "(dir)" : ""}
        </span>
      </div>
      <div className="context-menu-divider" />
      {isDir && (
        <button
          className="context-menu-item"
          onClick={onToggleCollapse}
        >
          {isCollapsed ? "Expand" : "Collapse"}
        </button>
      )}
      {!confirming ? (
        <button
          className="context-menu-item context-menu-delete"
          onClick={() => setConfirming(true)}
        >
          Delete
        </button>
      ) : (
        <button
          className="context-menu-item context-menu-confirm"
          onClick={onDelete}
        >
          Confirm delete?
        </button>
      )}
    </div>
  );
}
