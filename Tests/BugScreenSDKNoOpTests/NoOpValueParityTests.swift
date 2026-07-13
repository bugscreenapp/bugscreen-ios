import Foundation
import XCTest

/// Guards value-type **body** parity between the real SDK and the no-op stub.
///
/// `check-noop-parity.sh` locks the public *signatures* via the symbol graph, but
/// it can't see the executable bodies a consumer actually runs in a Release build:
/// `LogLevel.displayName` strings, its `Comparable` ordering, and the
/// `BugReportResponse` `CodingKeys` mapping (`issueURLs = "issueUrls"`). If the
/// real SDK's body drifts (`"WARN"` → `"WARNING"`, a renamed coding key) the
/// surface diff still passes — this test fails instead. It compares the two
/// modules via primitive snapshots (RealSDKValueSnapshot / NoOpValueSnapshot),
/// which each import one module in isolation so this file needs neither.
final class NoOpValueParityTests: XCTestCase {
    func testLogLevelDisplayNamesAndOrderingMatchRealSDK() {
        XCTAssertEqual(RealSDKValueSnapshot.logLevelDisplayNames, NoOpValueSnapshot.logLevelDisplayNames)
        XCTAssertEqual(RealSDKValueSnapshot.logLevelCaseCount, NoOpValueSnapshot.logLevelCaseCount)
        XCTAssertEqual(RealSDKValueSnapshot.verboseIsLessThanError, NoOpValueSnapshot.verboseIsLessThanError)
    }

    func testBugReportResponseDecodesTheSameWireShape() throws {
        // The `issueUrls` → issueURLs key mapping is the drift-prone bit.
        let json = Data(
            #"{"success":true,"message":"ok","issueUrls":["https://example.com/1"],"partialFailures":null}"#.utf8
        )
        let real = try RealSDKValueSnapshot.decodedIssueURLs(from: json)
        let noop = try NoOpValueSnapshot.decodedIssueURLs(from: json)
        XCTAssertEqual(real, noop)
        XCTAssertEqual(noop, ["https://example.com/1"])
    }

    func testBugScreenUserFieldsMatchRealSDK() {
        let real = RealSDKValueSnapshot.userFields(id: "pro-user-8823", role: "admin", email: "qa@example.com")
        let noop = NoOpValueSnapshot.userFields(id: "pro-user-8823", role: "admin", email: "qa@example.com")
        XCTAssertEqual(real.id, noop.id)
        XCTAssertEqual(real.role, noop.role)
        XCTAssertEqual(real.email, noop.email)
    }
}
