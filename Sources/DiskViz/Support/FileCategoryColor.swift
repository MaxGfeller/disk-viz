import SwiftUI

enum FileCategoryColor {
    private static let extensionHues: [String: Double] = [
        ".ts": 210, ".tsx": 210, ".js": 210, ".jsx": 210, ".py": 210,
        ".rb": 210, ".go": 210, ".rs": 210, ".c": 210, ".cpp": 210,
        ".h": 210, ".java": 210, ".swift": 210, ".kt": 210, ".cs": 210,
        ".sh": 210, ".bash": 210, ".zsh": 210, ".fish": 210,
        ".html": 210, ".css": 210, ".scss": 210, ".less": 210,
        ".vue": 210, ".svelte": 210,

        ".json": 140, ".yaml": 140, ".yml": 140, ".toml": 140,
        ".xml": 140, ".csv": 140, ".env": 140, ".ini": 140,
        ".lock": 140, ".config": 140, ".sql": 140,

        ".png": 30, ".jpg": 30, ".jpeg": 30, ".gif": 30, ".svg": 30,
        ".webp": 30, ".ico": 30, ".bmp": 30, ".tiff": 30,
        ".mp3": 30, ".wav": 30, ".flac": 30, ".aac": 30, ".ogg": 30,
        ".mp4": 30, ".mov": 30, ".avi": 30, ".mkv": 30, ".webm": 30,
        ".ttf": 30, ".otf": 30, ".woff": 30, ".woff2": 30,

        ".zip": 0, ".tar": 0, ".gz": 0, ".bz2": 0, ".xz": 0,
        ".rar": 0, ".7z": 0, ".dmg": 0, ".iso": 0,
        ".whl": 0, ".jar": 0, ".war": 0,

        ".md": 280, ".txt": 280, ".pdf": 280, ".doc": 280,
        ".docx": 280, ".rst": 280, ".tex": 280, ".rtf": 280
    ]

    static let legend: [(label: String, hue: Double, saturation: Double)] = [
        ("Code", 210, 0.60),
        ("Data/Config", 140, 0.60),
        ("Media", 30, 0.60),
        ("Archives", 0, 0.60),
        ("Docs", 280, 0.60),
        ("Other", 0, 0.10)
    ]

    static func color(for node: DiskNode, sizeRatio: Double) -> Color {
        let hue = hue(for: node) / 360
        let saturation = saturation(for: node)
        let lightness = 0.75 - max(0, min(sizeRatio, 1)) * 0.40
        return Color(hue: hue, saturation: saturation, brightness: lightness)
    }

    static func legendColor(hue: Double, saturation: Double) -> Color {
        Color(hue: hue / 360, saturation: saturation, brightness: 0.55)
    }

    private static func hue(for node: DiskNode) -> Double {
        if node.isDirectory { return 210 }
        return extensionHues[node.fileExtension ?? ""] ?? 0
    }

    private static func saturation(for node: DiskNode) -> Double {
        if node.isDirectory { return 0.40 }
        if extensionHues[node.fileExtension ?? ""] != nil { return 0.60 }
        return 0.10
    }
}
