@testable import BugScreenSDK
import CryptoKit
import UIKit
import XCTest

final class VideoUploadClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset(); super.tearDown()
    }

    func testFileBackedUploadHasNoCredentialsAndManualRetryReusesReadyReference() async throws {
        StubURLProtocol.reset()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data("video-content".utf8)
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = "upload-1"
        StubURLProtocol.handler = { request in
            let value: [String: Any]
            if request.url!.host == "private.storage.test" {
                value = [:]
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertNil(request.value(forHTTPHeaderField: "X-BugScreen-SDK-Version"))
            } else if request.url!.path.hasSuffix("/complete") {
                value = ["uploadId": id, "expiresAt": "2099-01-01T00:00:00.000Z"]
            } else {
                value = [
                    "uploadId": id,
                    "upload": ["url": "https://private.storage.test/", "fields": ["key": "raw/video", "Policy": "private-policy"]],
                ]
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                try JSONSerialization.data(withJSONObject: value)
            )
        }
        let client = VideoUploadClient(
            baseURL: try XCTUnwrap(URL(string: "https://api.bugscreen.test/")),
            headers: ["Authorization": "Bearer secret"],
            session: StubURLProtocol.makeSession(),
            storage: StubURLProtocol.makeSession()
        )
        let video = PreparedVideo(file: file, poster: UIImage(), durationSeconds: 1)
        let order = [ReportMediaOrder(isVideo: false, index: 0), ReportMediaOrder(isVideo: true, index: 0)]
        let first = try await client.references(videos: [video], order: order)
        let refs = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.utf8)) as? [[String: Any]])
        XCTAssertEqual(refs[0]["kind"] as? String, "screenshot")
        XCTAssertEqual(refs[1]["uploadId"] as? String, id)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 3)
        let grantBody = try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.recordedBodies[0]) as? [String: Any])
        XCTAssertEqual(grantBody["sha256"] as? String, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let uploadBody = try XCTUnwrap(String(data: StubURLProtocol.recordedBodies[1], encoding: .utf8))
        XCTAssertTrue(uploadBody.contains("private-policy"))
        XCTAssertTrue(uploadBody.contains("video-content"))
        let second = try await client.references(videos: [video], order: order)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(first.utf8)) as? NSArray,
            try JSONSerialization.jsonObject(with: Data(second.utf8)) as? NSArray
        )
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 3)
    }

    @MainActor
    func testFailuresBlockFinalReportAndManualRetryRetainsSelectionAndReplacesConsumedReferences() async throws {
        for failure in ["grant", "storage", "complete", "report", "report-expired"] {
            StubURLProtocol.reset()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("video-content".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            var stage = failure
            var grants = 0
            StubURLProtocol.handler = { request in
                var value: [String: Any] = [:]
                var status = 200
                if request.url!.host == "private.storage.test" {
                    status = stage == "storage" ? 503 : 204
                } else if request.url!.path == "/report-uploads" {
                    grants += 1
                    status = stage == "grant" ? 429 : 200
                    value = [
                        "uploadId": "upload-\(grants)",
                        "upload": ["url": "https://private.storage.test/", "fields": ["key": "raw/video"]],
                    ]
                } else if request.url!.path.hasSuffix("/complete") {
                    status = stage == "complete" ? 400 : 200
                    value = [
                        "uploadId": "upload-\(grants)",
                        "expiresAt": "\(stage == "report-expired" ? "2000" : "2099")-01-01T00:00:00.000Z",
                    ]
                } else if request.url!.path == "/reports" {
                    status = stage.hasPrefix("report") ? 500 : 201
                    value = ["success": true, "message": "ok", "issueUrls": []]
                }
                return (
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                    try JSONSerialization.data(withJSONObject: value)
                )
            }
            let base = try XCTUnwrap(URL(string: "https://api.bugscreen.test/"))
            let session = StubURLProtocol.makeSession()
            let uploader = VideoUploadClient(
                baseURL: base,
                headers: ["Authorization": "Bearer secret"],
                session: session,
                storage: StubURLProtocol.makeSession()
            )
            let client = APIClient(apiKey: "secret", baseURL: base, session: session, videoUploader: uploader)
            let videos = [PreparedVideo(file: file, poster: UIImage(), durationSeconds: 1)]
            let order = [ReportMediaOrder(isVideo: true, index: 0)]
            let description = "Original retained description"
            do {
                _ = try await client.submitBugReport(description: description, metadata: [:], videos: videos, visualOrder: order)
                XCTFail("Expected failure for \(failure)")
            } catch {}
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            XCTAssertEqual(
                StubURLProtocol.recordedRequests.filter { $0.url!.path == "/reports" }.count,
                failure.hasPrefix("report") ? 1 : 0
            )
            stage = ""
            _ = try await client.submitBugReport(description: description, metadata: [:], videos: videos, visualOrder: order)
            XCTAssertEqual(grants, failure == "report" ? 1 : 2)
            let reportIndex = try XCTUnwrap(StubURLProtocol.recordedRequests.lastIndex { $0.url!.path == "/reports" })
            let report = try XCTUnwrap(String(data: StubURLProtocol.recordedBodies[reportIndex], encoding: .utf8))
            XCTAssertTrue(report.contains(description))
            XCTAssertTrue(report.contains("visualAttachments"))
            XCTAssertFalse(report.contains("name=\"screenshot\""))
            let before = grants
            _ = try await client.submitBugReport(description: description, metadata: [:], videos: videos, visualOrder: order)
            XCTAssertEqual(grants, before + 1)
        }
    }
}
