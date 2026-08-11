import Foundation

enum FileActionPolicy {
    static let mobileAssetRoot = "/System/Library/AssetsV2"

    static func manualDeletionRestriction(for path: String) -> String? {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardizedPath == mobileAssetRoot
                || standardizedPath.hasPrefix(mobileAssetRoot + "/")
        else {
            return nil
        }

        return "This is a macOS-managed asset. Keep it in the scan, but remove eligible content only through Cleanup Opportunities or the feature that installed it."
    }
}
