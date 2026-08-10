@testable import BugScreenSDK
import SwiftUI
import UIKit
import ViewInspector
import XCTest

/// View-layer assertions for `BugReportView`, the sibling of the Android
/// Compose UI tests (bugscreen-nh1). Inspects the SwiftUI tree from XCTest via
/// ViewInspector — no XCUITest, no on-device UI automation, no snapshot/pixel
/// tests. State is driven through `BugReportViewModel`'s published properties so
/// the assertions exercise the real render path without hosting the view.
@MainActor
final class BugReportViewTests: XCTestCase {
    // MARK: - Validation

    /// iOS deliberately keeps the create-ticket CTA enabled on an empty
    /// description (canSubmit == !submitting): the inline validator surfaces the
    /// reason instead of silently disabling the button. This diverges from the
    /// Android scenario, which disables the CTA — reconciled to iOS reality here.
    func testCreateTicketButtonStaysEnabledWhileDescriptionEmpty() throws {
        let viewModel = makeViewModel()
        let sut = BugReportView(viewModel: viewModel)

        let button = try sut.inspect().find(button: "Create ticket")
        XCTAssertFalse(try button.isDisabled())
    }

    func testEmptySubmitSurfacesValidationMessageInScrollBody() async throws {
        let viewModel = makeViewModel()
        viewModel.description = "   "

        // Empty/whitespace description returns before any network call.
        await viewModel.submit()

        let view = try BugReportView(viewModel: viewModel).inspect()
        XCTAssertNoThrow(
            try view.find(ViewType.ScrollView.self).find(text: SDKStrings.validationDescriptionRequired),
            "validation message should render in the scrolling form body"
        )
        // The CTA is not disabled by the empty description.
        XCTAssertFalse(try view.find(button: "Create ticket").isDisabled())
    }

    // MARK: - Submit-blocking (loading)

    func testSubmittingDisablesDescriptionAndShowsLoadingCTA() throws {
        let viewModel = makeViewModel()
        viewModel.submissionState = .submitting

        let view = try BugReportView(viewModel: viewModel).inspect()

        XCTAssertTrue(
            try view.find(ViewType.TextEditor.self).isDisabled(),
            "description field should be locked while submitting"
        )
        // While loading the CTA renders a spinner instead of the label text.
        XCTAssertNoThrow(try view.find(ViewType.ProgressView.self))
        XCTAssertThrowsError(try view.find(button: "Create ticket"))
    }

    func testSubmittingBlocksDismissWithoutConfirmation() {
        // The UIKit host (UISheetPresentationController) consults this view-model
        // predicate to decide whether a swipe/scrim-tap dismiss is honored.
        let viewModel = makeViewModel()

        viewModel.submissionState = .submitting
        XCTAssertFalse(viewModel.canDismissWithoutConfirmation)

        viewModel.submissionState = .idle
        viewModel.description = "still typing"
        XCTAssertFalse(viewModel.canDismissWithoutConfirmation)

        viewModel.description = ""
        XCTAssertTrue(viewModel.canDismissWithoutConfirmation)
    }

    // MARK: - Failure flow

    func testErrorStateRendersSnackbarInFooterAndClearsLoading() throws {
        let viewModel = makeViewModel()
        viewModel.submissionState = .error
        viewModel.lastError = .offline

        let view = try BugReportView(viewModel: viewModel).inspect()

        // Snackbar (title + user message) is present…
        XCTAssertNoThrow(try view.find(text: SDKStrings.errorTitle))
        XCTAssertNoThrow(try view.find(text: BugScreenSDKError.offline.userMessage))
        // …in the pinned footer, not the scrolling body.
        XCTAssertThrowsError(
            try view.find(ViewType.ScrollView.self).find(text: SDKStrings.errorTitle),
            "error snackbar belongs to the footer, not the scroll body"
        )
        // Loading indicator is cleared and the CTA is tappable again.
        XCTAssertThrowsError(try view.find(ViewType.ProgressView.self))
        XCTAssertFalse(try view.find(button: "Create ticket").isDisabled())
    }

    // MARK: - Type / Severity selection

    func testTappingTypeChipUpdatesBoundType() throws {
        let viewModel = makeViewModel()
        XCTAssertEqual(viewModel.bugType, .bug)

        let sut = BugReportView(viewModel: viewModel)
        try sut.inspect().find(button: BugReportViewModel.BugType.ui.displayName).tap()

        XCTAssertEqual(viewModel.bugType, .ui)
    }

    func testTappingSeverityPillUpdatesBoundSeverity() throws {
        let viewModel = makeViewModel()
        XCTAssertEqual(viewModel.severity, .medium)

        let sut = BugReportView(viewModel: viewModel)
        try sut.inspect().find(button: BugReportViewModel.Severity.high.displayName).tap()

        XCTAssertEqual(viewModel.severity, .high)
    }

    // MARK: - Attachment cap

    /// `Section` uppercases its label, so assert on the rendered casing. The point of both
    /// tests is that the cap is readable on an empty form — before the tester runs into it —
    /// rather than being inferred when the Add tile disappears (CAP-004).
    func testAttachmentsSectionStatesTheCapOnAnEmptyForm() throws {
        let sut = BugReportView(viewModel: makeViewModel())

        XCTAssertNoThrow(try sut.inspect().find(text: "ATTACHMENTS · 0 OF 4"))
    }

    func testAttachmentsSectionCountsWhatIsAttached() throws {
        let sut = BugReportView(viewModel: makeViewModel(screenshot: UIImage()))

        XCTAssertNoThrow(try sut.inspect().find(text: "ATTACHMENTS · 1 OF 4"))
        XCTAssertThrowsError(try sut.inspect().find(text: "ATTACHMENTS · 0 OF 4"))
    }

    // MARK: - Helpers

    private func makeViewModel(screenshot: UIImage? = nil) -> BugReportViewModel {
        BugReportViewModel(
            screenshot: screenshot,
            onDismiss: {},
            submitter: FakeBugReportSubmitter(),
            photosPermission: FakePhotosPermission(),
            screenshotLocator: FakeScreenshotLocator()
        )
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
    @MainActor
    func ensureAccess(
        presenter _: UIViewController,
        completion: @escaping (PhotosPermissionCoordinator.Outcome) -> Void
    ) {
        completion(.denied)
    }
}

private final class FakeScreenshotLocator: ScreenshotLocating {
    func findLatestScreenshot(
        since _: Date,
        completion: @escaping (UIImage?) -> Void
    ) {
        completion(nil)
    }
}
