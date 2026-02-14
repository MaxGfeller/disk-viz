import { readdir, stat } from "node:fs/promises";
import { join, extname, basename } from "node:path";
import { execFile } from "node:child_process";

export interface TreeNode {
  name: string;
  path: string;
  size: number;
  type: "file" | "directory";
  extension?: string;
  children?: TreeNode[];
  truncated?: boolean;
}

const DEFAULT_MAX_DEPTH = 8;
const CHILD_LIMIT_DEPTH = 2;
const MAX_CHILDREN = 30;

// Concurrency control to avoid EMFILE (too many open files)
const MAX_CONCURRENT = 64;
let active = 0;
const queue: Array<() => void> = [];

function acquireSlot(): Promise<void> {
  if (active < MAX_CONCURRENT) {
    active++;
    return Promise.resolve();
  }
  return new Promise((resolve) => queue.push(resolve));
}

function releaseSlot() {
  const next = queue.shift();
  if (next) {
    next();
  } else {
    active--;
  }
}

async function withSlot<T>(fn: () => Promise<T>): Promise<T> {
  await acquireSlot();
  try {
    return await fn();
  } finally {
    releaseSlot();
  }
}

/** Non-streaming scan — used for drill-down rescans of individual directories. */
export async function scanDirectory(
  dirPath: string,
  maxDepth = DEFAULT_MAX_DEPTH,
  depth = 0
): Promise<TreeNode> {
  const name = basename(dirPath) || dirPath;
  const node: TreeNode = {
    name,
    path: dirPath,
    size: 0,
    type: "directory",
  };

  if (depth >= maxDepth) {
    node.truncated = true;
    node.size = await fastDirSize(dirPath);
    return node;
  }

  let entries;
  try {
    entries = await withSlot(() => readdir(dirPath, { withFileTypes: true }));
  } catch {
    node.size = 0;
    return node;
  }

  const childPromises: Promise<TreeNode | null>[] = entries.map(
    async (entry) => {
      if (entry.isSymbolicLink()) return null;

      const fullPath = join(dirPath, entry.name);

      if (entry.isDirectory()) {
        try {
          return await scanDirectory(fullPath, maxDepth, depth + 1);
        } catch {
          return null;
        }
      }

      if (entry.isFile()) {
        try {
          const stats = await withSlot(() => stat(fullPath));
          return {
            name: entry.name,
            path: fullPath,
            size: stats.size,
            type: "file" as const,
            extension: extname(entry.name).toLowerCase() || undefined,
          };
        } catch {
          return null;
        }
      }

      return null;
    }
  );

  let children = (await Promise.all(childPromises)).filter(
    (c): c is TreeNode => c !== null
  );

  children.sort((a, b) => b.size - a.size);

  if (depth >= CHILD_LIMIT_DEPTH && children.length > MAX_CHILDREN) {
    const kept = children.slice(0, MAX_CHILDREN);
    const droppedSize = children
      .slice(MAX_CHILDREN)
      .reduce((s, c) => s + c.size, 0);
    if (droppedSize > 0) {
      kept.push({
        name: `(${children.length - MAX_CHILDREN} smaller items)`,
        path: dirPath + "/__other__",
        size: droppedSize,
        type: "file",
      });
    }
    children = kept;
  }

  node.children = children;
  node.size = children.reduce((sum, c) => sum + c.size, 0);

  return node;
}

export interface ScanProgress {
  dirsFound: number;
  dirsCompleted: number;
}

/**
 * Streaming scan — builds tree in-place and calls onProgress periodically
 * so the client can render partial results.
 */
export async function scanDirectoryStreaming(
  dirPath: string,
  maxDepth: number,
  onProgress: (tree: TreeNode, progress: ScanProgress) => void,
  signal?: AbortSignal,
): Promise<TreeNode> {
  const root: TreeNode = {
    name: basename(dirPath) || dirPath,
    path: dirPath,
    size: 0,
    type: "directory",
  };

  const progress: ScanProgress = { dirsFound: 1, dirsCompleted: 0 };
  let dirty = false;
  const markDirty = () => { dirty = true; };

  const timer = setInterval(() => {
    if (signal?.aborted) return;
    if (dirty) {
      dirty = false;
      onProgress(snapshot(root), { ...progress });
    }
  }, 500);

  try {
    await fillNode(root, maxDepth, 0, markDirty, progress, signal);
    if (signal?.aborted) throw new DOMException("Scan aborted", "AbortError");
    const final = snapshot(root);
    return final;
  } finally {
    clearInterval(timer);
  }
}

/** Clone tree, recalculate sizes, apply child limits — safe to send over the wire. */
function snapshot(root: TreeNode): TreeNode {
  const clone = JSON.parse(JSON.stringify(root)) as TreeNode;
  recalcSizes(clone);
  applyChildLimits(clone, 0);
  recalcSizes(clone);
  return clone;
}

/** Fill a mutable TreeNode in-place. Used by streaming scan. */
async function fillNode(
  node: TreeNode,
  maxDepth: number,
  depth: number,
  markDirty: () => void,
  progress: ScanProgress,
  signal?: AbortSignal,
): Promise<void> {
  if (signal?.aborted) return;

  if (depth >= maxDepth) {
    node.truncated = true;
    node.size = await fastDirSize(node.path, signal);
    progress.dirsCompleted++;
    markDirty();
    return;
  }

  let entries;
  try {
    entries = await withSlot(() => readdir(node.path, { withFileTypes: true }));
  } catch {
    progress.dirsCompleted++;
    return;
  }

  if (signal?.aborted) return;

  node.children = [];

  // Count subdirectories discovered
  for (const entry of entries) {
    if (!entry.isSymbolicLink() && entry.isDirectory()) {
      progress.dirsFound++;
    }
  }

  const promises = entries.map(async (entry) => {
    if (signal?.aborted) return;
    if (entry.isSymbolicLink()) return;
    const fullPath = join(node.path, entry.name);

    if (entry.isDirectory()) {
      const child: TreeNode = {
        name: entry.name,
        path: fullPath,
        size: 0,
        type: "directory",
      };
      node.children!.push(child);
      markDirty();
      try {
        await fillNode(child, maxDepth, depth + 1, markDirty, progress, signal);
      } catch {}
    } else if (entry.isFile()) {
      if (signal?.aborted) return;
      try {
        const stats = await withSlot(() => stat(fullPath));
        node.children!.push({
          name: entry.name,
          path: fullPath,
          size: stats.size,
          type: "file",
          extension: extname(entry.name).toLowerCase() || undefined,
        });
        markDirty();
      } catch {}
    }
  });

  await Promise.all(promises);
  progress.dirsCompleted++;
  markDirty();
}

/** Recalculate sizes bottom-up and sort children by size desc. */
function recalcSizes(node: TreeNode): void {
  if (!node.children || node.children.length === 0) return;
  for (const child of node.children) {
    recalcSizes(child);
  }
  node.children.sort((a, b) => b.size - a.size);
  node.size = node.children.reduce((s, c) => s + c.size, 0);
}

/** Apply MAX_CHILDREN limit at depth >= CHILD_LIMIT_DEPTH. */
function applyChildLimits(node: TreeNode, depth: number): void {
  if (!node.children || node.children.length === 0) return;
  for (const child of node.children) {
    applyChildLimits(child, depth + 1);
  }
  if (depth >= CHILD_LIMIT_DEPTH && node.children.length > MAX_CHILDREN) {
    const kept = node.children.slice(0, MAX_CHILDREN);
    const droppedSize = node.children
      .slice(MAX_CHILDREN)
      .reduce((s, c) => s + c.size, 0);
    if (droppedSize > 0) {
      kept.push({
        name: `(${node.children.length - MAX_CHILDREN} smaller items)`,
        path: node.path + "/__other__",
        size: droppedSize,
        type: "file",
      });
    }
    node.children = kept;
  }
}

/**
 * Fast directory size using native `du`.
 * Much faster than manual recursive stat() calls.
 */
async function fastDirSize(dirPath: string, signal?: AbortSignal): Promise<number> {
  if (signal?.aborted) return 0;
  try {
    const text = await new Promise<string>((resolve, reject) => {
      const child = execFile("du", ["-sk", dirPath], { timeout: 300_000 }, (err, stdout) => {
        if (err) reject(err);
        else resolve(stdout);
      });
      const onAbort = () => { child.kill(); reject(new DOMException("Aborted", "AbortError")); };
      signal?.addEventListener("abort", onAbort, { once: true });
    });
    if (signal?.aborted) return 0;
    const kb = parseInt(text.split("\t")[0], 10);
    return isNaN(kb) ? 0 : kb * 1024;
  } catch {
    return 0;
  }
}
