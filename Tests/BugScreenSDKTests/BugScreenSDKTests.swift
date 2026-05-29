@testable import BugScreenSDK
import XCTest

/// Tests for BugScreenSDK configuration and initialization.
@MainActor
final class BugScreenSDKTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestHelpers.resetSDK()
    }

    override func tearDown() {
        TestHelpers.resetSDK()
        super.tearDown()
    }

    // MARK: - Configuration Tests

    func testSDKInitiallyNotConfigured() {
        XCTAssertFalse(BugScreenSDK.isConfigured, "SDK should not be configured initially")
    }

    func testConfigureWithValidAPIKey() {
        BugScreenSDK.configure(apiKey: TestHelpers.validAPIKey)

        XCTAssertTrue(BugScreenSDK.isConfigured, "SDK should be configured after calling configure()")
    }

    func testConfigureWithEmptyAPIKey() {
        // Should not crash, just log warning
        BugScreenSDK.configure(apiKey: TestHelpers.emptyAPIKey)

        XCTAssertTrue(BugScreenSDK.isConfigured, "SDK should be configured even with empty API key")
    }

    // Note: invalid-prefix API keys now trap via `precondition` (programmer
    // error, matches Android's `require(apiKey.startsWith("fb_"))`). Not
    // unit-testable without a death-test runner; verified manually.

    func testConfigureWithShortAPIKey() {
        // Should not crash, just log warning
        BugScreenSDK.configure(apiKey: TestHelpers.shortAPIKey)

        XCTAssertTrue(BugScreenSDK.isConfigured, "SDK should be configured even with short API key")
    }

    func testSecondConfigureReinits() {
        BugScreenSDK.configure(apiKey: TestHelpers.validAPIKey)
        XCTAssertTrue(BugScreenSDK.isConfigured)
        XCTAssertEqual(BugScreenSDK.configuration?.apiKey, TestHelpers.validAPIKey)

        // Second configure tears down and replaces the previous configuration.
        BugScreenSDK.configure(apiKey: "fb_different_key_1234567890")

        XCTAssertTrue(BugScreenSDK.isConfigured)
        XCTAssertEqual(BugScreenSDK.configuration?.apiKey, "fb_different_key_1234567890")
    }

    func testConfigureWithCustomOptions() {
        BugScreenSDK.configure(
            apiKey: TestHelpers.validAPIKey,
            enableScreenshotDetection: false,
            debug: true
        )

        XCTAssertTrue(BugScreenSDK.isConfigured, "SDK should be configured with custom options")
    }

    // MARK: - Logging Tests

    func testLogBeforeConfiguration() {
        // Should not crash when logging before configuration
        BugScreenSDK.log("Test message", level: .info)

        // SDK should still be unconfigured
        XCTAssertFalse(BugScreenSDK.isConfigured)
    }

    func testLogAfterConfiguration() {
        BugScreenSDK.configure(apiKey: TestHelpers.validAPIKey)

        // Should not crash
        BugScreenSDK.log("Test message", level: .info)
        BugScreenSDK.log("Debug message", level: .debug)
        BugScreenSDK.log("Error message", level: .error)

        XCTAssertTrue(BugScreenSDK.isConfigured)
    }

    func testLogWithDifferentLevels() {
        BugScreenSDK.configure(apiKey: TestHelpers.validAPIKey)

        // Test all log levels
        BugScreenSDK.log("Verbose", level: .verbose)
        BugScreenSDK.log("Debug", level: .debug)
        BugScreenSDK.log("Info", level: .info)
        BugScreenSDK.log("Warn", level: .warning)
        BugScreenSDK.log("Error", level: .error)

        // Should not crash
        XCTAssertTrue(BugScreenSDK.isConfigured)
    }

    // MARK: - Shutdown Tests

    func testShutdown() {
        BugScreenSDK.configure(apiKey: TestHelpers.validAPIKey)
        XCTAssertTrue(BugScreenSDK.isConfigured)

        BugScreenSDK.shutdown()

        XCTAssertFalse(BugScreenSDK.isConfigured, "SDK should not be configured after shutdown")
    }

    func testShutdownWhenNotConfigured() {
        // Should not crash
        BugScreenSDK.shutdown()

        XCTAssertFalse(BugScreenSDK.isConfigured)
    }

    func testReconfigureAfterShutdown() {
        BugScreenSDK.configure(apiKey: TestHelpers.validAPIKey)
        BugScreenSDK.shutdown()

        BugScreenSDK.configure(apiKey: "fb_new_api_key_1234567890")

        XCTAssertTrue(BugScreenSDK.isConfigured, "SDK should allow reconfiguration after shutdown")
    }

    // MARK: - Custom Data Tests

    func testCustomDataDefaultsToEmpty() {
        XCTAssertTrue(BugScreenSDK.customData.isEmpty)
    }

    func testSetCustomDataStoresProvidedMap() {
        BugScreenSDK.setCustomData(["env": "staging", "buildType": "debug"])

        XCTAssertEqual(BugScreenSDK.customData, ["env": "staging", "buildType": "debug"])
    }

    func testSetCustomDataReplacesNotMerges() {
        BugScreenSDK.setCustomData(["a": "1", "b": "2"])
        BugScreenSDK.setCustomData(["c": "3"])

        XCTAssertEqual(BugScreenSDK.customData, ["c": "3"])
    }

    func testClearCustomDataEmptiesTheMap() {
        BugScreenSDK.setCustomData(["env": "staging"])
        BugScreenSDK.clearCustomData()

        XCTAssertTrue(BugScreenSDK.customData.isEmpty)
    }

    func testShutdownClearsCustomData() {
        BugScreenSDK.configure(apiKey: TestHelpers.validAPIKey)
        BugScreenSDK.setCustomData(["env": "staging"])

        BugScreenSDK.shutdown()

        XCTAssertTrue(BugScreenSDK.customData.isEmpty)
    }

    func testSetCustomDataSingleKeyAddsToExistingMap() {
        BugScreenSDK.setCustomData(["env": "staging"])
        BugScreenSDK.setCustomData(key: "userId", value: "abc-123")

        XCTAssertEqual(BugScreenSDK.customData, ["env": "staging", "userId": "abc-123"])
    }

    func testSetCustomDataSingleKeyOverwritesExistingValue() {
        BugScreenSDK.setCustomData(["env": "staging"])
        BugScreenSDK.setCustomData(key: "env", value: "production")

        XCTAssertEqual(BugScreenSDK.customData, ["env": "production"])
    }

    func testRemoveCustomDataRemovesPresentKey() {
        BugScreenSDK.setCustomData(["a": "1", "b": "2"])
        BugScreenSDK.removeCustomData(key: "a")

        XCTAssertEqual(BugScreenSDK.customData, ["b": "2"])
    }

    func testRemoveCustomDataIsNoOpForAbsentKey() {
        BugScreenSDK.setCustomData(["a": "1"])
        BugScreenSDK.removeCustomData(key: "missing")

        XCTAssertEqual(BugScreenSDK.customData, ["a": "1"])
    }

    func testAddCustomDataMergesIntoExistingMap() {
        BugScreenSDK.setCustomData(["env": "staging", "buildType": "debug"])
        BugScreenSDK.addCustomData(["plan": "pro", "env": "production"])

        XCTAssertEqual(
            BugScreenSDK.customData,
            ["env": "production", "buildType": "debug", "plan": "pro"]
        )
    }
}
