# disk-viz

An interactive, web-based disk space visualization tool. Scan any directory and explore its contents as a treemap, drill down into subdirectories, and delete files directly from the interface.

## Features

- **Streaming scan** — filesystem is indexed progressively with real-time progress updates via Server-Sent Events
- **Interactive treemap** — click to drill down into directories, right-click for options, Escape to go back up
- **Collapse/expand** — hide subdirectories to focus on what matters; state persists across sessions via localStorage
- **Delete files** — remove files and directories directly from the context menu
- **Breadcrumb navigation** — always know where you are and jump back to any parent

## Tech Stack

- **Runtime:** [Bun](https://bun.sh)
- **Backend:** TypeScript HTTP server with SSE streaming
- **Frontend:** React 19, D3-hierarchy (squarify treemap layout)

## Getting Started

```bash
bun install
bun --hot server.ts
```

Then open http://localhost:3000. Enter a directory path to scan (defaults to `/`).

## How It Works

1. The frontend sends a GET request to `/api/scan?path=<dir>`, which opens an SSE stream.
2. The backend recursively walks the filesystem (up to depth 8, max 64 concurrent file operations) and streams partial tree updates every 500ms.
3. The frontend renders the tree as a D3 squarify treemap, pruned to 500 leaf nodes for performance.
4. Small items within a directory are aggregated into a single "(N smaller items)" node to keep the visualization readable.

## Project Structure

```
server.ts          — Bun HTTP server (/api/scan, /api/delete, static files)
scanner.ts         — Filesystem traversal with concurrency control and streaming
index.html         — HTML entry point
src/
  App.tsx          — Root React component
  components/
    Treemap.tsx    — Interactive SVG treemap with zoom/drill-down
    ScanForm.tsx   — Directory path input
    TreemapRect.tsx, Breadcrumb.tsx, ContextMenu.tsx, Legend.tsx
  hooks/
    useScan.ts     — SSE client for streaming scan results
    useTreemapLayout.ts — D3 hierarchy + treemap layout computation
  lib/
    types.ts       — TreeNode interface
    format.ts      — Byte formatting (B, KB, MB, GB, TB)
    colors.ts      — Color utilities
    treeUtils.ts   — Tree manipulation helpers
  styles.css       — Dark-themed UI styles
```
