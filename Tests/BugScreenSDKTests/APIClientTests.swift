@testable import BugScreenSDK
import XCTest

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
            "customData": TestHelpers.sampleCustomData,
        ]
    }

    private func stubSuccess(issueUrls: [String] = ["https://github.com/example/repo/issues/1"]) {
        let payload: [String: Any] = [
            "success": true,
            "message": "ok",
            "issueUrls": issueUrls,
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
            "appVersion": "1.2.3",
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

    /// A screenshot as the reporter now hands it over: already downscaled and re-encoded.
    /// Encoding itself is asserted in BugScreenSDKReporterTests/ScreenshotPreparationTests
    /// — what matters here is that the transport packs whatever it is given faithfully.
    private func prepared(
        _ image: UIImage = TestHelpers.solidImage(),
        contentType: String = "image/jpeg",
        fileExtension: String = "jpg"
    ) -> PreparedScreenshot {
        let data = image.jpegData(compressionQuality: 0.85) ?? Data([0xFF, 0xD8])
        return PreparedScreenshot(data: data, contentType: contentType, fileExtension: fileExtension)
    }

    func testMultipartBodyContainsScreenshot() async throws {
        stubSuccess()
        _ = try await makeClient().submitBugReport(
            description: "shot",
            metadata: sampleMetadata(),
            screenshots: [prepared()]
        )

        // The transport writes whatever content type and extension it is handed. The
        // downscale + re-encode that makes them JPEG happens in the reporter now
        // (RFC-003 §2.2). Search raw Data (JPEG bytes aren't UTF-8).
        let body = try XCTUnwrap(StubURLProtocol.recordedBodies.first)
        XCTAssertTrue(body.contains(utf8Bytes: "name=\"screenshot\"; filename=\"screenshot-1.jpg\""))
        XCTAssertTrue(body.contains(utf8Bytes: "Content-Type: image/jpeg"))
    }

    func testMultipartBodyContainsAllScreenshotsInOrder() async throws {
        stubSuccess()
        let images = [
            prepared(TestHelpers.solidImage(color: .red)),
            prepared(TestHelpers.solidImage(color: .green)),
            prepared(TestHelpers.solidImage(color: .blue)),
        ]
        _ = try await makeClient().submitBugReport(
            description: "shots",
            metadata: sampleMetadata(),
            screenshots: images
        )

        let body = try XCTUnwrap(StubURLProtocol.recordedBodies.first)
        for index in 1 ... images.count {
            XCTAssertTrue(
                body.contains(utf8Bytes: "name=\"screenshot\"; filename=\"screenshot-\(index).jpg\""),
                "Expected multipart part for screenshot-\(index)"
            )
        }
    }

    func testScreenshotsCapAtFourEvenIfMorePassed() async throws {
        stubSuccess()
        let images = (1 ... 6).map { _ in prepared() }
        _ = try await makeClient().submitBugReport(
            description: "shots",
            metadata: sampleMetadata(),
            screenshots: images
        )

        let body = try XCTUnwrap(StubURLProtocol.recordedBodies.first)
        for index in 1 ... 4 {
            XCTAssertTrue(body.contains(utf8Bytes: "filename=\"screenshot-\(index).jpg\""))
        }
        XCTAssertFalse(body.contains(utf8Bytes: "filename=\"screenshot-5"))
    }

    func testMultipartBodyOmitsTypeAndSeverityWhenNil() async throws {
        stubSuccess()
        _ = try await makeClient().submitBugReport(
            description: "valid",
            metadata: sampleMetadata()
        )

        let body = try XCTUnwrap(StubURLProtocol.recordedBodies.first)
        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("name=\"type\""))
        XCTAssertFalse(text.contains("name=\"severity\""))
    }

    func testMultipartBodyIncludesTypeAndSeverityWhenProvided() async throws {
        stubSuccess()
        _ = try await makeClient().submitBugReport(
            description: "valid",
            metadata: sampleMetadata(),
            type: "ui",
            severity: "high"
        )

        let body = try XCTUnwrap(StubURLProtocol.recordedBodies.first)
        let text = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("name=\"type\""))
        XCTAssertTrue(text.contains("\r\n\r\nui\r\n"))
        XCTAssertTrue(text.contains("name=\"severity\""))
        XCTAssertTrue(text.contains("\r\n\r\nhigh\r\n"))
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

    func test400ResponseThrowsHTTPErrorWithMessage() async {
        stubStatus(400, body: errorResponseJSON(
            error: "Bad Request",
            message: "Description is required",
            statusCode: 400
        ))
        await XCTAssertThrowsErrorAsync(
            try await makeClient().submitBugReport(description: "x", metadata: sampleMetadata())
        ) { error in
            guard case let BugScreenSDKError.httpError(status, _, message) = error else {
                return XCTFail("Expected .httpError, got \(error)")
            }
            XCTAssertEqual(status, 400)
            XCTAssertEqual(message, "Description is required")
        }
    }

    func test401ResponseThrowsHTTPErrorWithMessage() async {
        stubStatus(401, body: errorResponseJSON(
            error: "Unauthorized",
            message: "Invalid or revoked API key",
            statusCode: 401
        ))
        await XCTAssertThrowsErrorAsync(
            try await makeClient().submitBugReport(description: "x", metadata: sampleMetadata())
        ) { error in
            guard case let BugScreenSDKError.httpError(status, _, message) = error else {
                return XCTFail("Expected .httpError, got \(error)")
            }
            XCTAssertEqual(status, 401)
            XCTAssertEqual(message, "Invalid or revoked API key")
        }
    }

    func test402PlanLimitReportsThrowsHTTPErrorWithConfigMessage() async {
        let body = """
        {"error":"Payment Required","message":"over cap","statusCode":402,"code":"plan_limit.reports"}
        """.data(using: .utf8)!
        stubStatus(402, body: body)
        await XCTAssertThrowsErrorAsync(
            try await makeClient().submitBugReport(description: "x", metadata: sampleMetadata())
        ) { error in
            guard let sdkError = error as? BugScreenSDKError,
                  case let .httpError(status, code, _) = sdkError
            else {
                return XCTFail("Expected .httpError, got \(error)")
            }
            XCTAssertEqual(status, 402)
            XCTAssertEqual(code, "plan_limit.reports")
            XCTAssertEqual(sdkError.userMessage, SDKStrings.errorConfig)
        }
    }

    func test500ResponseThrowsHTTPErrorWithMessage() async {
        stubStatus(500, body: errorResponseJSON(
            error: "Internal Server Error",
            message: "Failed to create issue in GitHub: repository not found",
            statusCode: 500
        ))
        await XCTAssertThrowsErrorAsync(
            try await makeClient().submitBugReport(description: "x", metadata: sampleMetadata())
        ) { error in
            guard case let BugScreenSDKError.httpError(status, _, message) = error else {
                return XCTFail("Expected .httpError, got \(error)")
            }
            XCTAssertEqual(status, 500)
            XCTAssertEqual(message, "Failed to create issue in GitHub: repository not found")
        }
    }

    /// Locks the fallback at `APIClient.submitBugReport` where an undecodable
    /// error body falls through to `.httpError(status:, code: nil, message: nil)`.
    func test500WithUndecodableBodyThrowsHTTPError() async {
        stubStatus(500, body: Data())
        await XCTAssertThrowsErrorAsync(
            try await makeClient().submitBugReport(description: "x", metadata: sampleMetadata())
        ) { error in
            guard case let BugScreenSDKError.httpError(status, code, message) = error else {
                return XCTFail("Expected .httpError, got \(error)")
            }
            XCTAssertEqual(status, 500)
            XCTAssertNil(code)
            XCTAssertNil(message)
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

    func testNotConnectedToInternetMapsToOffline() async {
        stubURLError(.notConnectedToInternet)
        await XCTAssertThrowsErrorAsync(
            try await makeClient().submitBugReport(description: "x", metadata: sampleMetadata())
        ) { error in
            guard case BugScreenSDKError.offline = error else {
                return XCTFail("Expected .offline, got \(error)")
            }
        }
    }

    func testUnmappedURLErrorFallsBackToNetworkError() async {
        stubURLError(.badServerResponse)
        await XCTAssertThrowsErrorAsync(
            try await makeClient().submitBugReport(description: "x", metadata: sampleMetadata())
        ) { error in
            guard case let BugScreenSDKError.networkError(underlying) = error else {
                return XCTFail("Expected .networkError, got \(error)")
            }
            XCTAssertEqual((underlying as? URLError)?.code, .badServerResponse)
        }
    }

    // MARK: - Runtime Config Fetch

    func testFetchRuntimeConfigSendsGetToConfigWithBearerAuth() async throws {
        stubStatus(200, body: Data(#"{"appId":"app-123","showBranding":true}"#.utf8))

        let runtimeConfig = try await makeClient().fetchRuntimeConfig()

        XCTAssertTrue(runtimeConfig.showBranding)
        XCTAssertTrue(runtimeConfig.severityEnabled)
        XCTAssertNil(runtimeConfig.videoAttachmentLimits)
        let request = StubURLProtocol.recordedRequests.first
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(request?.url?.path, "/config")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer \(apiKey)")
    }

    func testRemoteWordingReachesResolvedConfigAndMalformedSuppliedCopyFails() async throws {
        stubStatus(
            200,
            body: Data(#"{"appId":"app-123","showBranding":false,"reporterCopy":{"title":"Share <feedback>","successMessage":"We received your thoughts."}}"#
                .utf8)
        )
        let config = try await makeClient().fetchRuntimeConfig()
        XCTAssertEqual(config.copy.title, "Share <feedback>")
        XCTAssertEqual(config.copy.successMessage, "We received your thoughts.")
        XCTAssertEqual(config.copy.submitLabel, "Create ticket")
        for copy in ["null", #"{"title":17}"#, #"{"title":" "}"#] {
            stubStatus(200, body: Data(#"{"appId":"app-123","showBranding":false,"reporterCopy":\#(copy)}"#.utf8))
            await XCTAssertThrowsErrorAsync(try await makeClient().fetchRuntimeConfig()) { _ in }
        }
    }

    func testVideoLimitsAreDecodedFromConfigAndInvalidPoliciesFail() async throws {
        stubStatus(
            200,
            body: Data(#"{"appId":"app-123","showBranding":false,"videoAttachmentLimits":{"maxSizeBytes":25000000,"maxDurationSeconds":120}}"#
                .utf8)
        )
        let config = try await makeClient().fetchRuntimeConfig()
        let policy = try XCTUnwrap(config.videoAttachmentLimits)
        XCTAssertEqual(policy.maxSizeBytes, 25_000_000)
        XCTAssertEqual(policy.maxDurationSeconds, 120)
        for policy in [
            #"{"maxSizeBytes":0,"maxDurationSeconds":120}"#,
            #"{"maxSizeBytes":25000000,"maxDurationSeconds":0}"#,
            #"{"maxSizeBytes":25000000}"#,
        ] {
            stubStatus(200, body: Data("{\"appId\":\"app-123\",\"showBranding\":false,\"videoAttachmentLimits\":\(policy)}".utf8))
            await XCTAssertThrowsErrorAsync(try await makeClient().fetchRuntimeConfig()) { _ in }
        }
    }

    func testReporterPresentationsReuseCachedConfigWithoutReconfiguringSDK() async throws {
        var calls = 0
        BugScreenSDK.configureForTesting(apiKey: TestHelpers.validAPIKey,
                                         baseURL: try XCTUnwrap(URL(string: "https://stub.bugscreen.test/")),
                                         session: StubURLProtocol.makeSession(), runtimeConfigLoader: { _ in
                                             calls += 1
                                             return ResolvedSdkConfig(showBranding: calls == 1, reportTypes: ["Config\(calls)"],
                                                                      severityEnabled: calls == 1,
                                                                      videoAttachmentLimits: VideoAttachmentLimits(
                                                                          maxSizeBytes: Int64(calls * 10_000_000),
                                                                          maxDurationSeconds: Double(calls * 60)
                                                                      ), copy: ReporterCopy(
                                                                          title: "Form \(calls)",
                                                                          successMessage: "Thanks \(calls)"
                                                                      ))
                                         })
        guard case let .ready(first) = await BugScreenSDK.loadReporterConfiguration(forceRefresh: false),
              case let .ready(second) = await BugScreenSDK.loadReporterConfiguration(forceRefresh: false)
        else {
            return XCTFail("Expected configured reporters")
        }
        XCTAssertEqual(calls, 1)
        for config in [first, second] {
            XCTAssertTrue(config.showBranding)
            XCTAssertEqual(config.reportTypes, ["Config1"])
            XCTAssertTrue(config.severityEnabled)
            XCTAssertEqual(config.copy.title, "Form 1")
            XCTAssertEqual(config.copy.successMessage, "Thanks 1")
            XCTAssertEqual(config.videoAttachmentLimits?.maxSizeBytes, 10_000_000)
            XCTAssertEqual(config.videoAttachmentLimits?.maxDurationSeconds, 60)
        }
    }

    func testReporterReusesInFlightStartupVideoPolicy() async throws {
        let latch = RuntimeConfigLatch()
        var calls = 0
        BugScreenSDK.configureForTesting(apiKey: TestHelpers.validAPIKey,
                                         baseURL: try XCTUnwrap(URL(string: "https://stub.bugscreen.test/")),
                                         session: StubURLProtocol.makeSession(), runtimeConfigLoader: { _ in
                                             calls += 1
                                             return await latch.wait()
                                         })
        let reporter = Task { await BugScreenSDK.loadReporterConfiguration(forceRefresh: false) }
        let deadline = Date().addingTimeInterval(5)
        while calls == 0, Date() < deadline {
            await Task.yield()
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        XCTAssertEqual(calls, 1)
        await latch.release(ResolvedSdkConfig(showBranding: false, reportTypes: defaultReportTypes,
                                              videoAttachmentLimits: VideoAttachmentLimits(maxSizeBytes: 25_000_000,
                                                                                           maxDurationSeconds: 120)))
        guard case let .ready(config) = await reporter.value else { return XCTFail("Expected reporter config") }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(config.videoAttachmentLimits?.maxSizeBytes, 25_000_000)
        XCTAssertEqual(config.videoAttachmentLimits?.maxDurationSeconds, 120)
    }

    func testCompletedStartupConfigIsCachedBeforeFirstReporter() async throws {
        var calls = 0
        BugScreenSDK.configureForTesting(apiKey: TestHelpers.validAPIKey,
                                         baseURL: try XCTUnwrap(URL(string: "https://stub.bugscreen.test/")),
                                         session: StubURLProtocol.makeSession(), runtimeConfigLoader: { _ in
                                             calls += 1
                                             return ResolvedSdkConfig(showBranding: false, reportTypes: ["Config\(calls)"],
                                                                      videoAttachmentLimits: VideoAttachmentLimits(
                                                                          maxSizeBytes: Int64(calls * 10_000_000),
                                                                          maxDurationSeconds: 120
                                                                      ))
                                         })
        let deadline = Date().addingTimeInterval(5)
        while BugScreenSDK.reportTypes != ["Config1"], Date() < deadline {
            await Task.yield()
        }
        XCTAssertEqual(BugScreenSDK.reportTypes, ["Config1"])
        XCTAssertEqual(calls, 1)
        guard case let .ready(config) = await BugScreenSDK.loadReporterConfiguration(forceRefresh: false) else {
            return XCTFail("Expected reporter configuration")
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(config.reportTypes, ["Config1"])
        XCTAssertEqual(config.videoAttachmentLimits?.maxSizeBytes, 10_000_000)
    }

    func testFailedStartupConfigRequiresExplicitRetryAndSuccessfulRetryIsCached() async {
        var calls = 0
        BugScreenSDK.configureForTesting(
            apiKey: TestHelpers.validAPIKey,
            baseURL: stubBaseURL,
            session: StubURLProtocol.makeSession(),
            runtimeConfigLoader: { _ in
                calls += 1
                if calls == 1 { throw URLError(.notConnectedToInternet) }
                return ResolvedSdkConfig(showBranding: false, reportTypes: ["Recovered"], severityEnabled: false,
                                         videoAttachmentLimits: VideoAttachmentLimits(maxSizeBytes: 25_000_000, maxDurationSeconds: 120))
            }
        )
        for _ in 0 ..< 2 {
            guard case .unavailable = await BugScreenSDK.loadReporterConfiguration(forceRefresh: false) else {
                return XCTFail("A failed initialization must wait for explicit Retry")
            }
        }
        XCTAssertEqual(calls, 1)
        guard case let .ready(retry) = await BugScreenSDK.loadReporterConfiguration(forceRefresh: true),
              case let .ready(reopened) = await BugScreenSDK.loadReporterConfiguration(forceRefresh: false)
        else { return XCTFail("Retry must recover the reporter configuration") }
        XCTAssertEqual(calls, 2)
        for config in [retry, reopened] {
            XCTAssertEqual(config.reportTypes, ["Recovered"])
            XCTAssertFalse(config.severityEnabled)
            XCTAssertEqual(config.videoAttachmentLimits?.maxSizeBytes, 25_000_000)
        }
    }

    func testReinitializationReplacesCompletedCachedConfig() async {
        var calls = 0
        func configure() {
            BugScreenSDK.configureForTesting(
                apiKey: TestHelpers.validAPIKey,
                baseURL: stubBaseURL,
                session: StubURLProtocol.makeSession(),
                runtimeConfigLoader: { _ in
                    calls += 1
                    return ResolvedSdkConfig(showBranding: false, reportTypes: ["Config\(calls)"])
                }
            )
        }
        configure()
        guard case let .ready(first) = await BugScreenSDK.loadReporterConfiguration(forceRefresh: false) else {
            return XCTFail("Expected initial cached configuration")
        }
        XCTAssertEqual(first.reportTypes, ["Config1"])
        XCTAssertEqual(calls, 1)
        configure()
        guard case let .ready(second) = await BugScreenSDK.loadReporterConfiguration(forceRefresh: false),
              case let .ready(reopened) = await BugScreenSDK.loadReporterConfiguration(forceRefresh: false)
        else { return XCTFail("Expected replacement cached configuration") }
        XCTAssertEqual(second.reportTypes, ["Config2"])
        XCTAssertEqual(reopened.reportTypes, ["Config2"])
        XCTAssertEqual(calls, 2)
    }

    func testFetchRuntimeConfigReturnsFalseWhenServerSaysSo() async throws {
        stubStatus(
            200,
            body: Data(#"{"appId":"app-123","showBranding":false,"severityEnabled":false}"#.utf8)
        )

        let runtimeConfig = try await makeClient().fetchRuntimeConfig()

        XCTAssertFalse(runtimeConfig.showBranding)
        XCTAssertEqual(runtimeConfig.reportTypes, defaultReportTypes)
        XCTAssertFalse(runtimeConfig.severityEnabled)
    }

    func testFetchRuntimeConfigDistinguishesCustomEmptyAndMissingReportTypes() async throws {
        stubStatus(
            200,
            body: Data(#"{"appId":"app-123","showBranding":false,"reportTypes":["Bug","Question"]}"#.utf8)
        )
        var config = try await makeClient().fetchRuntimeConfig()
        XCTAssertEqual(config.reportTypes, ["Bug", "Question"])

        stubStatus(200, body: Data(#"{"appId":"app-123","showBranding":false,"reportTypes":[]}"#.utf8))
        config = try await makeClient().fetchRuntimeConfig()
        XCTAssertEqual(config.reportTypes, [])

        stubStatus(200, body: Data(#"{"appId":"app-123","showBranding":false}"#.utf8))
        config = try await makeClient().fetchRuntimeConfig()
        XCTAssertEqual(config.reportTypes, defaultReportTypes)
    }

    func testFetchRuntimeConfigThrowsOnHTTPError() async {
        stubStatus(401, body: Data())

        await XCTAssertThrowsErrorAsync(try await makeClient().fetchRuntimeConfig()) { error in
            guard case BugScreenSDKError.httpError = error else {
                return XCTFail("Expected HTTP error, got \(error)")
            }
        }
    }

    func testFetchRuntimeConfigThrowsOnUndecodableBody() async {
        stubStatus(200, body: Data(#"<html>not json</html>"#.utf8))

        await XCTAssertThrowsErrorAsync(try await makeClient().fetchRuntimeConfig()) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    // MARK: - SDK Version Headers (OPS-011)

    func testSubmitSendsSdkVersionTransportHeader() async throws {
        stubSuccess()
        _ = try await makeClient().submitBugReport(description: "valid", metadata: sampleMetadata())

        let request = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-BugScreen-SDK"), "ios/\(BugScreenSDK.version)")
        // No wrapper configured → header absent for a direct native integration.
        XCTAssertNil(request.value(forHTTPHeaderField: "X-BugScreen-SDK-Wrapper"))
    }

    func testFetchConfigSendsSdkVersionTransportHeader() async {
        stubStatus(200, body: Data(#"{"appId":"app-123","showBranding":false}"#.utf8))
        _ = try? await makeClient().fetchRuntimeConfig()

        let request = StubURLProtocol.recordedRequests.first
        XCTAssertEqual(request?.value(forHTTPHeaderField: "X-BugScreen-SDK"), "ios/\(BugScreenSDK.version)")
        XCTAssertNil(request?.value(forHTTPHeaderField: "X-BugScreen-SDK-Wrapper"))
    }

    func testSubmitSendsWrapperHeaderWhenConfigured() async throws {
        stubSuccess()
        let client = APIClient(
            apiKey: apiKey,
            wrapperSdk: "rn/0.5.0",
            baseURL: stubBaseURL,
            session: StubURLProtocol.makeSession()
        )
        _ = try await client.submitBugReport(description: "valid", metadata: sampleMetadata())

        let request = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        // The native transport header (gating-relevant) is still the iOS SDK version...
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-BugScreen-SDK"), "ios/\(BugScreenSDK.version)")
        // ...and the wrapper tag rides the informational header verbatim.
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-BugScreen-SDK-Wrapper"), "rn/0.5.0")
    }

    // MARK: - Helpers

    private func errorResponseJSON(error: String, message: String, statusCode: Int) -> Data {
        let payload: [String: Any] = [
            "error": error,
            "message": message,
            "statusCode": statusCode,
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
        guard let headerEnd = text.range(of: "\r\n\r\n", range: nameRange.upperBound ..< text.endIndex) else {
            return nil
        }
        let afterHeader = headerEnd.upperBound
        guard let nextBoundary = text.range(of: "\r\n--", range: afterHeader ..< text.endIndex) else {
            return nil
        }
        let part = text[afterHeader ..< nextBoundary.lowerBound]
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

        let data = try XCTUnwrap(json.data(using: .utf8))
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

        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoder = JSONDecoder()
        let response = try decoder.decode(BugReportResponse.self, from: data)

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.issueURLs.count, 2)
    }

    func testBugReportResponseDecodesPartialFailureTypeAsOpenString() throws {
        // bugscreen-c7e / INT-007 / CAP-009: partialFailures[].type is the live
        // IntegrationType, carried as an open string. A type beyond the core three
        // (here "slack", a future provider) must decode verbatim — never throw and never
        // drop the entry — so this SDK build keeps working when a new provider ships.
        let json = """
        {
            "success": true,
            "message": "Bug report submitted successfully",
            "issueUrls": ["https://github.com/example/repo/issues/123"],
            "partialFailures": [
                { "type": "slack", "message": "channel archived" }
            ]
        }
        """

        let data = try XCTUnwrap(json.data(using: .utf8))
        let response = try JSONDecoder().decode(BugReportResponse.self, from: data)

        XCTAssertEqual(response.partialFailures?.count, 1)
        XCTAssertEqual(response.partialFailures?.first?.type, "slack")
        XCTAssertEqual(response.partialFailures?.first?.message, "channel archived")
    }

    func testBugReportResponseDecodesInboxOnlyAllFailedResponse() throws {
        let json = """
        {
            "success": true,
            "message": "Bug report submitted successfully",
            "issueUrls": [],
            "partialFailures": [
                { "type": "github", "message": "provider unavailable" }
            ]
        }
        """

        let data = try XCTUnwrap(json.data(using: .utf8))
        let response = try JSONDecoder().decode(BugReportResponse.self, from: data)

        XCTAssertTrue(response.issueURLs.isEmpty)
        XCTAssertEqual(response.partialFailures?.count, 1)
        XCTAssertEqual(response.partialFailures?.first?.type, "github")
        XCTAssertEqual(response.partialFailures?.first?.message, "provider unavailable")
    }

    func testErrorResponseDecoding() throws {
        let json = """
        {
            "error": "Bad Request",
            "message": "Description is required",
            "statusCode": 400
        }
        """

        let data = try XCTUnwrap(json.data(using: .utf8))
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

        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoder = JSONDecoder()
        let response = try decoder.decode(ErrorResponse.self, from: data)

        XCTAssertEqual(response.error, "Unauthorized")
        XCTAssertEqual(response.message, "Invalid or revoked API key")
        XCTAssertEqual(response.statusCode, 401)
    }

    func testErrorResponse500DecodingPreservesTechnicalDetail() throws {
        let json = """
        {
            "error": "Internal Server Error",
            "message": "Failed to create issue in GitHub: repository not found",
            "statusCode": 500,
            "code": "integrations.all_failed"
        }
        """

        let data = try XCTUnwrap(json.data(using: .utf8))
        let response = try JSONDecoder().decode(ErrorResponse.self, from: data)
        XCTAssertEqual(response.statusCode, 500)
        XCTAssertEqual(response.code, "integrations.all_failed")
        let error = BugScreenSDKError.httpError(
            status: response.statusCode,
            code: response.code,
            message: response.message
        )
        XCTAssertEqual(error.userMessage, SDKStrings.errorConfig)
        XCTAssertEqual(
            error.technicalDetail,
            "HTTP 500 · code=integrations.all_failed · Failed to create issue in GitHub: repository not found"
        )
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
        let stubURL = try XCTUnwrap(URL(string: "https://stub-a.bugscreen.test/"))
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
            baseURL: try XCTUnwrap(URL(string: "https://stub-a.bugscreen.test/")),
            session: StubURLProtocol.makeSession()
        )
        BugScreenSDK.configureForTesting(
            apiKey: TestHelpers.validAPIKey,
            baseURL: try XCTUnwrap(URL(string: "https://stub-b.bugscreen.test/")),
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

    func testDelayedRuntimeConfigFromPreviousClientCannotOverwriteReconfiguration() async throws {
        let firstConfig = RuntimeConfigLatch()
        BugScreenSDK.configureForTesting(
            apiKey: TestHelpers.validAPIKey,
            baseURL: try XCTUnwrap(URL(string: "https://stub-a.bugscreen.test/")),
            session: StubURLProtocol.makeSession(),
            runtimeConfigLoader: { _ in await firstConfig.wait() }
        )
        await Task.yield()

        BugScreenSDK.configureForTesting(
            apiKey: TestHelpers.validAPIKey,
            baseURL: try XCTUnwrap(URL(string: "https://stub-b.bugscreen.test/")),
            session: StubURLProtocol.makeSession(),
            runtimeConfigLoader: { _ in
                ResolvedSdkConfig(
                    showBranding: false,
                    reportTypes: ["Question", "Suggestion"],
                    severityEnabled: false,
                    copy: ReporterCopy(title: "New app", successMessage: "New acknowledgement")
                )
            }
        )
        await Task.yield()
        await firstConfig.release(
            ResolvedSdkConfig(showBranding: true, reportTypes: ["Old"], copy: ReporterCopy(title: "Old app"))
        )
        await Task.yield()

        XCTAssertEqual(BugScreenSDK.reportTypes, ["Question", "Suggestion"])
        XCTAssertFalse(BugScreenSDK.showBranding)
        XCTAssertFalse(BugScreenSDK.severityEnabled)
        guard case let .ready(configuration) = await BugScreenSDK.loadReporterConfiguration(forceRefresh: false) else {
            return XCTFail("Expected the new app's configured reporter")
        }
        XCTAssertEqual(configuration.copy.title, "New app")
        XCTAssertEqual(configuration.copy.successMessage, "New acknowledgement")
    }
}

private actor RuntimeConfigLatch {
    private var continuation: CheckedContinuation<ResolvedSdkConfig, Never>?
    private var bufferedValue: ResolvedSdkConfig?

    func wait() async -> ResolvedSdkConfig {
        if let bufferedValue {
            return bufferedValue
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ value: ResolvedSdkConfig) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: value)
        } else {
            bufferedValue = value
        }
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
private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
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
