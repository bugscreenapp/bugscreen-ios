import XCTest
@testable import BugScreenSDK

/// Tests for APIClient networking functionality.
///
/// Note: These are unit tests that test the client logic.
/// Integration tests with a real/mock server would go in a separate test suite.
final class APIClientTests: XCTestCase {

    // MARK: - Multipart Encoding Tests

    func testMultipartBodyContainsDescription() throws {
        // Note: APIClient's createMultipartBody is private,
        // so we test it indirectly through submission
        // This test structure is a placeholder for when we add
        // mock URLSession support or extract multipart logic
        XCTAssertTrue(true, "Placeholder for multipart encoding test")
    }

    func testMultipartBodyContainsMetadata() throws {
        XCTAssertTrue(true, "Placeholder for metadata encoding test")
    }

    func testMultipartBodyContainsScreenshot() throws {
        XCTAssertTrue(true, "Placeholder for screenshot encoding test")
    }

    func testMultipartBodyContainsLogFile() throws {
        XCTAssertTrue(true, "Placeholder for log file encoding test")
    }

    // MARK: - Error Handling Tests

    func testEmptyDescriptionThrowsError() async throws {
        // This will be implemented when we add mock URLSession
        XCTAssertTrue(true, "Placeholder for empty description validation")
    }

    func testDescriptionTooLongThrowsError() async throws {
        // This will be implemented when we add mock URLSession
        XCTAssertTrue(true, "Placeholder for description length validation")
    }

    // MARK: - Integration Test Placeholders

    // These would require a mock URLSession or mock server
    // For now, they serve as documentation of what should be tested

    func testSuccessfulSubmissionReturnsIssueURLs() async throws {
        // TODO: Implement with mock URLSession
        // Should test 201 response with issueUrls array
        XCTAssertTrue(true, "Placeholder - requires mock server")
    }

    func test400ResponseThrowsAPIError() async throws {
        // TODO: Implement with mock URLSession
        // Should test bad request error handling
        XCTAssertTrue(true, "Placeholder - requires mock server")
    }

    func test401ResponseThrowsUnauthorizedError() async throws {
        // TODO: Implement with mock URLSession
        // Should test invalid API key handling
        XCTAssertTrue(true, "Placeholder - requires mock server")
    }

    func test500ResponseThrowsServerError() async throws {
        // TODO: Implement with mock URLSession
        // Should test internal server error handling
        XCTAssertTrue(true, "Placeholder - requires mock server")
    }
}

// MARK: - Response Model Tests

final class APIModelsTests: XCTestCase {

    func testBugReportResponseDecoding() throws {
        let json = """
        {
            "success": true,
            "message": "Bug report submitted successfully",
            "issueUrls": [
                "https://github.com/example/repo/issues/123"
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let response = try decoder.decode(BugReportResponse.self, from: data)

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.message, "Bug report submitted successfully")
        XCTAssertEqual(response.issueUrls.count, 1)
        XCTAssertEqual(response.issueUrls[0], "https://github.com/example/repo/issues/123")
    }

    func testBugReportResponseWithMultipleIssues() throws {
        let json = """
        {
            "success": true,
            "message": "Bug report submitted successfully",
            "issueUrls": [
                "https://github.com/example/repo/issues/123",
                "https://github.com/example/another-repo/issues/456"
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let response = try decoder.decode(BugReportResponse.self, from: data)

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.issueUrls.count, 2)
    }

    func testErrorResponseDecoding() throws {
        let json = """
        {
            "error": "Bad Request",
            "message": "Description is required",
            "statusCode": 400
        }
        """

        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let response = try decoder.decode(ErrorResponse.self, from: data)

        XCTAssertEqual(response.error, "Bad Request")
        XCTAssertEqual(response.message, "Description is required")
        XCTAssertEqual(response.statusCode, 400)
    }

    func testErrorResponse401Decoding() throws {
        let json = """
        {
            "error": "Unauthorized",
            "message": "Invalid or revoked API key",
            "statusCode": 401
        }
        """

        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let response = try decoder.decode(ErrorResponse.self, from: data)

        XCTAssertEqual(response.error, "Unauthorized")
        XCTAssertEqual(response.message, "Invalid or revoked API key")
        XCTAssertEqual(response.statusCode, 401)
    }

    func testErrorResponse500DecodingSurfacesMessage() throws {
        // The backend sends ErrorResponse for 5xx too. iOS must surface the
        // message verbatim so support tickets read the same as Android.
        let json = """
        {
            "error": "Internal Server Error",
            "message": "Failed to create issue in GitHub: repository not found",
            "statusCode": 500
        }
        """

        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let response = try decoder.decode(ErrorResponse.self, from: data)

        XCTAssertEqual(response.statusCode, 500)
        let surfaced = BugScreenSDKError.apiError(response.message).errorDescription
        XCTAssertEqual(surfaced, "Failed to create issue in GitHub: repository not found")
    }
}
