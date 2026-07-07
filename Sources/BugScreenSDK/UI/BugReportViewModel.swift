import Combine
import Foundation
import UIKit

/// ViewModel for the bug report UI.
///
/// Manages form state, validation, and submission logic for the bug report screen.
@MainActor
final class BugReportViewModel: ObservableObject {
    // MARK: - Published Properties

    /// User's description of the bug (1-10000 characters)
    @Published var description: String = ""

    /// Up to ``BugReportViewModel/maxScreenshots`` images to attach to the report.
    @Published private(set) var screenshots: [UIImage] = []

    /// Reporter-selected bug type. Forwarded to GitHub/Jira as a label.
    @Published var bugType: BugType = .bug

    /// Reporter-selected severity. Forwarded to GitHub/Jira as a label/priority.
    @Published var severity: Severity = .medium

    /// Device metadata collected automatically
    @Published var metadata: [String: Any]

    /// Current submission state
    @Published var submissionState: SubmissionState = .idle

    /// Last submission error (drives the error UI). Nil when no error is active.
    @Published var lastError: BugScreenSDKError?

    /// Inline validation error for the description field. Shown beneath the
    /// text field rather than in an alert so the user can act on it without
    /// dismissing anything.
    @Published var descriptionValidationMessage: String?

    /// Partial integration failures from a successful submit. When non-empty,
    /// the success toast switches to its "with issues" variant.
    @Published var partialFailures: [BugReportPartialFailure] = []

    /// Callback to dismiss the bug report UI (cancel / close).
    private var onDismiss: () -> Void

    /// Callback invoked after a successful submit. The hosting controller
    /// dismisses the sheet and surfaces the success toast over the host app.
    /// Receives any partial integration failures so the toast can switch to
    /// its "with issues" variant.
    private var onSuccess: ([BugReportPartialFailure]) -> Void

    /// When true, the view model will try to append the most recent OS screenshot
    /// from the Photos library on first appearance.
    private let autoAttach: Bool

    /// Time at which the auto-attach flow was triggered. Used as the lower bound for the
    /// Photos query so we don't pick up an unrelated older screenshot.
    private let autoAttachSince: Date

    /// Whether the auto-attach flow has already run, so it only fires once per presentation.
    private var autoAttachHandled = false

    /// Index of the initial screenshot supplied at init time (typically a
    /// window-snapshot fallback from `ScreenshotObserver`). When auto-attach
    /// later resolves the higher-quality OS screenshot from Photos, we
    /// replace this entry instead of appending — otherwise the user sees the
    /// same screen attached twice. Cleared once the user touches the slot
    /// (removes, replaces, or the upgrade lands).
    private var placeholderIndex: Int?

    // MARK: - Dependencies (injectable for tests)

    private let submitter: BugReportSubmitting
    private let photosPermission: PhotosPermissionRequesting
    private let screenshotLocator: ScreenshotLocating

    // MARK: - Constants

    /// Matches the backend's busboy file-count limit and Android's `MAX_SCREENSHOTS`.
    static let maxScreenshots = 4

    // MARK: - Initialization

    init(
        screenshot: UIImage? = nil,
        autoAttach: Bool = false,
        onDismiss: @escaping () -> Void,
        onSuccess: @escaping ([BugReportPartialFailure]) -> Void = { _ in },
        submitter: BugReportSubmitting = DefaultBugReportSubmitter(),
        photosPermission: PhotosPermissionRequesting = DefaultPhotosPermissionRequester(),
        screenshotLocator: ScreenshotLocating = DefaultScreenshotLocator()
    ) {
        if let screenshot {
            screenshots = [screenshot]
            // Only treat the initial shot as an upgradeable placeholder when
            // auto-attach is on. Without auto-attach the caller supplied a
            // deliberate screenshot we must not silently replace.
            if autoAttach {
                placeholderIndex = 0
            }
        }
        self.autoAttach = autoAttach
        autoAttachSince = Date()
        self.onDismiss = onDismiss
        self.onSuccess = onSuccess
        let customData = BugScreenSDK.resolveReportCustomData()
        metadata = MetadataCollector.collect(customData: customData.isEmpty ? nil : customData)
        self.submitter = submitter
        self.photosPermission = photosPermission
        self.screenshotLocator = screenshotLocator
    }

    // MARK: - Computed Properties

    /// Whether the submit button should be enabled. Empty/too-long descriptions
    /// are reachable so the inline validators in `submit()` can surface a
    /// `descriptionValidationMessage` — silently disabling the button hides
    /// the reason from the user.
    var canSubmit: Bool {
        submissionState != .submitting
    }

    /// Whether there is room to attach more screenshots.
    var canAddMoreScreenshots: Bool {
        screenshots.count < BugReportViewModel.maxScreenshots
    }

    /// Remaining attachment slots (0 to ``maxScreenshots``).
    var remainingScreenshotSlots: Int {
        max(0, BugReportViewModel.maxScreenshots - screenshots.count)
    }

    /// True when the user has unsaved input that would be lost on dismiss.
    /// The auto-attach placeholder doesn't count — if the user hasn't typed
    /// anything and the only screenshot is the one the SDK attached for them,
    /// dismissing is safe.
    var isDirty: Bool {
        if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if placeholderIndex != nil {
            return screenshots.count > 1
        }
        return !screenshots.isEmpty
    }

    // MARK: - Attachment Mutation

    /// Appends up to ``remainingScreenshotSlots`` images. Extras are dropped.
    func addScreenshots(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        let slots = remainingScreenshotSlots
        guard slots > 0 else { return }
        screenshots.append(contentsOf: images.prefix(slots))
    }

    /// Removes the attachment at `index`, ignoring out-of-bounds indices.
    func removeScreenshot(at index: Int) {
        guard screenshots.indices.contains(index) else { return }
        screenshots.remove(at: index)
        // Forget the placeholder if it was removed or its index shifted out
        // from under it. Either way the upgrade can no longer target a
        // specific slot, so the OS screenshot (if it arrives) will append.
        if let placeholder = placeholderIndex {
            if index == placeholder {
                placeholderIndex = nil
            } else if index < placeholder {
                placeholderIndex = placeholder - 1
            }
        }
    }

    /// Auto-attach resolution: if the placeholder slot is still intact,
    /// replace it with the higher-quality OS screenshot. Otherwise append
    /// (subject to the slot cap), so the OS shot still lands somewhere
    /// useful if the user happened to clear the placeholder.
    ///
    /// `placeholderIndex` is intentionally kept after the upgrade lands —
    /// the slot still holds an SDK-provided screenshot the user never
    /// chose, so `isDirty` must continue to exempt it. The index is only
    /// cleared when the user touches the slot via `removeScreenshot`.
    private func upgradePlaceholderOrAppend(with image: UIImage) {
        if let index = placeholderIndex, screenshots.indices.contains(index) {
            screenshots[index] = image
            return
        }
        let countBefore = screenshots.count
        addScreenshots([image])
        if screenshots.count > countBefore {
            placeholderIndex = screenshots.count - 1
        }
    }

    // MARK: - Actions

    /// Submits the bug report to the backend.
    func submit() async {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            descriptionValidationMessage = SDKStrings.validationDescriptionRequired
            return
        }

        guard trimmed.count <= 10000 else {
            descriptionValidationMessage = SDKStrings.validationDescriptionTooLong
            return
        }

        descriptionValidationMessage = nil
        submissionState = .submitting
        lastError = nil
        partialFailures = []

        do {
            let response = try await submitter.submitBugReport(
                description: trimmed,
                screenshots: screenshots,
                type: bugType.apiValue,
                severity: severity.apiValue
            )

            partialFailures = response.partialFailures ?? []
            submissionState = .success
            onSuccess(partialFailures)

        } catch let error as BugScreenSDKError {
            submissionState = .error
            lastError = error

        } catch let urlError as URLError {
            submissionState = .error
            lastError = BugScreenSDKError.networkError(urlError)

        } catch {
            submissionState = .error
            lastError = .invalidResponse
        }
    }

    /// Called when the bug report view appears. Drives the auto-attach flow on first appearance.
    func onAppear(presenter: UIViewController?) {
        guard autoAttach, !autoAttachHandled else { return }
        autoAttachHandled = true
        guard let presenter else { return }
        // When a placeholder exists, we always have room to upgrade it even if
        // the list is at the cap. Otherwise require a free slot to append.
        if placeholderIndex == nil, !canAddMoreScreenshots { return }

        let since = autoAttachSince
        photosPermission.ensureAccess(presenter: presenter) { [weak self] outcome in
            guard outcome == .authorized else { return }
            self?.screenshotLocator.findLatestScreenshot(since: since) { image in
                guard let image else { return }
                Task { @MainActor in
                    self?.upgradePlaceholderOrAppend(with: image)
                }
            }
        }
    }

    /// Dismisses the bug report UI. Called by the toast after it fades out, and
    /// by the close button.
    func dismiss() {
        onDismiss()
    }

    /// Replaces the dismiss / success callbacks after construction. Lets
    /// `BugReportHostingController` build the view model in its initializer
    /// (so it can be passed into the SwiftUI view immediately) and then wire
    /// up callbacks that capture `self` once `super.init` has completed.
    func bind(
        onDismiss: @escaping () -> Void,
        onSuccess: @escaping ([BugReportPartialFailure]) -> Void
    ) {
        self.onDismiss = onDismiss
        self.onSuccess = onSuccess
    }

    /// Resets the form after successful submission.
    func reset() {
        description = ""
        screenshots = []
        bugType = .bug
        severity = .medium
        submissionState = .idle
        lastError = nil
        descriptionValidationMessage = nil
        partialFailures = []
    }

    // MARK: - Submission State

    /// Represents the current state of bug report submission
    enum SubmissionState: Equatable {
        case idle
        case submitting
        case success
        case error
    }

    // MARK: - Bug Type

    /// Mirrors Android `BugType` and the values accepted by `POST /reports`.
    enum BugType: String, CaseIterable, Identifiable {
        case bug
        case ui
        case crash

        var id: String {
            rawValue
        }

        var apiValue: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .bug: "Bug"
            case .ui: "UI"
            case .crash: "Crash"
            }
        }
    }

    // MARK: - Severity

    /// Mirrors Android `Severity` and the values accepted by `POST /reports`.
    enum Severity: String, CaseIterable, Identifiable {
        case low
        case medium
        case high

        var id: String {
            rawValue
        }

        var apiValue: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .low: "Low"
            case .medium: "Medium"
            case .high: "High"
            }
        }
    }
}
