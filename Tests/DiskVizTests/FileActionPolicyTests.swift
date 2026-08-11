@testable import DiskViz
import XCTest

final class FileActionPolicyTests: XCTestCase {
    func testAssetsV2AndItsContentsAreProtectedFromManualDeletion() {
        XCTAssertNotNil(
            FileActionPolicy.manualDeletionRestriction(
                for: "/System/Library/AssetsV2"
            )
        )
        XCTAssertNotNil(
            FileActionPolicy.manualDeletionRestriction(
                for: "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/runtime.dmg"
            )
        )
    }

    func testSimilarAndOrdinaryPathsRemainActionable() {
        XCTAssertNil(
            FileActionPolicy.manualDeletionRestriction(
                for: "/System/Library/AssetsV20/example"
            )
        )
        XCTAssertNil(
            FileActionPolicy.manualDeletionRestriction(
                for: "/Users/example/Downloads/old.dmg"
            )
        )
    }
}
