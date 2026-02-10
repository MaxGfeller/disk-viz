import type { TreeNode } from "../lib/types";

interface Props {
  path: TreeNode[];
  onNavigate: (index: number) => void;
}

export function Breadcrumb({ path, onNavigate }: Props) {
  if (path.length === 0) return null;

  return (
    <nav className="breadcrumb">
      {path.map((node, i) => (
        <span key={node.path}>
          {i > 0 && <span className="breadcrumb-sep">&rsaquo;</span>}
          {i < path.length - 1 ? (
            <button
              className="breadcrumb-btn"
              onClick={() => onNavigate(i)}
            >
              {node.name}
            </button>
          ) : (
            <span className="breadcrumb-current">{node.name}</span>
          )}
        </span>
      ))}
    </nav>
  );
}
