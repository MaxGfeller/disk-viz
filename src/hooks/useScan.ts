import { useState, useCallback, useEffect, useRef } from "react";
import type { TreeNode } from "../lib/types";

interface ScanState {
  data: TreeNode | null;
  loading: boolean;
  scanning: boolean;
  error: string | null;
  scanProgress: { dirsFound: number; dirsCompleted: number } | null;
}

export function useScan() {
  const [state, setState] = useState<ScanState>({
    data: null,
    loading: false,
    scanning: false,
    error: null,
    scanProgress: null,
  });

  const cleanupRef = useRef<(() => void) | null>(null);

  const setupListeners = useCallback(() => {
    // Clean up previous listeners
    cleanupRef.current?.();

    const removeProgress = window.api.onScanProgress(({ tree, progress }) => {
      setState((prev) => ({
        ...prev,
        data: tree,
        loading: false,
        scanProgress: progress ?? prev.scanProgress,
      }));
    });

    const removeDone = window.api.onScanDone(({ tree }) => {
      setState({
        data: tree,
        loading: false,
        scanning: false,
        error: null,
        scanProgress: null,
      });
    });

    const removeError = window.api.onScanError(({ error }) => {
      setState((prev) => ({
        data: prev.data,
        loading: false,
        scanning: false,
        error,
        scanProgress: null,
      }));
    });

    cleanupRef.current = () => {
      removeProgress();
      removeDone();
      removeError();
    };
  }, []);

  // Clean up listeners on unmount
  useEffect(() => {
    return () => {
      cleanupRef.current?.();
      window.api.removeAllListeners();
    };
  }, []);

  const scan = useCallback(async (path: string) => {
    setState({ data: null, loading: true, scanning: true, error: null, scanProgress: null });

    // Set up fresh listeners for this scan
    setupListeners();

    const result = await window.api.startScan(path);
    if (result.error) {
      setState((prev) => ({
        data: prev.data,
        loading: false,
        scanning: false,
        error: result.error!,
        scanProgress: null,
      }));
    }
  }, [setupListeners]);

  const setData = useCallback((data: TreeNode | null) => {
    setState((prev) => ({ ...prev, data }));
  }, []);

  return { ...state, scan, setData };
}
