import Foundation
import UIKit

/// Submits a bug report through the SDK. The production adapter calls the
/// internal `APIClient`; tests provide a fake so the view model can be
/// exercised without configuring the SDK.
internal protocol BugReportSubmitting {
    func submitBugReport(
        description: String,
        screenshot: UIImage?
    ) async throws -> BugReportResponse
}

/// Requests photo-library access, presenting a rationale if needed. The
/// production adapter forwards to `PhotosPermissionCoordinator.ensureAccess`.
/// Callers invoke this on the main actor.
internal protocol PhotosPermissionRequesting {
    @MainActor
    func ensureAccess(
        presenter: UIViewController,
        completion: @escaping (PhotosPermissionCoordinator.Outcome) -> Void
    )
}

/// Locates the user's most recent screenshot from the photo library. The
/// production adapter forwards to `ScreenshotLocator.findLatestScreenshot`.
/// Implementations must invoke `completion` on the main queue.
internal protocol ScreenshotLocating {
    func findLatestScreenshot(
        since: Date,
        completion: @escaping (UIImage?) -> Void
    )
}

// MARK: - Production adapters

internal struct DefaultBugReportSubmitter: BugReportSubmitting {
    func submitBugReport(
        description: String,
        screenshot: UIImage?
    ) async throws -> BugReportResponse {
        guard let apiClient = BugScreenSDK.apiClient else {
            throw BugScreenSDKError.notConfigured
        }

        let metadata = MetadataCollector.collect()
        let logFile = BugScreenSDK.logger?.exportToFile()

        let response = try await apiClient.submitBugReport(
            description: description,
            metadata: metadata,
            screenshot: screenshot,
            logFile: logFile
        )

        if let logFile = logFile {
            try? FileManager.default.removeItem(at: logFile)
        }

        return response
    }
}

@available(iOS 15.0, *)
internal struct DefaultPhotosPermissionRequester: PhotosPermissionRequesting {
    @MainActor
    func ensureAccess(
        presenter: UIViewController,
        completion: @escaping (PhotosPermissionCoordinator.Outcome) -> Void
    ) {
        PhotosPermissionCoordinator.ensureAccess(presenter: presenter, completion: completion)
    }
}

@available(iOS 15.0, *)
internal struct DefaultScreenshotLocator: ScreenshotLocating {
    func findLatestScreenshot(
        since: Date,
        completion: @escaping (UIImage?) -> Void
    ) {
        ScreenshotLocator.findLatestScreenshot(since: since, completion: completion)
    }
}
