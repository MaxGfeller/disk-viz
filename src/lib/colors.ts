// Hue by file type category
const EXT_HUES: Record<string, number> = {
  // Code — blue (210)
  ".ts": 210, ".tsx": 210, ".js": 210, ".jsx": 210, ".py": 210,
  ".rb": 210, ".go": 210, ".rs": 210, ".c": 210, ".cpp": 210,
  ".h": 210, ".java": 210, ".swift": 210, ".kt": 210, ".cs": 210,
  ".sh": 210, ".bash": 210, ".zsh": 210, ".fish": 210,
  ".html": 210, ".css": 210, ".scss": 210, ".less": 210,
  ".vue": 210, ".svelte": 210,
  // Data/config — green (140)
  ".json": 140, ".yaml": 140, ".yml": 140, ".toml": 140,
  ".xml": 140, ".csv": 140, ".env": 140, ".ini": 140,
  ".lock": 140, ".config": 140, ".sql": 140,
  // Media — orange (30)
  ".png": 30, ".jpg": 30, ".jpeg": 30, ".gif": 30, ".svg": 30,
  ".webp": 30, ".ico": 30, ".bmp": 30, ".tiff": 30,
  ".mp3": 30, ".wav": 30, ".flac": 30, ".aac": 30, ".ogg": 30,
  ".mp4": 30, ".mov": 30, ".avi": 30, ".mkv": 30, ".webm": 30,
  ".ttf": 30, ".otf": 30, ".woff": 30, ".woff2": 30,
  // Archives — red (0)
  ".zip": 0, ".tar": 0, ".gz": 0, ".bz2": 0, ".xz": 0,
  ".rar": 0, ".7z": 0, ".dmg": 0, ".iso": 0,
  ".whl": 0, ".jar": 0, ".war": 0,
  // Docs — purple (280)
  ".md": 280, ".txt": 280, ".pdf": 280, ".doc": 280,
  ".docx": 280, ".rst": 280, ".tex": 280, ".rtf": 280,
};

const DEFAULT_HUE = 0; // gray via low saturation
const DIR_HUE = 210;

export function getHue(node: { type: string; extension?: string }): number {
  if (node.type === "directory") return DIR_HUE;
  return EXT_HUES[node.extension ?? ""] ?? DEFAULT_HUE;
}

export function getSaturation(node: { type: string; extension?: string }): number {
  if (node.type === "directory") return 40;
  if (EXT_HUES[node.extension ?? ""] !== undefined) return 60;
  return 10; // gray for unknown
}

/**
 * Returns an HSL color string.
 * `sizeRatio` is 0..1 indicating how large this node is relative to its siblings.
 * Larger → darker (lower lightness) for heatmap effect.
 */
export function nodeColor(
  node: { type: string; extension?: string },
  sizeRatio: number
): string {
  const hue = getHue(node);
  const sat = getSaturation(node);
  // Lightness: 75 (smallest) → 35 (largest)
  const lightness = 75 - sizeRatio * 40;
  return `hsl(${hue}, ${sat}%, ${lightness}%)`;
}
