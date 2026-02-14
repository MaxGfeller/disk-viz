import { app, BrowserWindow, ipcMain, dialog } from "electron";
import { resolve, join } from "node:path";
import { stat, rm, unlink } from "node:fs/promises";
import { scanDirectoryStreaming, type ScanProgress, type TreeNode } from "../scanner";

const MAX_DEPTH = 8;
const isDev = !app.isPackaged;

let mainWindow: BrowserWindow | null = null;

interface ActiveScan {
  path: string;
  abort: AbortController;
  tree: TreeNode | null;
  progress: ScanProgress | null;
  done: boolean;
  error: string | null;
}

let activeScan: ActiveScan | null = null;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    backgroundColor: "#1a1a2e",
    webPreferences: {
      preload: join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  if (isDev) {
    mainWindow.loadURL("http://localhost:5173");
  } else {
    mainWindow.loadFile(join(__dirname, "../../renderer/index.html"));
  }

  mainWindow.on("closed", () => {
    mainWindow = null;
  });
}

function startBackgroundScan(dirPath: string) {
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

  scanDirectoryStreaming(
    dirPath,
    MAX_DEPTH,
    (snapshot, progress) => {
      scan.tree = snapshot;
      scan.progress = progress;
      mainWindow?.webContents.send("scan:progress", { tree: snapshot, progress });
    },
    abort.signal,
  )
    .then((tree) => {
      scan.tree = tree;
      scan.done = true;
      scan.progress = null;
      mainWindow?.webContents.send("scan:done", { tree });
    })
    .catch((err) => {
      if (err.name !== "AbortError") {
        scan.error = err.message;
        scan.done = true;
        mainWindow?.webContents.send("scan:error", { error: err.message });
      }
    });
}

// IPC handlers
ipcMain.handle("scan:start", async (_event, path: string) => {
  if (!path) {
    return { error: "Missing path" };
  }

  const resolved = resolve(path);

  try {
    const stats = await stat(resolved);
    if (!stats.isDirectory()) {
      return { error: "Path is not a directory" };
    }
  } catch (err: any) {
    if (err.code === "ENOENT") return { error: "Path not found" };
    if (err.code === "EACCES") return { error: "Permission denied" };
    return { error: "Cannot access path" };
  }

  const needsNew =
    !activeScan ||
    activeScan.path !== resolved ||
    (activeScan.done && activeScan.error != null);

  if (needsNew) {
    startBackgroundScan(resolved);
  } else if (activeScan?.tree) {
    // Send current state immediately
    if (activeScan.done) {
      mainWindow?.webContents.send("scan:done", { tree: activeScan.tree });
    } else {
      mainWindow?.webContents.send("scan:progress", {
        tree: activeScan.tree,
        progress: activeScan.progress,
      });
    }
  }

  return { ok: true };
});

ipcMain.handle("delete:file", async (_event, path: string) => {
  if (!path || typeof path !== "string") {
    return { error: "Missing path" };
  }

  const resolved = resolve(path);

  try {
    const stats = await stat(resolved);
    if (stats.isDirectory()) {
      await rm(resolved, { recursive: true });
    } else {
      await unlink(resolved);
    }
    return { ok: true };
  } catch (err: any) {
    if (err.code === "ENOENT") return { error: "Path not found" };
    if (err.code === "EACCES") return { error: "Permission denied" };
    return { error: err.message || "Delete failed" };
  }
});

ipcMain.handle("dialog:openDirectory", async () => {
  if (!mainWindow) return { canceled: true };
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ["openDirectory"],
  });
  if (result.canceled || result.filePaths.length === 0) {
    return { canceled: true };
  }
  return { path: result.filePaths[0] };
});

app.whenReady().then(createWindow);

app.on("window-all-closed", () => {
  if (activeScan && !activeScan.done) {
    activeScan.abort.abort();
  }
  app.quit();
});

app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    createWindow();
  }
});
