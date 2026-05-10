import Foundation

struct DiskVolumeInfo: Equatable, Sendable {
    var path: String
    var totalBytes: Int64
    var freeBytes: Int64

    var usedBytes: Int64 {
        max(0, totalBytes - freeBytes)
    }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }
}
