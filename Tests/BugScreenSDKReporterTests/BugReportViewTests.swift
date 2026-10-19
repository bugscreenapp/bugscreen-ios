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
        XCTAssertEqual(viewModel.bugType, "Bug")

        let sut = BugReportView(viewModel: viewModel)
        try sut.inspect().find(button: "UI").tap()

        XCTAssertEqual(viewModel.bugType, "UI")
    }

    func testCustomTypeLabelsRenderVerbatimAndInOrder() throws {
        let viewModel = makeViewModel(reportTypes: ["Bug", "Question", "Suggestion"])
        let view = try BugReportView(viewModel: viewModel).inspect()

        XCTAssertNoThrow(try view.find(button: "Bug"))
        XCTAssertNoThrow(try view.find(button: "Question"))
        XCTAssertNoThrow(try view.find(button: "Suggestion"))
        XCTAssertEqual(viewModel.bugType, "Bug")
    }

    func testCustomTypeLabelsAreCenteredWhenTheyWrap() throws {
        let label = "The labels are long lolo"
        let viewModel = makeViewModel(reportTypes: [label, "Question", "Suggestion"])
        let text = try BugReportView(viewModel: viewModel).inspect().find(text: label)

        XCTAssertEqual(try text.multilineTextAlignment(), .center)
    }

    func testEmptyTypeListOmitsTheWholeSection() throws {
        let viewModel = makeViewModel(reportTypes: [])
        let view = try BugReportView(viewModel: viewModel).inspect()

        XCTAssertThrowsError(try view.find(text: "TYPE"))
        XCTAssertNil(viewModel.bugType)
    }

    func testTappingSeverityPillUpdatesBoundSeverity() throws {
        let viewModel = makeViewModel()
        XCTAssertEqual(viewModel.severity, .medium)

        let sut = BugReportView(viewModel: viewModel)
        try sut.inspect().find(button: BugReportViewModel.Severity.high.displayName).tap()

        XCTAssertEqual(viewModel.severity, .high)
    }

    func testDisabledSeverityOmitsTheWholeSection() throws {
        let view = try BugReportView(viewModel: makeViewModel(severityEnabled: false)).inspect()

        XCTAssertThrowsError(try view.find(text: "SEVERITY"))
        XCTAssertThrowsError(try view.find(button: BugReportViewModel.Severity.medium.displayName))
    }

    // MARK: - Runtime configuration readiness

    func testConfigurationLoadingHidesTheFormAndRetainsItsCapture() throws {
        let viewModel = BugReportViewModel(
            screenshot: UIImage(),
            onDismiss: {},
            submitter: FakeBugReportSubmitter(),
            configurationLoader: { _ in .unavailable }
        )
        let view = try BugReportView(viewModel: viewModel).inspect()

        XCTAssertNoThrow(try view.find(ViewType.ProgressView.self))
        XCTAssertNoThrow(try view.find(text: "Loading report settings"))
        XCTAssertThrowsError(try view.find(text: "Report an issue"))
        XCTAssertEqual(viewModel.screenshots.count, 1)
    }

    func testConfigurationErrorShowsGuidanceAndRetry() async throws {
        let viewModel = BugReportViewModel(
            onDismiss: {},
            submitter: FakeBugReportSubmitter(),
            configurationLoader: { _ in .unavailable }
        )
        viewModel.loadConfigurationIfNeeded()
        for _ in 0 ..< 8 {
            await Task.yield()
        }

        let view = try BugReportView(viewModel: viewModel).inspect()
        XCTAssertNoThrow(try view.find(text: "Couldn't load report settings"))
        XCTAssertNoThrow(try view.find(text: "Check your connection and try again."))
        XCTAssertNoThrow(try view.find(button: "Retry"))
        XCTAssertThrowsError(try view.find(text: "Report an issue"))
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

    func testThumbnailHasOneNumberedPreviewActionWithDecorativePencil() throws {
        let view = try BugReportView(viewModel: makeViewModel(screenshot: UIImage())).inspect()
        let row = try view.find(ViewType.ScrollView.self, where: { try $0.axes() == .horizontal })
        let buttons = row.findAll(ViewType.Button.self)

        XCTAssertEqual(buttons.count, 2, "one preview button and Add; the pencil is not a button")
        let thumbnail = try row.find(ViewType.Button.self, where: {
            try $0.accessibilityLabel().string() == "Open preview for attachment 1"
        })
        XCTAssertFalse(try thumbnail.isDisabled())
        XCTAssertEqual(try thumbnail.labelView().fixedWidth(), 112)
        XCTAssertEqual(try thumbnail.labelView().fixedHeight(), 112)
        XCTAssertNoThrow(try thumbnail.labelView().find(ViewType.Image.self, where: {
            try $0.actualImage().name() == "pencil"
        }))
        for image in try thumbnail.labelView().findAll(ViewType.Image.self) {
            XCTAssertTrue(try image.accessibilityHidden(), "thumbnail images are decorative children of the preview button")
        }
    }

    func testFourAttachmentsRemainInTheHorizontalRowWithoutAdd() throws {
        let viewModel = makeViewModel(screenshot: UIImage())
        viewModel.addScreenshots([UIImage(), UIImage(), UIImage()])
        let view = try BugReportView(viewModel: viewModel).inspect()
        let row = try view.find(ViewType.ScrollView.self, where: { try $0.axes() == .horizontal })

        XCTAssertEqual(row.findAll(ViewType.Button.self).count, 4)
        for number in 1 ... 4 {
            XCTAssertNoThrow(try row.find(ViewType.Button.self, where: {
                try $0.accessibilityLabel().string() == "Open preview for attachment \(number)"
            }))
        }
        XCTAssertThrowsError(try row.find(button: "Add"))
    }

    func testSubmittingDisablesThumbnailAndAdd() throws {
        let viewModel = makeViewModel(screenshot: UIImage())
        viewModel.submissionState = .submitting
        let row = try BugReportView(viewModel: viewModel).inspect()
            .find(ViewType.ScrollView.self, where: { try $0.axes() == .horizontal })

        for button in row.findAll(ViewType.Button.self) {
            XCTAssertTrue(try button.isDisabled())
        }
    }

    func testConfiguredCopyRendersLiterallyAndPartialDeliveryKeepsItsWarning() async throws {
        let copy = ReporterCopy(title: "Share <feedback>", descriptionLabel: "Your thoughts?",
                                descriptionPlaceholder: "Tell us more…", typeLabel: "Feedback type",
                                submitLabel: "Send feedback", successTitle: "Received!", successMessage: "Thank you for your feedback.")
        let vm = BugReportViewModel(onDismiss: {}, submitter: FakeBugReportSubmitter(),
                                    configurationLoader: { _ in .ready(ReporterConfiguration(
                                        showBranding: false,
                                        reportTypes: ["Question", "Suggestion"],
                                        copy: copy
                                    )) })
        vm.loadConfigurationIfNeeded()
        for _ in 0 ..< 8 {
            await Task.yield()
        }
        let form = try BugReportView(viewModel: vm).inspect()
        for text in [copy.title, copy.descriptionLabel, copy.descriptionPlaceholder, copy.typeLabel] {
            XCTAssertNoThrow(try form.find(text: text))
        }
        XCTAssertNoThrow(try form.find(button: copy.submitLabel))
        let success = try SuccessToast(copy: copy).inspect()
        XCTAssertNoThrow(try success.find(text: copy.successTitle))
        XCTAssertNoThrow(try success.find(text: copy.successMessage))
        let partial = try SuccessToast(partialFailures: [ReportPartialFailure(type: "slack", message: "Unavailable")], copy: copy).inspect()
        XCTAssertNoThrow(try partial.find(text: SDKStrings.successPartialTitle))
        XCTAssertThrowsError(try partial.find(text: copy.successTitle))
    }

    // MARK: - Helpers

    private func makeViewModel(
        screenshot: UIImage? = nil,
        reportTypes: [String] = defaultReportTypes,
        severityEnabled: Bool = true
    ) -> BugReportViewModel {
        BugReportViewModel(
            screenshot: screenshot,
            onDismiss: {},
            submitter: FakeBugReportSubmitter(),
            photosPermission: FakePhotosPermission(),
            screenshotLocator: FakeScreenshotLocator(),
            reportTypes: reportTypes,
            severityEnabled: severityEnabled
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
