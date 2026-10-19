import Combine
import Foundation
import UIKit

struct PendingAttachment: Identifiable {
    let id: UUID
    var image: UIImage?
    var video: PreparedVideo?
    var isPreparing = true
}

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
    @Published private(set) var videos: [Int: PreparedVideo] = [:]
    @Published private(set) var isPreparingMedia = false
    @Published private(set) var pendingAttachments: [PendingAttachment] = []
    private var preparationTask: Task<Void, Never>?
    private var mediaClosed = false

    func beginMediaImport(count: Int = 1) {
        guard !mediaClosed else { return }
        pendingAttachments = (0 ..< min(count, remainingScreenshotSlots)).map { _ in PendingAttachment(id: UUID()) }
        isPreparingMedia = true
    }

    func finishMediaImport(_ picked: [PickedAttachment]) {
        preparationTask = Task { await addPickedAttachments(picked) }
    }

    var supportsVideoAttachments: Bool {
        submitter is VideoReportSubmitting && videoAttachmentLimits?.isValid == true
    }

    /// Reporter-selected type display label. Nil when the Type section is hidden.
    @Published var bugType: String?

    @Published private(set) var copy = ReporterCopy()
    @Published private(set) var reportTypes: [String] = []

    @Published private(set) var showBranding = false

    @Published private(set) var videoAttachmentLimits: VideoAttachmentLimits?

    @Published private(set) var severityEnabled = true

    @Published private(set) var configurationState: ConfigurationState = .loading

    /// Reporter-selected severity. Forwarded to GitHub/Jira as a label/priority.
    @Published var severity: Severity = .medium

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
    @Published var partialFailures: [ReportPartialFailure] = []

    /// Callback to dismiss the bug report UI (cancel / close).
    private var onDismiss: () -> Void

    /// Callback invoked after a successful submit. The hosting controller
    /// dismisses the sheet and surfaces the success toast over the host app.
    /// Receives any partial integration failures so the toast can switch to
    /// its "with issues" variant.
    private var onSuccess: ([ReportPartialFailure]) -> Void

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
    private let videoPreparer: VideoPreparing
    private let configurationLoader: @MainActor (Bool) async -> ReporterConfigurationResult
    private var configurationLoadStarted = false

    // MARK: - Constants

    /// Matches the backend's busboy file-count limit and Android's `MAX_SCREENSHOTS`.
    static let maxScreenshots = 4

    // MARK: - Initialization

    init(
        screenshot: UIImage? = nil,
        autoAttach: Bool = false,
        onDismiss: @escaping () -> Void,
        onSuccess: @escaping ([ReportPartialFailure]) -> Void = { _ in },
        submitter: BugReportSubmitting,
        photosPermission: PhotosPermissionRequesting = DefaultPhotosPermissionRequester(),
        screenshotLocator: ScreenshotLocating = DefaultScreenshotLocator(),
        videoPreparer: VideoPreparing = DefaultVideoPreparer(),
        reportTypes: [String] = defaultReportTypes,
        severityEnabled: Bool = true,
        videoAttachmentLimits: VideoAttachmentLimits? = nil,
        configurationLoader: (@MainActor (Bool) async -> ReporterConfigurationResult)? = nil
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
        self.submitter = submitter
        self.photosPermission = photosPermission
        self.screenshotLocator = screenshotLocator
        self.videoPreparer = videoPreparer
        if let configurationLoader {
            self.configurationLoader = configurationLoader
            bugType = nil
        } else {
            self.configurationLoader = { _ in
                .ready(ReporterConfiguration(
                    showBranding: false,
                    reportTypes: reportTypes,
                    severityEnabled: severityEnabled,
                    videoAttachmentLimits: videoAttachmentLimits
                ))
            }
            self.reportTypes = reportTypes
            bugType = reportTypes.first
            self.severityEnabled = severityEnabled
            self.videoAttachmentLimits = videoAttachmentLimits
            configurationState = .ready
            configurationLoadStarted = true
        }
    }

    // MARK: - Computed Properties

    /// Whether the submit button should be enabled. Empty/too-long descriptions
    /// are reachable so the inline validators in `submit()` can surface a
    /// `descriptionValidationMessage` — silently disabling the button hides
    /// the reason from the user.
    var canSubmit: Bool {
        submissionState != .submitting && !isPreparingMedia
    }

    var attachmentCount: Int {
        screenshots.count + pendingAttachments.count
    }

    /// Whether there is room to attach more screenshots.
    var canAddMoreScreenshots: Bool {
        attachmentCount < BugReportViewModel.maxScreenshots
    }

    /// Remaining attachment slots (0 to ``maxScreenshots``).
    var remainingScreenshotSlots: Int {
        max(0, BugReportViewModel.maxScreenshots - attachmentCount)
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

    /// Whether a swipe / scrim-tap dismiss should be honored without a discard
    /// prompt. Blocks entirely mid-submit; otherwise allows dismiss only when the
    /// form has no unsaved input.
    var canDismissWithoutConfirmation: Bool {
        if submissionState == .submitting || isPreparingMedia { return false }
        if configurationState != .ready { return true }
        return !isDirty
    }

    // MARK: - Attachment Mutation

    /// Appends up to ``remainingScreenshotSlots`` images. Extras are dropped.
    func addScreenshots(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        let slots = remainingScreenshotSlots
        guard slots > 0 else { return }
        screenshots.append(contentsOf: images.prefix(slots))
    }

    func addPickedAttachments(_ picked: [PickedAttachment]) async {
        defer { picked.forEach { if case let .video(url) = $0 { try? FileManager.default.removeItem(at: url) } } }
        guard !mediaClosed else { return }
        isPreparingMedia = true
        defer {
            isPreparingMedia = false
            clearPendingAttachments()
        }
        let batch = reserveAttachments(picked)

        let videoSelections = batch.compactMap { id, item -> (UUID, URL)? in
            guard case let .video(url) = item, supportsVideoAttachments else { return nil }
            return (id, url)
        }
        await loadSourcePosters(videoSelections)
        guard let limits = videoAttachmentLimits else { return }
        for (id, url) in videoSelections {
            guard !mediaClosed, !Task.isCancelled else { return }
            do {
                let video = try await videoPreparer.prepare(url, limits: limits)
                guard !mediaClosed, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: video.file)
                    return
                }
                updatePending(id) { $0.image = video.poster; $0.video = video; $0.isPreparing = false }
                flushReadyAttachments()
            } catch {
                guard !mediaClosed, !Task.isCancelled else { return }
                failPending(id, error: error)
                flushReadyAttachments()
            }
        }
    }

    private func reserveAttachments(_ picked: [PickedAttachment]) -> [(UUID, PickedAttachment)] {
        let selected = Array(picked.prefix(Self.maxScreenshots - screenshots.count))
        let existingIDs = pendingAttachments.map(\.id)
        pendingAttachments = selected.indices.map { index in
            PendingAttachment(id: index < existingIDs.count ? existingIDs[index] : UUID())
        }
        let batch = Array(zip(pendingAttachments.map(\.id), selected))
        for (id, item) in batch {
            switch item {
            case let .image(image):
                updatePending(id) { $0.image = image; $0.isPreparing = false }
            case .video:
                if !supportsVideoAttachments { removePending(id) }
            case let .unavailable(failure):
                failPending(id, error: failure)
            }
        }
        flushReadyAttachments()

        return batch
    }

    private func loadSourcePosters(_ videoSelections: [(UUID, URL)]) async {
        let preparer = videoPreparer
        await withTaskGroup(of: (UUID, UIImage?).self) { group in
            for (id, url) in videoSelections {
                group.addTask { @MainActor in (id, try? await preparer.poster(for: url)) }
            }
            for await (id, poster) in group {
                guard !mediaClosed, !Task.isCancelled else { group.cancelAll(); continue }
                updatePending(id) { $0.image = poster }
            }
        }
    }

    private func updatePending(_ id: UUID, update: (inout PendingAttachment) -> Void) {
        guard let index = pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
        update(&pendingAttachments[index])
    }

    private func removePending(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    private func failPending(_ id: UUID, error: Error = VideoPreparationError.importing) {
        removePending(id)
        lastError = .videoPreparation(error as? VideoPreparationError ?? .processing)
        submissionState = .error
    }

    private func flushReadyAttachments() {
        // Commit only the ready prefix so images after a video keep their selected position.
        while let first = pendingAttachments.first, !first.isPreparing {
            pendingAttachments.removeFirst()
            guard let image = first.image else { continue }
            if let video = first.video { videos[screenshots.count] = video }
            screenshots.append(image)
        }
    }

    private func clearPendingAttachments() {
        pendingAttachments.compactMap(\.video).forEach { try? FileManager.default.removeItem(at: $0.file) }
        pendingAttachments = []
    }

    func cleanupVideos() {
        mediaClosed = true
        isPreparingMedia = false
        clearPendingAttachments()
        preparationTask?.cancel()
        preparationTask = nil
        videos.values.forEach { try? FileManager.default.removeItem(at: $0.file) }
        videos = [:]
    }

    /// Removes the attachment at `index`, ignoring out-of-bounds indices.
    func removeScreenshot(at index: Int) {
        guard screenshots.indices.contains(index) else { return }
        if let video = videos[index] { try? FileManager.default.removeItem(at: video.file) }
        videos = Dictionary(uniqueKeysWithValues: videos.filter { $0.key != index }
            .map { ($0.key > index ? $0.key - 1 : $0.key, $0.value) })
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

    /// Replaces the attachment at `index` with an edited (marked-up) copy,
    /// ignoring out-of-bounds indices. Clearing `placeholderIndex` when it
    /// matches the edited slot stops a late auto-attach upgrade from
    /// overwriting the user's markup; it also makes the form `isDirty`.
    func replaceScreenshot(at index: Int, with image: UIImage) {
        guard videos[index] == nil, screenshots.indices.contains(index) else { return }
        screenshots[index] = image
        if placeholderIndex == index {
            placeholderIndex = nil
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

    func loadConfigurationIfNeeded() {
        guard !configurationLoadStarted else { return }
        configurationLoadStarted = true
        Task { await loadConfiguration(forceRefresh: false) }
    }

    func retryConfiguration() {
        Task { await loadConfiguration(forceRefresh: true) }
    }

    private func loadConfiguration(forceRefresh: Bool) async {
        configurationState = .loading
        switch await configurationLoader(forceRefresh) {
        case let .ready(configuration):
            copy = configuration.copy
            showBranding = configuration.showBranding
            reportTypes = configuration.reportTypes
            bugType = configuration.reportTypes.first
            severityEnabled = configuration.severityEnabled
            videoAttachmentLimits = configuration.videoAttachmentLimits
            configurationState = .ready
        case .unavailable:
            configurationState = .error
        case .notReady, .credentialRejected:
            onDismiss()
        }
    }

    /// Submits the bug report to the backend.
    func submit() async {
        guard canSubmit else { return }
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
            // Downscale + re-encode before the transport sees them. Preparation is the
            // reporter's job precisely because the transport is what a host replaces
            // (RFC-003 §2.2), and on iOS it must also happen before a share extension's
            // images cross the process boundary (COMP-004).
            //
            // Off the main actor: preparing 4 retina screenshots can spend 1+ s of CPU
            // time, and this type is `@MainActor`, so doing it inline would freeze the
            // sheet mid-submit.
            let toPrepare = screenshots.enumerated().filter { videos[$0.offset] == nil }.map(\.element)
            let prepared = await Task.detached(priority: .userInitiated) {
                toPrepare.compactMap(ScreenshotPreparation.prepare)
            }.value

            guard prepared.count == toPrepare.count else { throw BugScreenSDKError.encodingError }

            let response: ReportReceipt
            if !videos.isEmpty, let videoSubmitter = submitter as? VideoReportSubmitting {
                var imageIndex = 0
                var videoIndex = 0
                let order = screenshots.indices.map { index -> ReportMediaOrder in
                    let isVideo = videos[index] != nil
                    defer {
                        if isVideo {
                            videoIndex += 1
                        } else {
                            imageIndex += 1
                        }
                    }
                    return ReportMediaOrder(isVideo: isVideo, index: isVideo ? videoIndex : imageIndex)
                }
                response = try await videoSubmitter.submitVideoBugReport(description: trimmed, screenshots: prepared,
                                                                         videos: videos.sorted { $0.key < $1.key }.map(\.value),
                                                                         visualOrder: order,
                                                                         type: bugType, severity: severityEnabled ? severity.apiValue : nil)
            } else {
                response = try await submitter.submitBugReport(description: trimmed, screenshots: prepared,
                                                               type: bugType, severity: severityEnabled ? severity.apiValue : nil)
            }

            partialFailures = response.partialFailures
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
        onSuccess: @escaping ([ReportPartialFailure]) -> Void
    ) {
        self.onDismiss = onDismiss
        self.onSuccess = onSuccess
    }

    /// Resets the form after successful submission.
    func reset() {
        cleanupVideos()
        mediaClosed = false
        description = ""
        screenshots = []
        bugType = reportTypes.first
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

    enum ConfigurationState: Equatable {
        case loading
        case ready
        case error
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
