import { useState, type FormEvent } from "react";

interface Props {
  onScan: (path: string) => void;
  loading: boolean;
}

export function ScanForm({ onScan, loading }: Props) {
  const [path, setPath] = useState("/");

  const handleSubmit = (e: FormEvent) => {
    e.preventDefault();
    const trimmed = path.trim();
    if (trimmed) onScan(trimmed);
  };

  return (
    <form className="scan-form" onSubmit={handleSubmit}>
      <input
        type="text"
        value={path}
        onChange={(e) => setPath(e.target.value)}
        placeholder="Enter absolute path..."
        disabled={loading}
      />
      <button type="submit" disabled={loading || !path.trim()}>
        {loading ? "Scanning..." : "Scan"}
      </button>
    </form>
  );
}
