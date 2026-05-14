import XCTest
import UIKit
@testable import BugScreenSDK

@MainActor
final class BugReportViewModelTests: XCTestCase {

    // MARK: - Auto-attach

    func testAutoAttachWhenAuthorizedReplacesScreenshot() async {
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
        XCTAssertNotNil(viewModel.screenshot)
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

    func testAutoAttachDeniedLeavesScreenshotNil() async {
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
        XCTAssertNil(viewModel.screenshot)
    }

    func testAutoAttachCancelledLeavesScreenshotNil() async {
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
        XCTAssertNil(viewModel.screenshot)
    }

    func testAutoAttachDoesNotOverwriteWhenLocatorReturnsNil() async {
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

        XCTAssertEqual(viewModel.screenshot, existing)
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

    // MARK: - Submission

    func testSubmitSuccessDismissesScreen() async {
        let response = BugReportResponse(
            success: true,
            message: "ok",
            issueUrls: ["https://github.com/example/repo/issues/1"]
        )
        let submitter = FakeBugReportSubmitter(result: .success(response))
        var dismissCount = 0
        let viewModel = BugReportViewModel(
            onDismiss: { dismissCount += 1 },
            submitter: submitter,
            photosPermission: FakePhotosPermission(outcome: .authorized),
            screenshotLocator: FakeScreenshotLocator(result: nil)
        )
        viewModel.description = "Login button is unresponsive"

        await viewModel.submit()

        XCTAssertEqual(viewModel.submissionState, .success)
        XCTAssertEqual(dismissCount, 1)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testSubmitMapsSDKErrorToErrorState() async {
        let submitter = FakeBugReportSubmitter(
            result: .failure(BugScreenSDKError.apiError("Backend exploded"))
        )
        let viewModel = makeViewModel(submitter: submitter)
        viewModel.description = "Crash"

        await viewModel.submit()

        XCTAssertEqual(viewModel.submissionState, .error)
        XCTAssertEqual(viewModel.errorMessage, "Backend exploded")
        XCTAssertTrue(viewModel.showErrorAlert)
    }

    func testSubmitMapsUnknownErrorToErrorState() async {
        struct DummyError: Error {}
        let submitter = FakeBugReportSubmitter(result: .failure(DummyError()))
        let viewModel = makeViewModel(submitter: submitter)
        viewModel.description = "Crash"

        await viewModel.submit()

        XCTAssertEqual(viewModel.submissionState, .error)
        XCTAssertTrue(viewModel.showErrorAlert)
        XCTAssertEqual(viewModel.errorMessage?.contains("unexpected error"), true)
    }

    func testSubmitRejectsEmptyDescriptionWithoutCallingSubmitter() async {
        let submitter = FakeBugReportSubmitter(result: .failure(BugScreenSDKError.encodingError))
        let viewModel = makeViewModel(submitter: submitter)
        viewModel.description = "   \n"

        await viewModel.submit()

        XCTAssertEqual(submitter.invocationCount, 0)
        XCTAssertTrue(viewModel.showErrorAlert)
        XCTAssertEqual(viewModel.errorMessage, "Please enter a description of the bug")
        XCTAssertEqual(viewModel.submissionState, .idle)
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
        for _ in 0..<times {
            await Task.yield()
        }
    }

}

// MARK: - Fakes

private final class FakeBugReportSubmitter: BugReportSubmitting {
    var result: Result<BugReportResponse, Error>
    private(set) var invocationCount = 0
    private(set) var lastDescription: String?

    init(result: Result<BugReportResponse, Error> = .success(
        BugReportResponse(success: true, message: "ok", issueUrls: [])
    )) {
        self.result = result
    }

    func submitBugReport(
        description: String,
        screenshot: UIImage?
    ) async throws -> BugReportResponse {
        invocationCount += 1
        lastDescription = description
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
        presenter: UIViewController,
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
        since: Date,
        completion: @escaping (UIImage?) -> Void
    ) {
        invocationCount += 1
        completion(result)
    }
}
