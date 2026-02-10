import { useCallback, useEffect } from "react";
import { ScanForm } from "./components/ScanForm";
import { Treemap } from "./components/Treemap";
import { Legend } from "./components/Legend";
import { useScan } from "./hooks/useScan";
import { removeNode } from "./lib/treeUtils";

const DEFAULT_SCAN_PATH = "/";

export function App() {
  const { data, loading, scanning, error, scanProgress, scan, setData } = useScan();

  // Auto-scan root on mount
  useEffect(() => {
    scan(DEFAULT_SCAN_PATH);
  }, [scan]);

  const handleDelete = useCallback(
    (path: string) => {
      if (!data) return;
      setData(removeNode(data, path));
    },
    [data, setData]
  );

  return (
    <div className="app">
      <header className="app-header">
        <h1>disk-viz</h1>
        <ScanForm onScan={scan} loading={loading || scanning} />
        <Legend />
      </header>
      <main className="app-main">
        {loading && !data && (
          <div className="status">
            <div className="spinner" />
            Scanning...
          </div>
        )}
        {error && <div className="status error">Error: {error}</div>}
        {data && (
          <Treemap
            data={data}
            onRescan={scan}
            onDelete={handleDelete}
            scanning={scanning}
            scanProgress={scanProgress}
          />
        )}
        {!data && !loading && !error && (
          <div className="status">Enter a directory path and click Scan</div>
        )}
      </main>
    </div>
  );
}
