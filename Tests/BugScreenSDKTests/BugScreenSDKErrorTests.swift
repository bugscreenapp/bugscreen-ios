import XCTest
@testable import BugScreenSDK

/// Locks the human-readable `errorDescription` format for every public
/// `BugScreenSDKError` case. Every arm uses a `"<Category>: ..."` prefix or a
/// complete sentence; consumers (logging, alerts) can rely on a uniform shape.
final class BugScreenSDKErrorTests: XCTestCase {

    func testNotConfiguredDescription() {
        XCTAssertEqual(
            BugScreenSDKError.notConfigured.errorDescription,
            "BugScreenSDK not configured. Call BugScreenSDK.configure() before using the SDK."
        )
    }

    func testInvalidArgumentDescription() {
        XCTAssertEqual(
            BugScreenSDKError.invalidArgument("description is empty").errorDescription,
            "Invalid argument: description is empty"
        )
    }

    func testInvalidURLDescription() {
        XCTAssertEqual(
            BugScreenSDKError.invalidURL.errorDescription,
            "Invalid API URL. Please check your configuration."
        )
    }

    func testInvalidResponseDescription() {
        XCTAssertEqual(
            BugScreenSDKError.invalidResponse.errorDescription,
            "Invalid server response. Please try again."
        )
    }

    func testHTTPErrorDescription() {
        XCTAssertEqual(
            BugScreenSDKError.httpError(401).errorDescription,
            "HTTP error: 401. Unauthorized. Please check your API key."
        )
    }

    func testAPIErrorDescriptionIsPrefixed() {
        XCTAssertEqual(
            BugScreenSDKError.apiError("repo not found").errorDescription,
            "API error: repo not found"
        )
    }

    func testCancelledDescription() {
        XCTAssertEqual(
            BugScreenSDKError.cancelled.errorDescription,
            "Request cancelled."
        )
    }

    func testTimeoutDescription() {
        XCTAssertEqual(
            BugScreenSDKError.timeout.errorDescription,
            "Request timed out. Please try again."
        )
    }

    func testNetworkErrorDescription() {
        let underlying = URLError(.notConnectedToInternet)
        XCTAssertEqual(
            BugScreenSDKError.networkError(underlying).errorDescription,
            "Network error: \(underlying.localizedDescription)"
        )
    }

    func testEncodingErrorDescription() {
        XCTAssertEqual(
            BugScreenSDKError.encodingError.errorDescription,
            "Failed to encode request data. Please check your input."
        )
    }
}
