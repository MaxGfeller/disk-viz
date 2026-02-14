import type { TreeNode } from "../lib/types";

interface ScanProgressData {
  tree: TreeNode;
  progress: { dirsFound: number; dirsCompleted: number };
}

interface ScanDoneData {
  tree: TreeNode;
}

interface ScanErrorData {
  error: string;
}

interface ElectronAPI {
  startScan(path: string): Promise<{ ok?: boolean; error?: string }>;
  onScanProgress(callback: (data: ScanProgressData) => void): () => void;
  onScanDone(callback: (data: ScanDoneData) => void): () => void;
  onScanError(callback: (data: ScanErrorData) => void): () => void;
  deleteFile(path: string): Promise<{ ok?: boolean; error?: string }>;
  selectDirectory(): Promise<{ canceled?: boolean; path?: string }>;
  removeAllListeners(): void;
}

declare global {
  interface Window {
    api: ElectronAPI;
  }
}

export {};
