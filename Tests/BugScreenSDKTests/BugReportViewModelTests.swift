@testable import BugScreenSDK
import UIKit
import XCTest

@MainActor
final class BugReportViewModelTests: XCTestCase {
    // MARK: - Auto-attach

    func testAutoAttachWhenAuthorizedAppendsScreenshot() async {
        let image = TestHelpers.solidImage()
        let permission = FakePhotosPermission(outcome: .authorized)
        let locator = FakeScreenshotLocator(result: image)
        let viewModel = makeViewModel(
            autoAttach: true,
            permission: permission,
            locator: locator
        )

        viewModel.onAppear(presenter: UIViewController())
        await flushMainTasks()

        XCTAssertEqual(permission.invocationCount, 1)
        XCTAssertEqual(locator.invocationCount, 1)
        XCTAssertEqual(viewModel.screenshots.count, 1)
    }

    func testAutoAttachOnlyRunsOncePerPresentation() async {
        let permission = FakePhotosPermission(outcome: .authorized)
        let locator = FakeScreenshotLocator(result: TestHelpers.solidImage())
        let viewModel = makeViewModel(
            autoAttach: true,
            permission: permission,
            locator: locator
        )

        viewModel.onAppear(presenter: UIViewController())
        viewModel.onAppear(presenter: UIViewController())
        await flushMainTasks()

        XCTAssertEqual(permission.invocationCount, 1)
        XCTAssertEqual(locator.invocationCount, 1)
    }

    func testAutoAttachDeniedLeavesScreenshotsEmpty() async {
        let permission = FakePhotosPermission(outcome: .denied)
        let locator = FakeScreenshotLocator(result: TestHelpers.solidImage())
        let viewModel = makeViewModel(
            autoAttach: true,
            permission: permission,
            locator: locator
        )

        viewModel.onAppear(presenter: UIViewController())
        await flushMainTasks()

        XCTAssertEqual(locator.invocationCount, 0)
        XCTAssertTrue(viewModel.screenshots.isEmpty)
    }

    func testAutoAttachCancelledLeavesScreenshotsEmpty() async {
        let permission = FakePhotosPermission(outcome: .cancelled)
        let locator = FakeScreenshotLocator(result: TestHelpers.solidImage())
        let viewModel = makeViewModel(
            autoAttach: true,
            permission: permission,
            locator: locator
        )

        viewModel.onAppear(presenter: UIViewController())
        await flushMainTasks()

        XCTAssertEqual(locator.invocationCount, 0)
        XCTAssertTrue(viewModel.screenshots.isEmpty)
    }

    func testAutoAttachKeepsExistingScreenshotWhenLocatorReturnsNil() async {
        let permission = FakePhotosPermission(outcome: .authorized)
        let locator = FakeScreenshotLocator(result: nil)
        let existing = TestHelpers.solidImage()
        let viewModel = makeViewModel(
            screenshot: existing,
            autoAttach: true,
            permission: permission,
            locator: locator
        )

        viewModel.onAppear(presenter: UIViewController())
        await flushMainTasks()

        XCTAssertEqual(viewModel.screenshots.count, 1)
    }

    func testAutoAttachReplacesFallbackInsteadOfAppending() async {
        // ScreenshotObserver presents the reporter with a window-snapshot
        // fallback AND autoAttach=true. The OS screenshot from Photos should
        // upgrade the fallback in-place — not double up.
        let fallback = TestHelpers.solidImage(color: .red)
        let osScreenshot = TestHelpers.solidImage(color: .blue)
        let viewModel = makeViewModel(
            screenshot: fallback,
            autoAttach: true,
            permission: FakePhotosPermission(outcome: .authorized),
            locator: FakeScreenshotLocator(result: osScreenshot)
        )

        viewModel.onAppear(presenter: UIViewController())
        await flushMainTasks()

        XCTAssertEqual(viewModel.screenshots.count, 1)
        XCTAssertTrue(viewModel.screenshots.first === osScreenshot)
    }

    func testAutoAttachAppendsWhenNoFallbackPresent() async {
        // Direct screenshot detection without a fallback (e.g. presenter
        // invoked auto-attach with `screenshot: nil`) should append the OS
        // screenshot as the first attachment.
        let osScreenshot = TestHelpers.solidImage(color: .blue)
        let viewModel = makeViewModel(
            autoAttach: true,
            permission: FakePhotosPermission(outcome: .authorized),
            locator: FakeScreenshotLocator(result: osScreenshot)
        )

        viewModel.onAppear(presenter: UIViewController())
        await flushMainTasks()

        XCTAssertEqual(viewModel.screenshots.count, 1)
        XCTAssertTrue(viewModel.screenshots.first === osScreenshot)
    }

    func testAutoAttachSkippedWhenDisabled() async {
        let permission = FakePhotosPermission(outcome: .authorized)
        let locator = FakeScreenshotLocator(result: TestHelpers.solidImage())
        let viewModel = makeViewModel(
            autoAttach: false,
            permission: permission,
            locator: locator
        )

        viewModel.onAppear(presenter: UIViewController())
        await flushMainTasks()

        XCTAssertEqual(permission.invocationCount, 0)
        XCTAssertEqual(locator.invocationCount, 0)
    }

    // MARK: - Attachments

    func testAddScreenshotsCapsAtMax() {
        let viewModel = makeViewModel()
        let images = (0 ..< 6).map { _ in TestHelpers.solidImage() }
        viewModel.addScreenshots(images)
        XCTAssertEqual(viewModel.screenshots.count, BugReportViewModel.maxScreenshots)
        XCTAssertFalse(viewModel.canAddMoreScreenshots)
    }

    func testAddScreenshotsRespectsRemainingSlots() {
        let viewModel = makeViewModel()
        viewModel.addScreenshots([TestHelpers.solidImage(), TestHelpers.solidImage()])
        viewModel.addScreenshots([TestHelpers.solidImage(), TestHelpers.solidImage(), TestHelpers.solidImage()])
        XCTAssertEqual(viewModel.screenshots.count, BugReportViewModel.maxScreenshots)
    }

    func testRemoveScreenshotByIndex() {
        let viewModel = makeViewModel()
        viewModel.addScreenshots([TestHelpers.solidImage(), TestHelpers.solidImage()])
        viewModel.removeScreenshot(at: 0)
        XCTAssertEqual(viewModel.screenshots.count, 1)
        viewModel.removeScreenshot(at: 99) // out-of-bounds is a no-op
        XCTAssertEqual(viewModel.screenshots.count, 1)
    }

    // MARK: - Submission

    func testSubmitSuccessInvokesOnSuccessNotOnDismiss() async {
        let response = BugReportResponse(
            success: true,
            message: "ok",
            issueURLs: ["https://github.com/example/repo/issues/1"],
            partialFailures: nil
        )
        let submitter = FakeBugReportSubmitter(result: .success(response))
        var dismissCount = 0
        var successCount = 0
        let viewModel = BugReportViewModel(
            onDismiss: { dismissCount += 1 },
            onSuccess: { _ in successCount += 1 },
            submitter: submitter,
            photosPermission: FakePhotosPermission(outcome: .authorized),
            screenshotLocator: FakeScreenshotLocator(result: nil)
        )
        viewModel.description = "Login button is unresponsive"

        await viewModel.submit()

        XCTAssertEqual(viewModel.submissionState, .success)
        // Hosting controller dismisses the sheet itself, then presents the
        // toast — the view model just signals success and lets the host do
        // the rest. `onDismiss` is reserved for cancel/close.
        XCTAssertEqual(successCount, 1)
        XCTAssertEqual(dismissCount, 0)
        XCTAssertNil(viewModel.lastError)
    }

    func testSubmitSurfacesPartialFailureWithOpenStringType() async {
        // bugscreen-c7e / CAP-009: a partialFailures[].type beyond the core three
        // (here "slack", a future provider) surfaces verbatim through the view model —
        // the SDK presents it rather than crashing or dropping it when a provider ships.
        let response = BugReportResponse(
            success: true,
            message: "ok",
            issueURLs: ["https://github.com/example/repo/issues/1"],
            partialFailures: [
                BugReportPartialFailure(type: "slack", message: "channel archived"),
            ]
        )
        let submitter = FakeBugReportSubmitter(result: .success(response))
        let viewModel = makeViewModel(submitter: submitter)
        viewModel.description = "Login button is unresponsive"

        await viewModel.submit()

        XCTAssertEqual(viewModel.submissionState, .success)
        XCTAssertEqual(viewModel.partialFailures.count, 1)
        XCTAssertEqual(viewModel.partialFailures.first?.type, "slack")
        XCTAssertEqual(viewModel.partialFailures.first?.message, "channel archived")
    }

    func testSubmitDefaultsTypeBugSeverityMedium() async {
        let submitter = FakeBugReportSubmitter()
        let viewModel = makeViewModel(submitter: submitter)
        viewModel.description = "default fields"

        await viewModel.submit()

        XCTAssertEqual(submitter.lastType, "bug")
        XCTAssertEqual(submitter.lastSeverity, "medium")
    }

    func testSubmitForwardsSelectedTypeAndSeverity() async {
        let submitter = FakeBugReportSubmitter()
        let viewModel = makeViewModel(submitter: submitter)
        viewModel.description = "selected fields"
        viewModel.bugType = .crash
        viewModel.severity = .high

        await viewModel.submit()

        XCTAssertEqual(submitter.lastType, "crash")
        XCTAssertEqual(submitter.lastSeverity, "high")
    }

    func testSubmitForwardsScreenshots() async {
        let submitter = FakeBugReportSubmitter()
        let viewModel = makeViewModel(submitter: submitter)
        viewModel.description = "with attachments"
        viewModel.addScreenshots([TestHelpers.solidImage(), TestHelpers.solidImage()])

        await viewModel.submit()

        XCTAssertEqual(submitter.lastScreenshots.count, 2)
    }

    func testSubmitMapsSDKErrorToErrorState() async {
        let submitter = FakeBugReportSubmitter(
            result: .failure(BugScreenSDKError.apiError("Backend exploded"))
        )
        let viewModel = makeViewModel(submitter: submitter)
        viewModel.description = "Crash"

        await viewModel.submit()

        XCTAssertEqual(viewModel.submissionState, .error)
        guard case .apiError = viewModel.lastError else {
            return XCTFail("Expected .apiError, got \(String(describing: viewModel.lastError))")
        }
    }

    func testSubmitMapsUnknownErrorToErrorState() async {
        struct DummyError: Error {}
        let submitter = FakeBugReportSubmitter(result: .failure(DummyError()))
        let viewModel = makeViewModel(submitter: submitter)
        viewModel.description = "Crash"

        await viewModel.submit()

        XCTAssertEqual(viewModel.submissionState, .error)
        XCTAssertNotNil(viewModel.lastError)
    }

    func testSubmitRejectsEmptyDescriptionWithoutCallingSubmitter() async {
        let submitter = FakeBugReportSubmitter(result: .failure(BugScreenSDKError.encodingError))
        let viewModel = makeViewModel(submitter: submitter)
        viewModel.description = "   \n"

        await viewModel.submit()

        XCTAssertEqual(submitter.invocationCount, 0)
        XCTAssertEqual(viewModel.descriptionValidationMessage, SDKStrings.validationDescriptionRequired)
        XCTAssertEqual(viewModel.submissionState, .idle)
        XCTAssertNil(viewModel.lastError)
    }

    // MARK: - isDirty

    func testIsDirtyFalseOnEmptyForm() {
        let viewModel = makeViewModel()
        XCTAssertFalse(viewModel.isDirty)
    }

    func testIsDirtyTrueWhenDescriptionHasContent() {
        let viewModel = makeViewModel()
        viewModel.description = "broken"
        XCTAssertTrue(viewModel.isDirty)
    }

    func testIsDirtyFalseForWhitespaceOnlyDescription() {
        let viewModel = makeViewModel()
        viewModel.description = "   \n\t  "
        XCTAssertFalse(viewModel.isDirty)
    }

    func testIsDirtyTrueWhenScreenshotPresentWithoutAutoAttach() {
        // Without autoAttach the supplied screenshot is a deliberate user
        // attachment, so the form is dirty even with no typed description.
        let viewModel = makeViewModel(screenshot: TestHelpers.solidImage(), autoAttach: false)
        XCTAssertTrue(viewModel.isDirty)
    }

    func testIsDirtyFalseWhenOnlyAutoAttachPlaceholderPresent() {
        // Auto-attached placeholder shouldn't count — dismissing here loses
        // nothing the user typed or chose.
        let viewModel = makeViewModel(screenshot: TestHelpers.solidImage(), autoAttach: true)
        XCTAssertFalse(viewModel.isDirty)
    }

    func testIsDirtyFalseAfterAutoAttachUpgradeLands() async {
        // ScreenshotObserver presents a fallback + autoAttach. The OS-Photos
        // upgrade replaces the fallback in place. The upgraded slot is still
        // SDK-provided, so the form must remain clean.
        let fallback = TestHelpers.solidImage(color: .red)
        let osScreenshot = TestHelpers.solidImage(color: .blue)
        let viewModel = makeViewModel(
            screenshot: fallback,
            autoAttach: true,
            permission: FakePhotosPermission(outcome: .authorized),
            locator: FakeScreenshotLocator(result: osScreenshot)
        )

        viewModel.onAppear(presenter: UIViewController())
        await flushMainTasks()

        XCTAssertTrue(viewModel.screenshots.first === osScreenshot)
        XCTAssertFalse(viewModel.isDirty)
    }

    func testIsDirtyFalseAfterAutoAttachAppendsFromEmpty() async {
        // autoAttach=true with no initial fallback: the OS screenshot is
        // appended fresh. It's still SDK-provided, so the form stays clean
        // until the user types or adds their own attachment.
        let osScreenshot = TestHelpers.solidImage(color: .blue)
        let viewModel = makeViewModel(
            autoAttach: true,
            permission: FakePhotosPermission(outcome: .authorized),
            locator: FakeScreenshotLocator(result: osScreenshot)
        )

        viewModel.onAppear(presenter: UIViewController())
        await flushMainTasks()

        XCTAssertEqual(viewModel.screenshots.count, 1)
        XCTAssertFalse(viewModel.isDirty)
    }

    func testIsDirtyTrueAfterUserAddsExtraScreenshot() {
        let viewModel = makeViewModel(screenshot: TestHelpers.solidImage(), autoAttach: true)
        viewModel.addScreenshots([TestHelpers.solidImage()])
        XCTAssertTrue(viewModel.isDirty)
    }

    func testIsDirtyFalseAfterUserRemovesAutoAttachPlaceholder() {
        // Removing the placeholder leaves an empty form — still clean.
        let viewModel = makeViewModel(screenshot: TestHelpers.solidImage(), autoAttach: true)
        viewModel.removeScreenshot(at: 0)
        XCTAssertFalse(viewModel.isDirty)
    }

    // MARK: - Helpers

    private func makeViewModel(
        screenshot: UIImage? = nil,
        autoAttach: Bool = false,
        submitter: BugReportSubmitting = FakeBugReportSubmitter(),
        permission: PhotosPermissionRequesting = FakePhotosPermission(outcome: .authorized),
        locator: ScreenshotLocating = FakeScreenshotLocator(result: nil)
    ) -> BugReportViewModel {
        BugReportViewModel(
            screenshot: screenshot,
            autoAttach: autoAttach,
            onDismiss: {},
            submitter: submitter,
            photosPermission: permission,
            screenshotLocator: locator
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
    var result: Result<BugReportResponse, Error>
    private(set) var invocationCount = 0
    private(set) var lastDescription: String?
    private(set) var lastScreenshots: [UIImage] = []
    private(set) var lastType: String?
    private(set) var lastSeverity: String?

    init(result: Result<BugReportResponse, Error> = .success(
        BugReportResponse(success: true, message: "ok", issueURLs: [], partialFailures: nil)
    )) {
        self.result = result
    }

    func submitBugReport(
        description: String,
        screenshots: [UIImage],
        type: String?,
        severity: String?
    ) async throws -> BugReportResponse {
        invocationCount += 1
        lastDescription = description
        lastScreenshots = screenshots
        lastType = type
        lastSeverity = severity
        return try result.get()
    }
}

private final class FakePhotosPermission: PhotosPermissionRequesting {
    var outcome: PhotosPermissionCoordinator.Outcome
    private(set) var invocationCount = 0

    init(outcome: PhotosPermissionCoordinator.Outcome) {
        self.outcome = outcome
    }

    @MainActor
    func ensureAccess(
        presenter _: UIViewController,
        completion: @escaping (PhotosPermissionCoordinator.Outcome) -> Void
    ) {
        invocationCount += 1
        completion(outcome)
    }
}

private final class FakeScreenshotLocator: ScreenshotLocating {
    var result: UIImage?
    private(set) var invocationCount = 0

    init(result: UIImage?) {
        self.result = result
    }

    func findLatestScreenshot(
        since _: Date,
        completion: @escaping (UIImage?) -> Void
    ) {
        invocationCount += 1
        completion(result)
    }
}
