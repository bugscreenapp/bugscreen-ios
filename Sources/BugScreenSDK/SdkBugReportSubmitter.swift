import Foundation
import UIKit

/// The SDK's side of the reporter seam (RFC-003 §2).
///
/// This is what keeps the extraction invisible: the reporter module knows nothing about
/// API keys, `APIClient` or `BugScreenSDK`, and everything it used to reach back for
/// arrives through here. The companion app supplies its own implementation, backed by a
/// device credential and metadata with no app-under-test context — same reporter,
/// different host.
@MainActor
final class DefaultBugReportSubmitter: VideoReportSubmitting {
    private let apiClient: APIClient?
    private let systemLogs: SystemLogReport?
    private let capturedMetadata: BugReportMetadata?

    init(client: APIClient? = nil, capturedMetadata: BugReportMetadata? = nil) {
        self.capturedMetadata = capturedMetadata
        apiClient = client ?? BugScreenSDK.apiClient
        systemLogs = Self.prepareSystemLogs { lifetime, cutoff in
            await SystemLogCapture.shared.capture(lifetime: lifetime, capturedAt: cutoff)
        }
    }

    #if DEBUG
        init(captureForTesting: @escaping SystemLogReport.Capture) {
            capturedMetadata = nil
            apiClient = BugScreenSDK.apiClient
            systemLogs = Self.prepareSystemLogs(capture: captureForTesting)
        }
    #endif

    private static func prepareSystemLogs(capture: @escaping SystemLogReport.Capture) -> SystemLogReport? {
        guard let configuration = BugScreenSDK.configuration, configuration.captureSystemLogs else { return nil }
        return SystemLogReport(lifetime: configuration.systemLogLifetime, capture: capture)
    }

    static func currentMetadata() -> BugReportMetadata {
        let customData = BugScreenSDK.resolveReportCustomData()
        return MetadataCollector.collect(customData: customData.isEmpty ? nil : customData)
    }

    func discard() {
        systemLogs?.discard()
    }

    @MainActor
    func submitVideoBugReport(description: String, screenshots: [PreparedScreenshot], videos: [PreparedVideo],
                              visualOrder: [ReportMediaOrder], type: String?, severity: String?) async throws -> ReportReceipt
    {
        guard let apiClient, apiClient === BugScreenSDK.apiClient else {
            discard()
            throw BugScreenSDKError.notConfigured
        }
        let metadata = capturedMetadata ?? Self.currentMetadata()
        let logFile = BugScreenSDK.logger?.exportToFile()
        defer { if let logFile { try? FileManager.default.removeItem(at: logFile) } }
        let snapshot = await systemLogs?.snapshot()
        try Task.checkCancellation()
        let response = try await apiClient.submitBugReport(description: description, metadata: metadata, screenshots: screenshots,
                                                           type: type, severity: severity, logFile: logFile, videos: videos,
                                                           visualOrder: visualOrder, systemLogs: snapshot)
        return ReportReceipt(partialFailures: (response.partialFailures ?? [])
            .map { ReportPartialFailure(type: $0.type, message: $0.message) })
    }

    @MainActor
    func submitBugReport(
        description: String,
        screenshots: [PreparedScreenshot],
        type: String?,
        severity: String?
    ) async throws -> ReportReceipt {
        try await submitVideoBugReport(
            description: description,
            screenshots: screenshots,
            videos: [],
            visualOrder: [],
            type: type,
            severity: severity
        )
    }
}
