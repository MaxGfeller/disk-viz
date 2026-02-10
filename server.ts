import { scanDirectoryStreaming, type ScanProgress, type TreeNode } from "./scanner";
import { resolve } from "node:path";
import { stat, rm, unlink } from "node:fs/promises";
import homepage from "./index.html";

const PORT = 3000;
const MAX_DEPTH = 8;

// Track the last-scanned root so we can restrict deletions to it
let scanRoot: string | null = null;

// ---- Background scan state (persists across client connections) ----

interface ActiveScan {
  path: string;
  abort: AbortController;
  tree: TreeNode | null;
  progress: ScanProgress | null;
  done: boolean;
  error: string | null;
}

let activeScan: ActiveScan | null = null;

type ScanEvent =
  | { type: "progress"; tree: TreeNode; progress: ScanProgress }
  | { type: "done"; tree: TreeNode }
  | { type: "error"; error: string };

const sseListeners = new Set<(event: ScanEvent) => void>();

function broadcast(event: ScanEvent) {
  for (const fn of sseListeners) fn(event);
}

function startBackgroundScan(dirPath: string) {
  // Abort previous scan if still running
  if (activeScan && !activeScan.done) {
    activeScan.abort.abort();
  }

  const abort = new AbortController();
  const scan: ActiveScan = {
    path: dirPath,
    abort,
    tree: null,
    progress: null,
    done: false,
    error: null,
  };
  activeScan = scan;

  // Fire and forget — runs in the background, not tied to any request
  scanDirectoryStreaming(
    dirPath,
    MAX_DEPTH,
    (snapshot, progress) => {
      scan.tree = snapshot;
      scan.progress = progress;
      broadcast({ type: "progress", tree: snapshot, progress });
    },
    abort.signal,
  )
    .then((tree) => {
      scan.tree = tree;
      scan.done = true;
      scan.progress = null;
      broadcast({ type: "done", tree });
    })
    .catch((err) => {
      if (err.name !== "AbortError") {
        scan.error = err.message;
        scan.done = true;
        broadcast({ type: "error", error: err.message });
      }
    });
}

// ---- Server ----

Bun.serve({
  port: PORT,
  idleTimeout: 255,
  routes: {
    "/": homepage,

    "/api/scan": async (req) => {
      const url = new URL(req.url);
      const path = url.searchParams.get("path");

      if (!path) {
        return Response.json(
          { error: "Missing 'path' query parameter" },
          { status: 400 }
        );
      }

      const resolved = resolve(path);

      // Validate path exists and is a directory
      try {
        const stats = await stat(resolved);
        if (!stats.isDirectory()) {
          return Response.json(
            { error: "Path is not a directory" },
            { status: 400 }
          );
        }
      } catch (err: any) {
        if (err.code === "ENOENT") {
          return Response.json(
            { error: "Path not found" },
            { status: 404 }
          );
        }
        if (err.code === "EACCES") {
          return Response.json(
            { error: "Permission denied" },
            { status: 403 }
          );
        }
        return Response.json(
          { error: "Cannot access path" },
          { status: 400 }
        );
      }

      scanRoot = resolved;

      // Start a new scan only if needed:
      // - no scan exists
      // - different path requested
      // - previous scan for same path failed
      const needsNew =
        !activeScan ||
        activeScan.path !== resolved ||
        (activeScan.done && activeScan.error != null);

      if (needsNew) {
        startBackgroundScan(resolved);
      }

      // SSE: subscribe to the background scan
      const encoder = new TextEncoder();
      const stream = new ReadableStream({
        start(controller) {
          const send = (data: any) => {
            try {
              controller.enqueue(
                encoder.encode(`data: ${JSON.stringify(data)}\n\n`)
              );
            } catch {}
          };

          // Send current state immediately if available
          if (activeScan?.tree) {
            if (activeScan.done) {
              send({ type: "done", tree: activeScan.tree });
              try { controller.close(); } catch {}
              return;
            }
            send({
              type: "progress",
              tree: activeScan.tree,
              progress: activeScan.progress,
            });
          }

          // Subscribe to future updates from the background scan
          const listener = (event: ScanEvent) => {
            send(event);
            if (event.type === "done" || event.type === "error") {
              sseListeners.delete(listener);
              clearInterval(keepalive);
              try { controller.close(); } catch {}
            }
          };
          sseListeners.add(listener);

          // SSE keepalive every 30s to prevent connection timeout
          const keepalive = setInterval(() => {
            try {
              controller.enqueue(encoder.encode(": keepalive\n\n"));
            } catch {
              clearInterval(keepalive);
            }
          }, 30_000);

          // On client disconnect, just remove listener (scan continues in background)
          req.signal.addEventListener(
            "abort",
            () => {
              sseListeners.delete(listener);
              clearInterval(keepalive);
              try { controller.close(); } catch {}
            },
            { once: true }
          );
        },
      });

      return new Response(stream, {
        headers: {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
        },
      });
    },
  },

  async fetch(req) {
    const url = new URL(req.url);

    if (req.method === "DELETE" && url.pathname === "/api/delete") {
      let body: { path?: string };
      try {
        body = await req.json();
      } catch {
        return Response.json({ error: "Invalid JSON body" }, { status: 400 });
      }

      const targetPath = body.path;
      if (!targetPath || typeof targetPath !== "string") {
        return Response.json(
          { error: "Missing 'path' in request body" },
          { status: 400 }
        );
      }

      const resolved = resolve(targetPath);

      // Safety: reject if no scan has happened or path is outside scan root
      // if (!scanRoot || !resolved.startsWith(scanRoot + "/")) {
      //   return Response.json(
      //     { error: "Path is outside the scanned directory" },
      //     { status: 403 }
      //   );
      // }

      try {
        const stats = await stat(resolved);
        if (stats.isDirectory()) {
          await rm(resolved, { recursive: true });
        } else {
          await unlink(resolved);
        }
        return Response.json({ ok: true });
      } catch (err: any) {
        if (err.code === "ENOENT") {
          return Response.json({ error: "Path not found" }, { status: 404 });
        }
        if (err.code === "EACCES") {
          return Response.json(
            { error: "Permission denied" },
            { status: 403 }
          );
        }
        return Response.json(
          { error: err.message || "Delete failed" },
          { status: 500 }
        );
      }
    }

    return new Response("Not found", { status: 404 });
  },
});

console.log(`disk-viz running at http://localhost:${PORT}`);
