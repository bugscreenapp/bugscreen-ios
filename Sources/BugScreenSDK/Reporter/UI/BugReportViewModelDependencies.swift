import Foundation
import UIKit

/// What the reporter needs from whoever is hosting it.
///
/// `BugScreenSDK` supplies an implementation backed by the app API key and the SDK's own
/// metadata collection; the BugScreen companion app supplies one backed by a device
/// credential and metadata with no app-under-test context (RFC-003 §1). The reporter
/// itself knows about neither, which is what lets both embed the same form instead of
/// forking it.
///
/// Everything under `Reporter/` is `internal` and stays that way. The companion app does
/// not import this module — it compiles this directory into its own target (RFC-003
/// §2.5), so the seam never has to cross a module boundary and never becomes SDK API.
/// `scripts/check-reporter-boundary.sh` is what holds the other half of that bargain: it
/// type-checks this directory on its own, so a file here reaching back into the SDK fails
/// in CI rather than in the companion's build.
protocol BugReportSubmitting {
    @MainActor
    func submitBugReport(
        description: String,
        screenshots: [PreparedScreenshot],
        type: String?,
        severity: String?
    ) async throws -> ReportReceipt
}

protocol PhotosPermissionRequesting {
    @MainActor
    func ensureAccess(
        presenter: UIViewController,
        completion: @escaping (PhotosPermissionCoordinator.Outcome) -> Void
    )
}

protocol ScreenshotLocating {
    func findLatestScreenshot(
        since: Date,
        completion: @escaping (UIImage?) -> Void
    )
}

/// What the backend made of a submitted report.
///
/// Deliberately the reporter's own type rather than the SDK's `BugReportResponse`, which
/// is a wire type belonging to the transport — the one layer a host replaces. The
/// companion app has no `BugReportResponse` at all, so a reporter that named it could not
/// be shared. Each host maps across instead.
struct ReportReceipt: Sendable {
    let partialFailures: [ReportPartialFailure]
}

/// One provider that did not receive the report, for the partial-failure disclosure.
struct ReportPartialFailure: Sendable {
    let type: String
    let message: String
}

/// Everything the reporter is handed when it is presented.
///
/// One value rather than four loose parameters so a host adds a capability in one place,
/// and so the two shells (SDK and companion) stay structurally alike.
struct ReporterHost {
    let submitter: BugReportSubmitting
    let photosPermission: PhotosPermissionRequesting
    let screenshotLocator: ScreenshotLocating

    /// Whether to show the BugScreen wordmark. Fail-safe `false` when unknown (CAP-010).
    let showBranding: Bool

    init(
        submitter: BugReportSubmitting,
        photosPermission: PhotosPermissionRequesting = DefaultPhotosPermissionRequester(),
        screenshotLocator: ScreenshotLocating = DefaultScreenshotLocator(),
        showBranding: Bool
    ) {
        self.submitter = submitter
        self.photosPermission = photosPermission
        self.screenshotLocator = screenshotLocator
        self.showBranding = showBranding
    }
}

/// Backed by `PhotosPermissionCoordinator`, which moved here with the reporter — it has
/// no dependency on the SDK, so it travels with the protocol it implements.
struct DefaultPhotosPermissionRequester: PhotosPermissionRequesting {
    @MainActor
    func ensureAccess(
        presenter: UIViewController,
        completion: @escaping (PhotosPermissionCoordinator.Outcome) -> Void
    ) {
        PhotosPermissionCoordinator.ensureAccess(presenter: presenter, completion: completion)
    }
}

struct DefaultScreenshotLocator: ScreenshotLocating {
    func findLatestScreenshot(
        since: Date,
        completion: @escaping (UIImage?) -> Void
    ) {
        ScreenshotLocator.findLatestScreenshot(since: since, completion: completion)
    }
}
