import Foundation
import UIKit
import Combine

/// ViewModel for the bug report UI.
///
/// Manages form state, validation, and submission logic for the bug report screen.
@MainActor
internal final class BugReportViewModel: ObservableObject {

    // MARK: - Published Properties

    /// User's description of the bug (1-10000 characters)
    @Published var description: String = ""

    /// Optional screenshot image to attach
    @Published var screenshot: UIImage?

    /// Device metadata collected automatically
    @Published var metadata: [String: Any]

    /// Current submission state
    @Published var submissionState: SubmissionState = .idle

    /// Error message to display in alert
    @Published var errorMessage: String?

    /// Whether to show the error alert
    @Published var showErrorAlert: Bool = false

    /// Callback to dismiss the bug report UI
    private let onDismiss: () -> Void

    /// When true, the view model will try to replace `screenshot` with the most recent
    /// OS screenshot from the Photos library on first appearance.
    private let autoAttach: Bool

    /// Time at which the auto-attach flow was triggered. Used as the lower bound for the
    /// Photos query so we don't pick up an unrelated older screenshot.
    private let autoAttachSince: Date

    /// Whether the auto-attach flow has already run, so it only fires once per presentation.
    private var autoAttachHandled = false

    // MARK: - Dependencies (injectable for tests)

    private let submitter: BugReportSubmitting
    private let photosPermission: PhotosPermissionRequesting
    private let screenshotLocator: ScreenshotLocating

    // MARK: - Initialization

    /// Creates a new bug report view model.
    ///
    /// - Parameters:
    ///   - screenshot: Optional pre-attached screenshot
    ///   - autoAttach: When true, attempts to replace `screenshot` with the OS screenshot from Photos
    ///   - onDismiss: Callback to dismiss the UI
    ///   - submitter: Submission adapter (defaults to the SDK-backed implementation)
    ///   - photosPermission: Photos permission coordinator (defaults to system-backed)
    ///   - screenshotLocator: Photo-library lookup (defaults to system-backed)
    init(
        screenshot: UIImage? = nil,
        autoAttach: Bool = false,
        onDismiss: @escaping () -> Void,
        submitter: BugReportSubmitting = DefaultBugReportSubmitter(),
        photosPermission: PhotosPermissionRequesting = DefaultPhotosPermissionRequester(),
        screenshotLocator: ScreenshotLocating = DefaultScreenshotLocator()
    ) {
        self.screenshot = screenshot
        self.autoAttach = autoAttach
        self.autoAttachSince = Date()
        self.onDismiss = onDismiss
        self.metadata = MetadataCollector.collect()
        self.submitter = submitter
        self.photosPermission = photosPermission
        self.screenshotLocator = screenshotLocator
    }

    // MARK: - Computed Properties

    /// Whether the submit button should be enabled
    var canSubmit: Bool {
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        description.count <= 10000 &&
        submissionState != .submitting
    }

    /// Character count for the description field
    var characterCount: Int {
        description.count
    }

    /// Whether the character count is within valid range
    var isCharacterCountValid: Bool {
        characterCount > 0 && characterCount <= 10000
    }

    // MARK: - Actions

    /// Submits the bug report to the backend.
    func submit() async {
        // Validate description
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Please enter a description of the bug"
            showErrorAlert = true
            return
        }

        guard trimmed.count <= 10000 else {
            errorMessage = "Description must be 10,000 characters or less"
            showErrorAlert = true
            return
        }

        // Update state
        submissionState = .submitting
        errorMessage = nil

        do {
            _ = try await submitter.submitBugReport(
                description: trimmed,
                screenshot: screenshot
            )

            submissionState = .success
            onDismiss()

        } catch let error as BugScreenSDKError {
            // Handle SDK errors
            submissionState = .error
            errorMessage = error.localizedDescription
            showErrorAlert = true

        } catch {
            // Handle other errors
            submissionState = .error
            errorMessage = "An unexpected error occurred: \(error.localizedDescription)"
            showErrorAlert = true
        }
    }

    /// Called when the bug report view appears. Drives the auto-attach flow on first appearance.
    func onAppear(presenter: UIViewController?) {
        guard autoAttach, !autoAttachHandled else { return }
        autoAttachHandled = true
        guard let presenter else { return }

        let since = autoAttachSince
        photosPermission.ensureAccess(presenter: presenter) { [weak self] outcome in
            guard outcome == .authorized else { return }
            self?.screenshotLocator.findLatestScreenshot(since: since) { image in
                guard let image else { return }
                Task { @MainActor in
                    self?.screenshot = image
                }
            }
        }
    }

    /// Dismisses the bug report UI.
    func dismiss() {
        onDismiss()
    }

    /// Resets the form after successful submission.
    func reset() {
        description = ""
        screenshot = nil
        submissionState = .idle
        errorMessage = nil
    }

    // MARK: - Submission State

    /// Represents the current state of bug report submission
    enum SubmissionState: Equatable {
        /// No submission in progress
        case idle

        /// Submission in progress
        case submitting

        /// Submission succeeded
        case success

        /// Submission failed
        case error
    }
}
