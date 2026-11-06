// Import only the no-op module, so the unqualified `BugScreenSDK` / `LogLevel` /
// `BugScreenUser` below resolve to the stub. Proves DX-009's "every no-op call is
// a safe no-op" criterion — the parity check proves the surface matches; this
// proves the bodies are inert.
import BugScreenSDKNoOp
import XCTest

@MainActor
final class BugScreenSDKNoOpTests: XCTestCase {
    func testIsConfiguredIsAlwaysFalse() {
        BugScreenSDK.showReportNotification()
        BugScreenSDK.showReportNotification(requestPermission: false)
        BugScreenSDK.hideReportNotification()
        XCTAssertFalse(BugScreenSDK.isConfigured)
        BugScreenSDK.configure(apiKey: "fb_test_key_1234", enableScreenshotDetection: true, debug: true)
        XCTAssertFalse(BugScreenSDK.isConfigured, "no-op configure() must not flip isConfigured")
    }

    func testEveryEntryPointIsInertAndDoesNotCrash() {
        BugScreenSDK.configure(apiKey: "fb_test_key_1234")
        BugScreenSDK.configure(apiKey: "fb_test_key_1234", captureSystemLogs: true)
        BugScreenSDK.configure(apiKey: "fb_test_key_1234", captureSystemLogs: true, startScreenRecordingImmediately: true,
                               screenRecordingOptions: .init(durationSeconds: 60, quality: .high))
        BugScreenSDK.startScreenRecording()
        XCTAssertEqual(BugScreenSDK.screenRecordingState, .disabled)
        BugScreenSDK.stopScreenRecording()
        BugScreenSDK.log("hello", level: .error)
        BugScreenSDK.setCustomData(["k": "v"])
        BugScreenSDK.setCustomData(key: "k", value: "v")
        BugScreenSDK.removeCustomData(key: "k")
        BugScreenSDK.addCustomData(["a": "b"])
        BugScreenSDK.clearCustomData()
        BugScreenSDK.setUser(id: "u", role: "admin", email: "e@example.com")
        BugScreenSDK.setUserProvider { BugScreenUser(id: "u") }
        BugScreenSDK.clearUser()
        BugScreenSDK.presentBugReport()
        BugScreenSDK.shutdown()

        // Nothing above changed any observable state — the stub holds no state.
        XCTAssertFalse(BugScreenSDK.isConfigured)
    }

    func testNotificationOptionRemainsInert() {
        BugScreenSDK.configure(apiKey: "fb_test_key_1234", enableScreenshotDetection: false, showReportNotification: true)
        BugScreenSDK.configure(apiKey: "fb_test_key_1234", showReportNotification: true, requestNotificationPermission: false)
        XCTAssertFalse(BugScreenSDK.isConfigured)
        BugScreenSDK.shutdown()
    }

    func testLogLevelValueSemanticsMatchRealSDK() {
        XCTAssertEqual(LogLevel.info.displayName, "INFO")
        XCTAssertEqual(LogLevel.error.displayName, "ERROR")
        XCTAssertLessThan(LogLevel.verbose, LogLevel.error)
        XCTAssertEqual(LogLevel.allCases.count, 5)
    }

    func testBugScreenUserPublicInit() {
        let user = BugScreenUser(id: "id", role: "role", email: "e@example.com")
        XCTAssertEqual(user.id, "id")
        XCTAssertEqual(user.role, "role")
        XCTAssertEqual(user.email, "e@example.com")

        let minimal = BugScreenUser(id: "only-id")
        XCTAssertNil(minimal.role)
        XCTAssertNil(minimal.email)
    }
}
