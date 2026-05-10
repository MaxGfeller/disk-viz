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
const MAX_SHALLOW_CHILDREN = 500;
const ENTRY_WORKERS = 8;
const SNAPSHOT_INTERVAL_MS = 1_000;

// Concurrency control to avoid EMFILE (too many open files) and too many du(1) processes.
function createLimiter(limit: number) {
  let active = 0;
  const queue: Array<() => void> = [];

  const acquire = (): Promise<void> => {
    if (active < limit) {
      active++;
      return Promise.resolve();
    }
    return new Promise((resolve) => queue.push(resolve));
  };

  const release = () => {
    const next = queue.shift();
    if (next) {
      next();
    } else {
      active--;
    }
  };

  return async function withLimit<T>(fn: () => Promise<T>): Promise<T> {
    await acquire();
    try {
      return await fn();
    } finally {
      release();
    }
  };
}

const withFsSlot = createLimiter(64);
const withDuSlot = createLimiter(4);

/** Non-streaming scan — used for drill-down rescans of individual directories. */
export async function scanDirectory(
  dirPath: string,
  maxDepth = DEFAULT_MAX_DEPTH,
  depth = 0
): Promise<TreeNode> {
  const node = createDirectoryNode(dirPath);
  const progress: ScanProgress = { dirsFound: 1, dirsCompleted: 0 };
  await fillNode(node, maxDepth, depth, () => {}, progress);
  return snapshot(node);
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
  const root = createDirectoryNode(dirPath);

  const progress: ScanProgress = { dirsFound: 1, dirsCompleted: 0 };
  let dirty = false;
  const markDirty = () => { dirty = true; };

  const timer = setInterval(() => {
    if (signal?.aborted) return;
    if (dirty) {
      dirty = false;
      onProgress(snapshot(root), { ...progress });
    }
  }, SNAPSHOT_INTERVAL_MS);

  try {
    await fillNode(root, maxDepth, 0, markDirty, progress, signal);
    if (signal?.aborted) throw new DOMException("Scan aborted", "AbortError");
    const final = snapshot(root);
    return final;
  } finally {
    clearInterval(timer);
  }
}

/** Clone tree and recalculate sizes — safe to send over the wire. */
function snapshot(root: TreeNode): TreeNode {
  const clone = JSON.parse(JSON.stringify(root)) as TreeNode;
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
    entries = await withFsSlot(() => readdir(node.path, { withFileTypes: true }));
  } catch {
    progress.dirsCompleted++;
    markDirty();
    return;
  }

  if (signal?.aborted) return;

  const children = new ChildAccumulator(node.path, childLimitForDepth(depth));
  node.children = [];

  // Count subdirectories discovered
  for (const entry of entries) {
    if (!entry.isSymbolicLink() && entry.isDirectory()) {
      progress.dirsFound++;
    }
  }

  await processEntries(entries, async (entry) => {
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
      try {
        await fillNode(child, maxDepth, depth + 1, markDirty, progress, signal);
        if (signal?.aborted) return;
        children.add(child);
        syncNodeChildren(node, children);
        markDirty();
      } catch {}
    } else if (entry.isFile()) {
      if (signal?.aborted) return;
      try {
        const stats = await withFsSlot(() => stat(fullPath));
        children.add({
          name: entry.name,
          path: fullPath,
          size: stats.size,
          type: "file",
          extension: extname(entry.name).toLowerCase() || undefined,
        });
        syncNodeChildren(node, children);
        markDirty();
      } catch {}
    }
  }, signal);

  syncNodeChildren(node, children);
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

/**
 * Fast directory size using native `du`.
 * Much faster than manual recursive stat() calls.
 */
async function fastDirSize(dirPath: string, signal?: AbortSignal): Promise<number> {
  if (signal?.aborted) return 0;
  try {
    const text = await withDuSlot(() => new Promise<string>((resolve, reject) => {
      let child: ReturnType<typeof execFile>;
      const onAbort = () => { child.kill(); reject(new DOMException("Aborted", "AbortError")); };
      child = execFile("du", ["-sk", dirPath], { timeout: 300_000 }, (err, stdout) => {
        signal?.removeEventListener("abort", onAbort);
        if (err) reject(err);
        else resolve(stdout);
      });
      if (signal?.aborted) {
        onAbort();
        return;
      }
      signal?.addEventListener("abort", onAbort, { once: true });
    }));
    if (signal?.aborted) return 0;
    const kb = parseInt(text.trim().split(/\s+/)[0], 10);
    return isNaN(kb) ? 0 : kb * 1024;
  } catch {
    return 0;
  }
}

function createDirectoryNode(dirPath: string): TreeNode {
  return {
    name: basename(dirPath) || dirPath,
    path: dirPath,
    size: 0,
    type: "directory",
  };
}

function childLimitForDepth(depth: number): number {
  return depth >= CHILD_LIMIT_DEPTH ? MAX_CHILDREN : MAX_SHALLOW_CHILDREN;
}

function compareBySizeDesc(a: TreeNode, b: TreeNode): number {
  return b.size - a.size || a.name.localeCompare(b.name);
}

class ChildAccumulator {
  private retained: TreeNode[] = [];
  private droppedCount = 0;
  private droppedSize = 0;

  constructor(private readonly parentPath: string, private readonly limit: number) {}

  add(child: TreeNode): void {
    this.retained.push(child);
    this.retained.sort(compareBySizeDesc);

    while (this.retained.length > this.limit) {
      const dropped = this.retained.pop();
      if (!dropped) break;
      this.droppedCount++;
      this.droppedSize += dropped.size;
    }
  }

  materialize(): TreeNode[] {
    const children = [...this.retained].sort(compareBySizeDesc);
    if (this.droppedCount > 0 && this.droppedSize > 0) {
      children.push({
        name: `(${this.droppedCount} smaller items)`,
        path: this.parentPath + "/__other__",
        size: this.droppedSize,
        type: "file",
      });
    }
    return children;
  }

  size(): number {
    return this.retained.reduce((sum, child) => sum + child.size, 0) + this.droppedSize;
  }
}

function syncNodeChildren(node: TreeNode, children: ChildAccumulator): void {
  node.children = children.materialize();
  node.size = children.size();
}

async function processEntries<T>(
  entries: T[],
  worker: (entry: T) => Promise<void>,
  signal?: AbortSignal,
): Promise<void> {
  let nextIndex = 0;
  const workerCount = Math.min(ENTRY_WORKERS, entries.length);

  await Promise.all(Array.from({ length: workerCount }, async () => {
    while (!signal?.aborted) {
      const index = nextIndex++;
      if (index >= entries.length) return;
      await worker(entries[index]);
    }
  }));
}
