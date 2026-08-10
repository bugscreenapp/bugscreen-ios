@testable import BugScreenSDK
import XCTest

final class BundleAccessorTests: XCTestCase {
    /// The CocoaPods branch of `BugScreenResources` looks the resource bundle up by name,
    /// and a name that does not match the podspec fails *silently* — localized strings
    /// fall back to their keys and the wordmark does not render. It breaks on the
    /// CocoaPods channel only, which CI's SPM build cannot observe, so the two are pinned
    /// to each other here instead.
    func testResourceBundleNameMatchesPodspec() throws {
        let podspecURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BugScreenSDKReporterTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // sdks/ios
            .appendingPathComponent("BugScreenSDK.podspec")

        // Read, don't skip-if-missing: this test exists because a bundle-key mismatch
        // fails silently and on the CocoaPods channel only, which the SwiftPM test run
        // never exercises. A guard that skips when the podspec is absent would also
        // skip if it were renamed or deleted — the one change most likely to break the
        // pairing. Fail instead.
        let podspec = try String(contentsOf: podspecURL, encoding: .utf8)

        XCTAssertTrue(
            podspec.contains("'\(BugScreenResources.cocoaPodsBundleName)' =>"),
            """
            BugScreenSDK.podspec must declare a resource_bundles entry keyed \
            '\(BugScreenResources.cocoaPodsBundleName)' to match BugScreenResources.
            """
        )
    }

    func testStringsResolveFromTheBundleRatherThanFallingBackToTheKey() {
        // Proves the resources actually travelled with the target: a missing catalogue
        // returns the key itself, which reads as plausible English and hides the break.
        XCTAssertNotEqual(SDKStrings.errorTitle, "bugscreen_error_title")
        XCTAssertFalse(SDKStrings.errorTitle.isEmpty)
    }
}
