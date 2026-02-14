import { contextBridge, ipcRenderer } from "electron";

contextBridge.exposeInMainWorld("api", {
  startScan(path: string) {
    return ipcRenderer.invoke("scan:start", path);
  },

  onScanProgress(callback: (data: { tree: any; progress: any }) => void) {
    const handler = (_event: Electron.IpcRendererEvent, data: any) => callback(data);
    ipcRenderer.on("scan:progress", handler);
    return () => ipcRenderer.removeListener("scan:progress", handler);
  },

  onScanDone(callback: (data: { tree: any }) => void) {
    const handler = (_event: Electron.IpcRendererEvent, data: any) => callback(data);
    ipcRenderer.on("scan:done", handler);
    return () => ipcRenderer.removeListener("scan:done", handler);
  },

  onScanError(callback: (data: { error: string }) => void) {
    const handler = (_event: Electron.IpcRendererEvent, data: any) => callback(data);
    ipcRenderer.on("scan:error", handler);
    return () => ipcRenderer.removeListener("scan:error", handler);
  },

  deleteFile(path: string): Promise<{ ok?: boolean; error?: string }> {
    return ipcRenderer.invoke("delete:file", path);
  },

  selectDirectory(): Promise<{ canceled?: boolean; path?: string }> {
    return ipcRenderer.invoke("dialog:openDirectory");
  },

  removeAllListeners() {
    ipcRenderer.removeAllListeners("scan:progress");
    ipcRenderer.removeAllListeners("scan:done");
    ipcRenderer.removeAllListeners("scan:error");
  },
});
