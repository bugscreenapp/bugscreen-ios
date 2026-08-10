@testable import BugScreenSDK
import Foundation
import XCTest

/// Verifies the user-facing message routing for `BugScreenSDKError`. The exact
/// localized text is owned by `Localizable.xcstrings` — these tests check that
/// each case + backend `code` is mapped to the right bucket (config vs server
/// vs validation) and that technical details are preserved for "Show details".
final class BugScreenSDKErrorTests: XCTestCase {
    func test_notConfigured_routesToConfigMessage() {
        let error = BugScreenSDKError.notConfigured
        XCTAssertEqual(error.userMessage, SDKStrings.errorConfig)
        XCTAssertNotNil(error.technicalDetail)
    }

    func test_invalidArgument_routesToConfigMessage() {
        let error = BugScreenSDKError.invalidArgument("x")
        XCTAssertEqual(error.userMessage, SDKStrings.errorConfig)
        XCTAssertEqual(error.technicalDetail, "Invalid argument: x")
    }

    func test_invalidURL_routesToConfigMessage() {
        XCTAssertEqual(BugScreenSDKError.invalidURL.userMessage, SDKStrings.errorConfig)
    }

    func test_offline_routesToOfflineMessage() {
        XCTAssertEqual(BugScreenSDKError.offline.userMessage, SDKStrings.errorOffline)
    }

    func test_timeout_routesToTimeoutMessage() {
        XCTAssertEqual(BugScreenSDKError.timeout.userMessage, SDKStrings.errorTimeout)
    }

    func test_httpError_authCode_routesToConfigMessage() {
        let error = BugScreenSDKError.httpError(status: 401, code: "auth.invalid_key", message: "bad")
        XCTAssertEqual(error.userMessage, SDKStrings.errorConfig)
        XCTAssertEqual(error.technicalDetail, "HTTP 401 · code=auth.invalid_key · bad")
    }

    func test_httpError_validationDescription_routesToDescriptionRequired() {
        let error = BugScreenSDKError.httpError(status: 400, code: "validation.description", message: nil)
        XCTAssertEqual(error.userMessage, SDKStrings.validationDescriptionRequired)
    }

    func test_httpError_validationFileTooLarge_routesToFileTooLargeMessage() {
        let error = BugScreenSDKError.httpError(status: 400, code: "validation.file_too_large", message: nil)
        XCTAssertEqual(error.userMessage, SDKStrings.validationFileTooLarge)
    }

    func test_httpError_serverStorage_routesToServerMessage() {
        let error = BugScreenSDKError.httpError(status: 500, code: "server.storage", message: nil)
        XCTAssertEqual(error.userMessage, SDKStrings.errorServer)
    }

    func test_httpError_integrationsAllFailed_routesToConfigMessage() {
        let error = BugScreenSDKError.httpError(status: 500, code: "integrations.all_failed", message: nil)
        XCTAssertEqual(error.userMessage, SDKStrings.errorConfig)
    }

    func test_httpError_noCode_5xx_fallsBackToServerMessage() {
        let error = BugScreenSDKError.httpError(status: 500, code: nil, message: "boom")
        XCTAssertEqual(error.userMessage, SDKStrings.errorServer)
        XCTAssertEqual(error.technicalDetail, "HTTP 500 · boom")
    }

    func test_httpError_noCode_401_fallsBackToConfigMessage() {
        let error = BugScreenSDKError.httpError(status: 401, code: nil, message: nil)
        XCTAssertEqual(error.userMessage, SDKStrings.errorConfig)
    }

    func test_httpError_noCode_429_fallsBackToRateLimitedMessage() {
        let error = BugScreenSDKError.httpError(status: 429, code: nil, message: nil)
        XCTAssertEqual(error.userMessage, SDKStrings.errorRateLimited)
    }

    func test_errorDescription_matchesUserMessage() {
        let error = BugScreenSDKError.offline
        XCTAssertEqual(error.errorDescription, error.userMessage)
    }
}
