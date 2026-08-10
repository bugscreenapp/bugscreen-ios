import Foundation
import UIKit

/// The SDK's side of the reporter seam (RFC-003 §2).
///
/// This is what keeps the extraction invisible: the reporter module knows nothing about
/// API keys, `APIClient` or `BugScreenSDK`, and everything it used to reach back for
/// arrives through here. The companion app supplies its own implementation, backed by a
/// device credential and metadata with no app-under-test context — same reporter,
/// different host.
struct DefaultBugReportSubmitter: BugReportSubmitting {
    @MainActor
    func submitBugReport(
        description: String,
        screenshots: [PreparedScreenshot],
        type: String?,
        severity: String?
    ) async throws -> ReportReceipt {
        guard let apiClient = BugScreenSDK.apiClient else {
            throw BugScreenSDKError.notConfigured
        }

        let customData = BugScreenSDK.resolveReportCustomData()
        let metadata = MetadataCollector.collect(
            customData: customData.isEmpty ? nil : customData
        )
        let logFile = BugScreenSDK.logger?.exportToFile()

        let response = try await apiClient.submitBugReport(
            description: description,
            metadata: metadata,
            screenshots: screenshots,
            type: type,
            severity: severity,
            logFile: logFile
        )

        if let logFile {
            try? FileManager.default.removeItem(at: logFile)
        }

        // BugReportResponse is public and pinned in api/BugScreenSDK.api.json, so it stays
        // here and the mapping to the reporter's own type happens on this side of the seam.
        return ReportReceipt(
            partialFailures: (response.partialFailures ?? []).map {
                ReportPartialFailure(type: $0.type, message: $0.message)
            }
        )
    }
}
