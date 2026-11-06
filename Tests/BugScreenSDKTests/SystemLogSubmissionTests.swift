@testable import BugScreenSDK
import UIKit
import XCTest

@MainActor
final class SystemLogSubmissionTests: XCTestCase {
    private let baseURL = URL(string: "https://system-logs.bugscreen.test")!

    override func tearDown() {
        BugScreenSDK.shutdown()
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testCustomAndSystemLogsHaveIndependentMultipartFiles() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("custom marker".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let body = try await send(systemLogs: makeSystemLogSnapshot(), logFile: file)
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(text.contains("name=\"logFile\"; filename=\"logs.txt\""))
        XCTAssertTrue(text.contains("name=\"systemLogFile\"; filename=\"system-logs.txt\""))
        XCTAssertTrue(text.contains("custom marker"))
        XCTAssertTrue(text.contains("native marker"))
    }

    func testExactMultipartBudgetIncludesUnicodeFieldsHeadersAndClosingBoundary() async throws {
        let baseline = try await send()
        let snapshot = makeSystemLogSnapshot(records: ["old marker\n", "🧪newest marker\n"])
        let systemFraming = "--Boundary-\(String(repeating: "0", count: 36))\r\n"
            + "Content-Disposition: form-data; name=\"systemLogFile\"; filename=\"system-logs.txt\"\r\n"
            + "Content-Type: text/plain\r\n\r\n"
        let payloadBytes = "🧪newest marker\n".utf8.count
        let screenshotBytes = APIClient.systemLogBodyBudget - baseline.count - systemFraming.utf8.count - 2 - payloadBytes
        let body = try await send(screenshotBytes: screenshotBytes, systemLogs: snapshot)
        XCTAssertEqual(body.count, APIClient.systemLogBodyBudget)
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertTrue(text.contains("🧪newest marker\n"))
        XCTAssertFalse(text.contains("old marker\n"))
        XCTAssertFalse(text.contains("BugScreen system logs"))
        XCTAssertTrue(text.contains("unicode 🧪 description"))
        XCTAssertTrue(text.contains("field 日本語"))
    }

    func testFullAndAlreadyOversizedReportsOmitSystemLogsWithoutReducingOtherEvidence() async throws {
        let baseline = try await send()
        for excess in [0, 17] {
            let screenshotBytes = APIClient.systemLogBodyBudget - baseline.count + excess
            let body = try await send(screenshotBytes: screenshotBytes, systemLogs: makeSystemLogSnapshot())
            XCTAssertEqual(body.count, APIClient.systemLogBodyBudget + excess)
            XCTAssertFalse(try XCTUnwrap(String(data: body, encoding: .utf8)).contains("systemLogFile"))
        }
    }

    func testDisabledCaptureNeverInvokesCollectorAndCustomLogsStillSubmit() async throws {
        installSuccess()
        BugScreenSDK.configureForTesting(apiKey: TestHelpers.validAPIKey, baseURL: baseURL, session: StubURLProtocol.makeSession())
        BugScreenSDK.logger?.log("custom marker", level: .info)
        var attempts = 0
        let submitter = DefaultBugReportSubmitter(captureForTesting: { _, _ in
            attempts += 1
            return makeSystemLogSnapshot()
        })
        _ = try await submitter.submitBugReport(description: "test", screenshots: [], type: nil, severity: nil)
        XCTAssertEqual(attempts, 0)
        let text = try XCTUnwrap(String(data: try XCTUnwrap(StubURLProtocol.recordedBodies.last), encoding: .utf8))
        XCTAssertTrue(text.contains("custom marker"))
        XCTAssertFalse(text.contains("systemLogFile"))
    }

    func testEnabledCaptureSubmitsBothLogSourcesThroughSubmitter() async throws {
        installSuccess()
        BugScreenSDK.configureForTesting(apiKey: TestHelpers.validAPIKey, baseURL: baseURL,
                                         session: StubURLProtocol.makeSession(), captureSystemLogs: true)
        BugScreenSDK.logger?.log("custom submitter marker", level: .info)
        var attempts = 0
        let submitter = DefaultBugReportSubmitter(captureForTesting: { lifetime, _ in
            attempts += 1
            return makeSystemLogSnapshot(lifetime: lifetime, records: ["system submitter marker\n"])
        })

        _ = try await submitter.submitBugReport(description: "test", screenshots: [], type: nil, severity: nil)

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(StubURLProtocol.recordedRequests.last?.url?.path, "/reports")
        let body = try XCTUnwrap(String(data: try XCTUnwrap(StubURLProtocol.recordedBodies.last), encoding: .utf8))
        XCTAssertTrue(body.contains("name=\"logFile\"; filename=\"logs.txt\""))
        XCTAssertTrue(body.contains("name=\"systemLogFile\"; filename=\"system-logs.txt\""))
        XCTAssertTrue(body.contains("custom submitter marker"))
        XCTAssertTrue(body.contains("system submitter marker"))
    }

    func testReporterStartsCaptureBeforeSubmissionAndReusesOpeningSnapshotOnRetry() async throws {
        installSuccess()
        BugScreenSDK.configureForTesting(apiKey: TestHelpers.validAPIKey, baseURL: baseURL,
                                         session: StubURLProtocol.makeSession(), captureSystemLogs: true)
        var cutoffs: [Date] = []
        let openedBefore = Date()
        let submitter = DefaultBugReportSubmitter(captureForTesting: { lifetime, cutoff in
            cutoffs.append(cutoff)
            return makeSystemLogSnapshot(lifetime: lifetime)
        })
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertEqual(cutoffs.count, 1, "Opening the reporter must start capture before Submit")
        let submittingAt = Date()
        _ = try await submitter.submitBugReport(description: "first attempt", screenshots: [], type: nil, severity: nil)
        _ = try await submitter.submitBugReport(description: "retry", screenshots: [], type: nil, severity: nil)
        XCTAssertEqual(cutoffs.count, 1, "Retries must reuse the same capture")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(cutoffs.first), openedBefore)
        XCTAssertLessThanOrEqual(try XCTUnwrap(cutoffs.first), submittingAt)
    }

    func testUnavailableCaptureStillSubmitsCustomLogs() async throws {
        installSuccess()
        BugScreenSDK.configureForTesting(apiKey: TestHelpers.validAPIKey, baseURL: baseURL,
                                         session: StubURLProtocol.makeSession(), captureSystemLogs: true)
        BugScreenSDK.logger?.log("survives unavailable capture", level: .info)
        let submitter = DefaultBugReportSubmitter(captureForTesting: { _, _ in nil })
        _ = try await submitter.submitBugReport(description: "test", screenshots: [], type: nil, severity: nil)
        let text = try XCTUnwrap(String(data: try XCTUnwrap(StubURLProtocol.recordedBodies.last), encoding: .utf8))
        XCTAssertTrue(text.contains("survives unavailable capture"))
        XCTAssertFalse(text.contains("systemLogFile"))
    }

    func testReconfigurationWhileCapturingDropsOldSnapshotAndRetainsOriginalClient() async throws {
        installSuccess()
        BugScreenSDK.configureForTesting(apiKey: "fb_old_config_123456", baseURL: baseURL,
                                         session: StubURLProtocol.makeSession(), captureSystemLogs: true)
        let submitter = DefaultBugReportSubmitter(captureForTesting: { [baseURL] lifetime, _ in
            BugScreenSDK.configureForTesting(apiKey: "fb_new_config_123456", baseURL: baseURL,
                                             session: StubURLProtocol.makeSession(), captureSystemLogs: true)
            return makeSystemLogSnapshot(lifetime: lifetime)
        })
        _ = try await submitter.submitBugReport(description: "test", screenshots: [], type: nil, severity: nil)
        let request = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fb_old_config_123456")
        XCTAssertFalse(try XCTUnwrap(String(data: try XCTUnwrap(StubURLProtocol.recordedBodies.last), encoding: .utf8))
            .contains("systemLogFile"))
    }

    func testStaleReporterCannotUploadReplacementConfigurationEvidenceEvenWithCaptureDisabled() async throws {
        for enabled in [false, true] {
            installSuccess()
            BugScreenSDK.configureForTesting(apiKey: "fb_original_app_key", baseURL: baseURL,
                                             session: StubURLProtocol.makeSession(), captureSystemLogs: enabled)
            let submitter = DefaultBugReportSubmitter(captureForTesting: { _, _ in nil })
            BugScreenSDK.configureForTesting(apiKey: "fb_replacement_app_key", baseURL: baseURL,
                                             session: StubURLProtocol.makeSession())
            BugScreenSDK.logger?.log("replacement private log", level: .info)
            BugScreenSDK.setCustomData(["account": "replacement private account"])
            do {
                _ = try await submitter.submitBugReport(description: "old draft", screenshots: [], type: nil, severity: nil)
                XCTFail("A stale reporter must fail before uploading evidence")
            } catch BugScreenSDKError.notConfigured {} catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        }
    }

    func testSDKReporterDismissalInvalidatesReadyEvidenceWhileSubmitterIsRetained() async throws {
        try await assertSDKReporterDismissalDiscardsEvidence(pending: false)
    }

    func testSDKReporterDismissalInvalidatesPendingEvidenceAndDropsLateOutput() async throws {
        try await assertSDKReporterDismissalDiscardsEvidence(pending: true)
    }

    private func assertSDKReporterDismissalDiscardsEvidence(pending: Bool) async throws {
        installSuccess()
        BugScreenSDK.configureForTesting(apiKey: TestHelpers.validAPIKey, baseURL: baseURL,
                                         session: StubURLProtocol.makeSession(), captureSystemLogs: true)
        var lifetime: SystemLogLifetime?
        var finish: CheckedContinuation<SystemLogSnapshot?, Never>?
        let started = expectation(description: "capture started")
        let submitter = DefaultBugReportSubmitter(captureForTesting: { active, _ in
            lifetime = active
            started.fulfill()
            if pending { return await withCheckedContinuation { finish = $0 } }
            return makeSystemLogSnapshot(lifetime: active)
        })
        let controller = BugScreenSDK.makeBugReportController(submitter: submitter, screenshot: nil, autoAttach: false)
        await fulfillment(of: [started], timeout: 1)
        let capturedLifetime = try XCTUnwrap(lifetime)
        XCTAssertTrue(capturedLifetime.isActive)
        controller.dismissFromHost()
        XCTAssertFalse(capturedLifetime.isActive, "The SDK controller's dismissal must invalidate its report")
        finish?.resume(returning: makeSystemLogSnapshot(lifetime: capturedLifetime))
        _ = try await submitter.submitBugReport(description: "retained submitter", screenshots: [], type: nil, severity: nil)
        let body = try XCTUnwrap(String(data: try XCTUnwrap(StubURLProtocol.recordedBodies.last), encoding: .utf8))
        XCTAssertFalse(body.contains("systemLogFile"))
    }

    func testSnapshotInvalidatedDuringVideoUploadIsNotAttached() async throws {
        StubURLProtocol.reset()
        let snapshot = makeSystemLogSnapshot()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("video-content".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        StubURLProtocol.handler = { request in
            let value: [String: Any]
            let status: Int
            if request.url!.path == "/reports" {
                value = ["success": true, "message": "ok", "issueUrls": []]
                status = 201
            } else if request.url!.path.hasSuffix("/complete") {
                snapshot.lifetime.invalidate()
                value = ["uploadId": "video-1", "expiresAt": "2099-01-01T00:00:00.000Z"]
                status = 200
            } else if request.url!.host == "storage.test" {
                value = [:]
                status = 204
            } else {
                value = ["uploadId": "video-1", "upload": ["url": "https://storage.test/", "fields": ["key": "video"]]]
                status = 200
            }
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                    try JSONSerialization.data(withJSONObject: value))
        }
        let session = StubURLProtocol.makeSession()
        let uploader = VideoUploadClient(baseURL: baseURL, headers: [:], session: session, storage: session)
        let client = APIClient(apiKey: TestHelpers.validAPIKey, baseURL: baseURL, session: session, videoUploader: uploader)
        _ = try await client.submitBugReport(description: "test", metadata: [:],
                                             videos: [PreparedVideo(file: file, poster: UIImage(), durationSeconds: 1)],
                                             visualOrder: [ReportMediaOrder(isVideo: true, index: 0)], systemLogs: snapshot)
        let body = try XCTUnwrap(String(data: try XCTUnwrap(StubURLProtocol.recordedBodies.last), encoding: .utf8))
        XCTAssertTrue(body.contains("visualAttachments"))
        XCTAssertFalse(body.contains("systemLogFile"))
    }

    func testSnapshotInvalidatedAfterEncodingIsRemovedBeforeSending() async throws {
        installSuccess()
        let snapshot = makeSystemLogSnapshot()
        let client = APIClient(apiKey: TestHelpers.validAPIKey, baseURL: baseURL, session: StubURLProtocol.makeSession())
        client.multipartBodyPreparedForTesting = { snapshot.lifetime.invalidate() }
        _ = try await client.submitBugReport(description: "retained report", metadata: [:], systemLogs: snapshot)
        let body = try XCTUnwrap(String(data: try XCTUnwrap(StubURLProtocol.recordedBodies.last), encoding: .utf8))
        XCTAssertTrue(body.contains("retained report"))
        XCTAssertFalse(body.contains("systemLogFile"))
    }

    func testCancellationAfterDetachedEncodingPreventsNetworkRequest() async throws {
        installSuccess()
        let client = APIClient(apiKey: TestHelpers.validAPIKey, baseURL: baseURL, session: StubURLProtocol.makeSession())
        client.multipartBodyPreparedForTesting = { withUnsafeCurrentTask { $0?.cancel() } }
        let submission = Task {
            try await client.submitBugReport(description: "cancelled report", metadata: [:], systemLogs: makeSystemLogSnapshot())
        }
        do {
            _ = try await submission.value
            XCTFail("Expected cancellation after encoding")
        } catch is CancellationError {} catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    private func send(screenshotBytes: Int = 0, systemLogs: SystemLogSnapshot? = nil, logFile: URL? = nil) async throws -> Data {
        installSuccess()
        let client = APIClient(apiKey: TestHelpers.validAPIKey, baseURL: baseURL, session: StubURLProtocol.makeSession())
        let screenshot = PreparedScreenshot(
            data: Data(repeating: 120, count: screenshotBytes),
            contentType: "image/jpeg",
            fileExtension: "jpg"
        )
        _ = try await client.submitBugReport(description: "unicode 🧪 description", metadata: ["device": "field 日本語"],
                                             screenshots: [screenshot], type: "Bug", severity: "low", logFile: logFile,
                                             systemLogs: systemLogs)
        return try XCTUnwrap(StubURLProtocol.recordedBodies.last)
    }

    private func installSuccess() {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
             Data("{\"success\":true,\"message\":\"ok\",\"issueUrls\":[]}".utf8))
        }
    }
}
