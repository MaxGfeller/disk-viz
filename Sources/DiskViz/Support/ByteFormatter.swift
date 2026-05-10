import Foundation

enum ByteFormatter {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    static func string(from bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }

        let value = Double(bytes)
        let index = min(
            Int(floor(log(value) / log(1024))),
            units.count - 1
        )
        let scaled = value / pow(1024, Double(index))
        let precision = index == 0 ? 0 : 1

        return String(format: "%.\(precision)f %@", scaled, units[index])
    }
}
