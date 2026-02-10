import { useState, useCallback } from "react";
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

  const scan = useCallback(async (path: string) => {
    setState({ data: null, loading: true, scanning: true, error: null, scanProgress: null });
    try {
      const res = await fetch(`/api/scan?path=${encodeURIComponent(path)}`);
      if (!res.ok) {
        // Validation errors come back as plain JSON
        const body = await res.json().catch(() => ({ error: res.statusText }));
        throw new Error(body.error || `HTTP ${res.status}`);
      }

      // Successful response is an SSE stream
      const reader = res.body!.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const parts = buffer.split("\n\n");
        buffer = parts.pop()!; // keep incomplete chunk

        for (const part of parts) {
          const dataLine = part
            .split("\n")
            .find((l) => l.startsWith("data: "));
          if (!dataLine) continue;
          const msg = JSON.parse(dataLine.slice(6));

          if (msg.type === "progress") {
            setState((prev) => ({
              ...prev,
              data: msg.tree,
              loading: false,
              scanProgress: msg.progress ?? prev.scanProgress,
            }));
          } else if (msg.type === "done") {
            setState({
              data: msg.tree,
              loading: false,
              scanning: false,
              error: null,
              scanProgress: null,
            });
          } else if (msg.type === "error") {
            throw new Error(msg.error);
          }
        }
      }

      // In case stream closed without a done message
      setState((prev) => ({ ...prev, loading: false, scanning: false }));
    } catch (err: any) {
      setState((prev) => ({
        data: prev.data, // keep any partial data
        loading: false,
        scanning: false,
        error: err.message,
      }));
    }
  }, []);

  const setData = useCallback((data: TreeNode | null) => {
    setState((prev) => ({ ...prev, data }));
  }, []);

  return { ...state, scan, setData };
}
