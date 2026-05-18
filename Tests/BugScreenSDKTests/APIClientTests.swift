import XCTest
@testable import BugScreenSDK

/// Tests for `APIClient` networking: multipart encoding of outgoing report
/// bodies, validation short-circuits, and response handling for 201/4xx/5xx.
/// Backed by `StubURLProtocol` so every request is observable and every
/// response deterministic — no live network, no timeouts.
@MainActor
final class APIClientTests: XCTestCase {

    private let stubBaseURL = URL(string: "https://stub.bugscreen.test/")!
    private let apiKey = TestHelpers.validAPIKey

    private func makeClient() -> APIClient {
        APIClient(apiKey: apiKey, baseURL: stubBaseURL, session: StubURLProtocol.makeSession())
    }

    private func sampleMetadata() -> BugReportMetadata {
        [
            "device": "Apple iPhone15,2",
            "osVersion": "17.0",
            "appVersion": "1.0.0",
            "customData": TestHelpers.sampleCustomData
        ]
    }

    private func stubSuccess(issueUrls: [String] = ["https://github.com/example/repo/issues/1"]) {
        let payload: [String: Any] = [
            "success": true,
            "message": "ok",
            "issueUrls": issueUrls
        ]
        let body = try! JSONSerialization.data(withJSONObject: payload)
        stubStatus(201, body: body)
    }

    private func stubStatus(_ code: Int, body: Data) {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: code,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, body)
        }
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        BugScreenSDK.shutdown()
        super.tearDown()
    }

    // MARK: - Multipart Encoding Tests

    func testMultipartBodyContainsDescription() async throws {
        stubSuccess()
        _ = try await makeClient().submitBugReport(
            description: "Login crash",
            metadata: sampleMetadata()
        )

        let body = try XCTUnwrap(StubURLProtocol.recordedBodies.first)
        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"description\""))
        XCTAssertTrue(text.contains("\r\n\r\nLogin crash\r\n"))
    }

    func testMultipartBodyContainsMetadata() async throws {
        stubSuccess()
        let metadata: BugReportMetadata = [
            "device": "Apple iPhone15,2",
            "appVersion": "1.2.3"
        ]
        _ = try await makeClient().submitBugReport(
            description: "ignored",
            metadata: metadata
        )

        let body = try XCTUnwrap(StubURLProtocol.recordedBodies.first)
        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"metadata\""))
        XCTAssertTrue(text.contains("Content-Type: application/json"))

        // Pull out the JSON section between the metadata headers and the next boundary.
        let json = try XCTUnwrap(extractPart(named: "metadata", from: body))
        let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        XCTAssertEqual(decoded?["device"] as? String, "Apple iPhone15,2")
        XCTAssertEqual(decoded?["appVersion"] as? String, "1.2.3")
    }

    func testMultipartBodyContainsScreenshot() async throws {
        stubSuccess()
        _ = try await makeClient().submitBugReport(
            description: "shot",
            metadata: sampleMetadata(),
            screenshot: TestHelpers.solidImage()
        )

        // PNG bytes aren't UTF-8, so search the raw Data, not a String view.
        let body = try XCTUnwrap(StubURLProtocol.recordedBodies.first)
        XCTAssertTrue(body.contains(utf8Bytes: "name=\"screenshot\"; filename=\"screenshot.png\""))
        XCTAssertTrue(body.contains(utf8Bytes: "Content-Type: image/png"))
    }

    func testMultipartBodyContainsLogFile() async throws {
        stubSuccess()
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bugscreen-test-\(UUID().uuidString).log")
        let logContents = "line1\nline2\n"
        try logContents.write(to: logURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: logURL) }

        _ = try await makeClient().submitBugReport(
            description: "with log",
            metadata: sampleMetadata(),
            logFile: logURL
        )

        let body = try XCTUnwrap(StubURLProtocol.recordedBodies.first)
        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("name=\"logFile\"; filename=\"logs.txt\""))
        XCTAssertTrue(text.contains(logContents))
    }

    // MARK: - Validation Tests

    func testEmptyDescriptionThrowsError() async {
        let client = makeClient()
        await XCTAssertThrowsErrorAsync(
            try await client.submitBugReport(description: "", metadata: sampleMetadata())
        ) { error in
            guard case let BugScreenSDKError.invalidArgument(message) = error else {
                return XCTFail("Expected .invalidArgument, got \(error)")
            }
            XCTAssertEqual(message, "Description must be between 1 and 10000 characters")
        }
        // Validation must short-circuit before any network request.
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testDescriptionTooLongThrowsError() async {
        let client = makeClient()
        let tooLong = String(repeating: "a", count: 10001)
        await XCTAssertThrowsErrorAsync(
            try await client.submitBugReport(description: tooLong, metadata: sampleMetadata())
        ) { error in
            guard case let BugScreenSDKError.invalidArgument(message) = error else {
                return XCTFail("Expected .invalidArgument, got \(error)")
            }
            XCTAssertEqual(message, "Description must be between 1 and 10000 characters")
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    // MARK: - Response Handling Tests

    func testSuccessfulSubmissionReturnsIssueURLs() async throws {
        stubSuccess(issueUrls: ["https://github.com/example/repo/issues/1"])
        let response = try await makeClient().submitBugReport(
            description: "valid",
            metadata: sampleMetadata()
        )

        XCTAssertEqual(response.issueURLs, ["https://github.com/example/repo/issues/1"])
        XCTAssertTrue(response.success)

        let request = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://stub.bugscreen.test/reports")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(apiKey)")
        XCTAssertTrue(
            request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") ?? false
        )
    }

    func test400ResponseThrowsAPIError() async {
        stubStatus(400, body: errorResponseJSON(
            error: "Bad Request",
            message: "Description is required",
            statusCode: 400
        ))
        await XCTAssertThrowsErrorAsync(
            try await makeClient().submitBugReport(description: "x", metadata: sampleMetadata())
        ) { error in
            guard case let BugScreenSDKError.apiError(message) = error else {
                return XCTFail("Expected .apiError, got \(error)")
            }
            XCTAssertEqual(message, "Description is required")
        }
    }

    func test401ResponseThrowsUnauthorizedError() async {
        stubStatus(401, body: errorResponseJSON(
            error: "Unauthorized",
            message: "Invalid or revoked API key",
            statusCode: 401
        ))
        await XCTAssertThrowsErrorAsync(
            try await makeClient().submitBugReport(description: "x", metadata: sampleMetadata())
        ) { error in
            guard case let BugScreenSDKError.apiError(message) = error else {
                return XCTFail("Expected .apiError, got \(error)")
            }
            XCTAssertEqual(message, "Invalid or revoked API key")
        }
    }

    func test500ResponseThrowsServerError() async {
        stubStatus(500, body: errorResponseJSON(
            error: "Internal Server Error",
            message: "Failed to create issue in GitHub: repository not found",
            statusCode: 500
        ))
        await XCTAssertThrowsErrorAsync(
            try await makeClient().submitBugReport(description: "x", metadata: sampleMetadata())
        ) { error in
            guard case let BugScreenSDKError.apiError(message) = error else {
                return XCTFail("Expected .apiError, got \(error)")
            }
            XCTAssertEqual(message, "Failed to create issue in GitHub: repository not found")
        }
    }

    // Locks the fallback at `APIClient.submitBugReport` where an undecodable
    // error body falls through to `.httpError(statusCode)`.
    func test500WithUndecodableBodyThrowsHTTPError() async {
        stubStatus(500, body: Data())
        await XCTAssertThrowsErrorAsync(
            try await makeClient().submitBugReport(description: "x", metadata: sampleMetadata())
        ) { error in
            guard case let BugScreenSDKError.httpError(code) = error else {
                return XCTFail("Expected .httpError, got \(error)")
            }
            XCTAssertEqual(code, 500)
        }
    }

    // MARK: - URLError Mapping Tests

    private func stubURLError(_ code: URLError.Code) {
        StubURLProtocol.handler = { _ in throw URLError(code) }
    }

    func testCancelledURLErrorMapsToCancelled() async {
        stubURLError(.cancelled)
        await XCTAssertThrowsErrorAsync(
            try await makeClient().submitBugReport(description: "x", metadata: sampleMetadata())
        ) { error in
            guard case BugScreenSDKError.cancelled = error else {
                return XCTFail("Expected .cancelled, got \(error)")
            }
        }
    }

    func testTimedOutURLErrorMapsToTimeout() async {
        stubURLError(.timedOut)
        await XCTAssertThrowsErrorAsync(
            try await makeClient().submitBugReport(description: "x", metadata: sampleMetadata())
        ) { error in
            guard case BugScreenSDKError.timeout = error else {
                return XCTFail("Expected .timeout, got \(error)")
            }
        }
    }

    func testUnmappedURLErrorFallsBackToNetworkError() async {
        stubURLError(.notConnectedToInternet)
        await XCTAssertThrowsErrorAsync(
            try await makeClient().submitBugReport(description: "x", metadata: sampleMetadata())
        ) { error in
            guard case let BugScreenSDKError.networkError(underlying) = error else {
                return XCTFail("Expected .networkError, got \(error)")
            }
            XCTAssertEqual((underlying as? URLError)?.code, .notConnectedToInternet)
        }
    }

    // MARK: - Helpers

    private func errorResponseJSON(error: String, message: String, statusCode: Int) -> Data {
        let payload: [String: Any] = [
            "error": error,
            "message": message,
            "statusCode": statusCode
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    /// Extracts the body of a single multipart part (between the headers'
    /// blank-line terminator and the next boundary). Good enough for the
    /// JSON-typed `metadata` part — not a general multipart parser.
    private func extractPart(named name: String, from body: Data) -> Data? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        let marker = "name=\"\(name)\""
        guard let nameRange = text.range(of: marker) else { return nil }
        guard let headerEnd = text.range(of: "\r\n\r\n", range: nameRange.upperBound..<text.endIndex) else {
            return nil
        }
        let afterHeader = headerEnd.upperBound
        guard let nextBoundary = text.range(of: "\r\n--", range: afterHeader..<text.endIndex) else {
            return nil
        }
        let part = text[afterHeader..<nextBoundary.lowerBound]
        return part.data(using: .utf8)
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
        XCTAssertEqual(response.issueURLs.count, 1)
        XCTAssertEqual(response.issueURLs[0], "https://github.com/example/repo/issues/123")
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
        XCTAssertEqual(response.issueURLs.count, 2)
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
        // The backend sends ErrorResponse for 5xx too. iOS surfaces the
        // message verbatim in the .apiError payload so support tickets read
        // the same as Android; errorDescription prefixes it for uniform
        // human-readable formatting across all SDK error cases.
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
        XCTAssertEqual(response.message, "Failed to create issue in GitHub: repository not found")
        let surfaced = BugScreenSDKError.apiError(response.message).errorDescription
        XCTAssertEqual(surfaced, "API error: Failed to create issue in GitHub: repository not found")
    }
}

// MARK: - Configuration Seam Tests

/// Exercises `BugScreenSDK.configureForTesting` — the DEBUG-only seam that
/// rebinds the singleton's `APIClient` to a caller-supplied `URLSession`.
/// These tests guard the wiring that all of the singleton-driven flows
/// (UI submit, screenshot detection) depend on.
@MainActor
final class APIClientConfigurationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        BugScreenSDK.shutdown()
        super.tearDown()
    }

    func testConfigureForTestingInstallsClientThatHitsStubbedSession() async throws {
        let stubURL = URL(string: "https://stub-a.bugscreen.test/")!
        BugScreenSDK.configureForTesting(
            apiKey: TestHelpers.validAPIKey,
            baseURL: stubURL,
            session: StubURLProtocol.makeSession()
        )

        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            let body = #"{"success":true,"message":"ok","issueUrls":[]}"#.data(using: .utf8)!
            return (response, body)
        }

        let client = try XCTUnwrap(BugScreenSDK.apiClient)
        _ = try await client.submitBugReport(description: "hi", metadata: ["device": "iPhone"])

        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertEqual(StubURLProtocol.recordedRequests.first?.url?.host, "stub-a.bugscreen.test")
    }

    func testReconfigureForTestingReplacesPreviousClient() async throws {
        BugScreenSDK.configureForTesting(
            apiKey: TestHelpers.validAPIKey,
            baseURL: URL(string: "https://stub-a.bugscreen.test/")!,
            session: StubURLProtocol.makeSession()
        )
        BugScreenSDK.configureForTesting(
            apiKey: TestHelpers.validAPIKey,
            baseURL: URL(string: "https://stub-b.bugscreen.test/")!,
            session: StubURLProtocol.makeSession()
        )

        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            let body = #"{"success":true,"message":"ok","issueUrls":[]}"#.data(using: .utf8)!
            return (response, body)
        }

        let client = try XCTUnwrap(BugScreenSDK.apiClient)
        _ = try await client.submitBugReport(description: "hi", metadata: ["device": "iPhone"])

        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertEqual(StubURLProtocol.recordedRequests.first?.url?.host, "stub-b.bugscreen.test")
    }
}

// MARK: - Data search helper

private extension Data {
    /// True if `self` contains the UTF-8 bytes of `string`. Used to look for
    /// ASCII markers (headers, boundaries) inside multipart bodies that also
    /// contain non-UTF-8 binary content like PNG image data.
    func contains(utf8Bytes string: String) -> Bool {
        guard let needle = string.data(using: .utf8) else { return false }
        return range(of: needle) != nil
    }
}

// MARK: - Async assertion helper

/// `XCTAssertThrowsError` doesn't support `async` expressions, so we provide
/// a tiny shim that awaits an autoclosure and routes thrown errors into the
/// caller's handler. The handler is required so a missing one can't silently
/// pass any thrown error.
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
