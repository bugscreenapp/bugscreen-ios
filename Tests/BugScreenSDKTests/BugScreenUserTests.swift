@testable import BugScreenSDK
import XCTest

/// Tests for the account identity API (setUser / setUserProvider / clearUser)
/// and its reserved-key merge into report metadata.
@MainActor
final class BugScreenUserTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestHelpers.resetSDK()
    }

    override func tearDown() {
        TestHelpers.resetSDK()
        super.tearDown()
    }

    func testSetUserWritesReservedAccountKeys() {
        BugScreenSDK.setUser(id: "pro-user-8823", role: "admin", email: "qa@acme.dev")

        XCTAssertEqual(
            BugScreenSDK.resolveReportCustomData(),
            [
                "bugscreen.account.id": "pro-user-8823",
                "bugscreen.account.role": "admin",
                "bugscreen.account.email": "qa@acme.dev",
            ]
        )
    }

    func testSetUserOmitsUnsetOptionalFields() {
        BugScreenSDK.setUser(id: "u1")

        XCTAssertEqual(BugScreenSDK.resolveReportCustomData(), ["bugscreen.account.id": "u1"])
    }

    func testAccountKeysMergeAlongsideCustomData() {
        BugScreenSDK.setCustomData(["env": "staging"])
        BugScreenSDK.setUser(id: "u1", role: "admin")

        XCTAssertEqual(
            BugScreenSDK.resolveReportCustomData(),
            [
                "env": "staging",
                "bugscreen.account.id": "u1",
                "bugscreen.account.role": "admin",
            ]
        )
    }

    func testProviderIsEvaluatedAtResolveTimeNotRegistration() {
        var role = "free"
        BugScreenSDK.setUserProvider { BugScreenUser(id: "u1", role: role) }
        XCTAssertEqual(BugScreenSDK.resolveReportCustomData()["bugscreen.account.role"], "free")

        // Account switched after the provider was registered — the fresh value wins.
        role = "admin"
        XCTAssertEqual(BugScreenSDK.resolveReportCustomData()["bugscreen.account.role"], "admin")
    }

    func testProviderReturningNilAttachesNoAccount() {
        BugScreenSDK.setUserProvider { nil }

        XCTAssertTrue(BugScreenSDK.resolveReportCustomData().isEmpty)
    }

    func testSetUserProviderClearsStaticUser() {
        BugScreenSDK.setUser(id: "static", role: "admin")
        BugScreenSDK.setUserProvider { BugScreenUser(id: "dynamic", role: "pro") }

        XCTAssertEqual(BugScreenSDK.resolveReportCustomData()["bugscreen.account.id"], "dynamic")
    }

    func testSetUserClearsProvider() {
        BugScreenSDK.setUserProvider { BugScreenUser(id: "dynamic") }
        BugScreenSDK.setUser(id: "static", role: "admin")

        XCTAssertEqual(BugScreenSDK.resolveReportCustomData()["bugscreen.account.id"], "static")
    }

    func testClearUserRemovesAccountButKeepsCustomData() {
        BugScreenSDK.setCustomData(["env": "staging"])
        BugScreenSDK.setUser(id: "u1")
        BugScreenSDK.clearUser()

        XCTAssertEqual(BugScreenSDK.resolveReportCustomData(), ["env": "staging"])
    }

    func testBlankFieldsAreDropped() {
        BugScreenSDK.setUser(id: "  ", role: "  ")

        XCTAssertTrue(BugScreenSDK.resolveReportCustomData().isEmpty)
    }

    func testToReservedKeysTrimsWhitespace() {
        XCTAssertEqual(
            BugScreenUser(id: "  u1 ", role: " admin ").toReservedKeys(),
            ["bugscreen.account.id": "u1", "bugscreen.account.role": "admin"]
        )
    }

    func testShutdownClearsUser() {
        BugScreenSDK.configure(apiKey: TestHelpers.validAPIKey)
        BugScreenSDK.setUser(id: "u1", role: "admin")

        BugScreenSDK.shutdown()

        XCTAssertTrue(BugScreenSDK.resolveReportCustomData().isEmpty)
    }
}
