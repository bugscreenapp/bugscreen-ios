@testable import BugScreenSDK
import UIKit
import XCTest

/// What the hosting controller attaches on the way in. The SDK passes at most one screenshot; the
/// companion app passes everything the tester shared into the share sheet (COMP-004), so the
/// fan-out from `screenshots:` into the view model is the seam both hosts depend on.
@MainActor
final class BugReportHostingControllerTests: XCTestCase {
    func testEveryScreenshotPassedInIsAttached_inOrder() {
        let images = (0 ..< 3).map { _ in TestHelpers.solidImage() }
        let controller = makeController(screenshots: images)

        XCTAssertEqual(controller.viewModel.screenshots.count, 3)
        for (attached, supplied) in zip(controller.viewModel.screenshots, images) {
            XCTAssertIdentical(attached, supplied)
        }
    }

    /// A share of more images than the reporter can take is truncated rather than refused — the
    /// tester has already been told what would be dropped before it gets this far.
    func testMoreScreenshotsThanTheLimitAreTruncated() {
        let images = (0 ..< 9).map { _ in TestHelpers.solidImage() }
        let controller = makeController(screenshots: images)

        XCTAssertEqual(controller.viewModel.screenshots.count, BugReportViewModel.maxScreenshots)
    }

    func testNoScreenshotsAttachesNothing() {
        let controller = makeController(screenshots: [])

        XCTAssertTrue(controller.viewModel.screenshots.isEmpty)
    }

    /// The SDK's single screenshot is its window-snapshot fallback, which the higher-quality OS
    /// screenshot replaces rather than sitting beside. Routing it through `screenshots:` must not
    /// have cost it that — otherwise the tester sees the same screen attached twice.
    func testSingleScreenshotWithAutoAttachIsStillUpgradedInPlace() async {
        let upgrade = TestHelpers.solidImage()
        let controller = makeController(
            screenshots: [TestHelpers.solidImage()],
            autoAttach: true,
            permission: FakePhotosPermission(outcome: .authorized),
            locator: FakeScreenshotLocator(result: upgrade)
        )

        controller.viewModel.onAppear(presenter: UIViewController())
        await flushMainTasks()

        XCTAssertEqual(controller.viewModel.screenshots.count, 1)
        XCTAssertIdentical(controller.viewModel.screenshots.first, upgrade)
    }

    private func makeController(
        screenshots: [UIImage],
        autoAttach: Bool = false,
        permission: PhotosPermissionRequesting = FakePhotosPermission(outcome: .denied),
        locator: ScreenshotLocating = FakeScreenshotLocator(result: nil)
    ) -> BugReportHostingController {
        BugReportHostingController(
            host: ReporterHost(
                submitter: FakeBugReportSubmitter(),
                photosPermission: permission,
                screenshotLocator: locator,
                showBranding: false
            ),
            screenshots: screenshots,
            autoAttach: autoAttach
        )
    }

    private func flushMainTasks(times: Int = 8) async {
        for _ in 0 ..< times {
            await Task.yield()
        }
    }
}

// MARK: - Fakes

private final class FakeBugReportSubmitter: BugReportSubmitting {
    func submitBugReport(
        description _: String,
        screenshots _: [PreparedScreenshot],
        type _: String?,
        severity _: String?
    ) async throws -> ReportReceipt {
        ReportReceipt(partialFailures: [])
    }
}

private final class FakePhotosPermission: PhotosPermissionRequesting {
    private let outcome: PhotosPermissionCoordinator.Outcome

    init(outcome: PhotosPermissionCoordinator.Outcome) {
        self.outcome = outcome
    }

    @MainActor
    func ensureAccess(
        presenter _: UIViewController,
        completion: @escaping (PhotosPermissionCoordinator.Outcome) -> Void
    ) {
        completion(outcome)
    }
}

private final class FakeScreenshotLocator: ScreenshotLocating {
    private let result: UIImage?

    init(result: UIImage?) {
        self.result = result
    }

    func findLatestScreenshot(
        since _: Date,
        completion: @escaping (UIImage?) -> Void
    ) {
        completion(result)
    }
}
