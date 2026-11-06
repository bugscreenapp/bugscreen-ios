@testable import BugScreenSDK
import Combine
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import ViewInspector
import XCTest

@MainActor
final class MediaImportFeedbackTests: XCTestCase {
    func testSharedMediaWaitsForConfigurationRetryThenUsesTheExistingMixedImportPipeline() async throws {
        let preparer = ControlledVideoPreparer()
        let source = try fixtureCopy()
        let output = try fixtureCopy()
        let unavailable = expectation(description: "Initial config failed")
        var attempts = 0
        var imports = 0
        let model = BugReportViewModel(onDismiss: {}, submitter: FeedbackSubmitter(), videoPreparer: preparer,
                                       configurationLoader: { _ in
                                           attempts += 1
                                           if attempts == 1 { unavailable.fulfill(); return .unavailable }
                                           return .ready(ReporterConfiguration(showBranding: false, reportTypes: [],
                                                                               videoAttachmentLimits: VideoAttachmentLimits(
                                                                                   maxSizeBytes: 10_000_000,
                                                                                   maxDurationSeconds: 60
                                                                               )))
                                       })
        model.description = "Shared recording"
        model.initialMediaCount = 2
        model.initialMediaLoader = { imports += 1; return [.video(source), .image(TestHelpers.solidImage())] }
        defer { model.cleanupVideos() }
        XCTAssertEqual(imports, 0)
        model.loadConfigurationIfNeeded()
        await fulfillment(of: [unavailable], timeout: 2)
        XCTAssertEqual(imports, 0)
        model.retryConfiguration()
        await fulfillment(of: [preparer.exportStarted], timeout: 2)
        XCTAssertEqual(imports, 1)
        XCTAssertFalse(model.canSubmit)
        let completed = expectation(description: "Shared import completed")
        let subscription = model.$isPreparingMedia.dropFirst().filter { !$0 }.sink { _ in completed.fulfill() }
        preparer.finish(.success(PreparedVideo(file: output, poster: preparer.poster, durationSeconds: 1)))
        await fulfillment(of: [completed], timeout: 2)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(model.screenshots.count, 2)
        XCTAssertNotNil(model.videos[0])
        XCTAssertTrue(model.canSubmit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testPickerDelegateReservesEveryCardBeforeProvidersFinishLoading() async throws {
        let model = makeModel()
        model.description = "Playback stutters"
        model.addScreenshots([TestHelpers.solidImage(), TestHelpers.solidImage()])
        XCTAssertTrue(model.canSubmit)
        defer { model.cleanupVideos() }
        let providers = [SuspendedMovieProvider(), SuspendedMovieProvider()]
        let picked = expectation(description: "Picker delivers the completed batch")
        var pickedCount: Int?
        let sheet = PhotoPickerSheet(selectionLimit: 2, includeVideos: true, onImportStarted: model.beginMediaImport) { items in
            pickedCount = items.count
            picked.fulfill()
        }
        // PhotosUI provides no public PHPickerResult initializer; inject only its provider projection.
        let coordinator = PhotoPickerSheet.Coordinator(sheet, itemProviders: { _ in providers })
        let picker = PHPickerViewController(configuration: PhotoPickerConfiguration.make(selectionLimit: 2, includeVideos: true))
        coordinator.picker(picker, didFinishPicking: [])

        XCTAssertTrue(providers.allSatisfy { $0.completion != nil })
        XCTAssertNil(pickedCount)
        XCTAssertEqual(model.pendingAttachments.count, 2)
        XCTAssertEqual(model.attachmentCount, 4)
        XCTAssertEqual(model.remainingScreenshotSlots, 0)
        XCTAssertTrue(model.isPreparingMedia)
        XCTAssertFalse(model.canSubmit)
        let cards = try BugReportView(viewModel: model).inspect().findAll(AttachmentThumb.self)
        XCTAssertEqual(try cards.filter { try $0.actualView().isPreparing }.count, 2)

        providers.forEach { $0.completion?(nil, ImportFailure()) }
        await fulfillment(of: [picked], timeout: 2)
        XCTAssertEqual(pickedCount, 2)
    }

    func testPickerDelegateCancellationDoesNotReserveCardsOrStartImport() {
        let model = makeModel()
        model.description = "Playback stutters"
        XCTAssertTrue(model.canSubmit)
        let sheet = PhotoPickerSheet(selectionLimit: 4, includeVideos: true, onImportStarted: model.beginMediaImport) { _ in
            XCTFail("Cancelling the picker must not start an import")
        }
        let picker = PHPickerViewController(configuration: PhotoPickerConfiguration.make(selectionLimit: 4, includeVideos: true))
        sheet.makeCoordinator().picker(picker, didFinishPicking: [])
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        XCTAssertFalse(model.isPreparingMedia)
        XCTAssertTrue(model.canSubmit)
    }

    func testPickerImportImmediatelyShowsSpinnerCardWithoutStatusText() throws {
        let model = makeModel()
        model.beginMediaImport()
        let view = try BugReportView(viewModel: model).inspect()

        XCTAssertNoThrow(try view.find(ViewType.ProgressView.self))
        XCTAssertThrowsError(try view.find(button: "Add"))
        XCTAssertFalse(model.canSubmit)
        let pendingCard = try BugReportView(viewModel: model).inspect().find(AttachmentThumb.self).actualView()
        XCTAssertTrue(pendingCard.isPreparing)
        XCTAssertFalse(pendingCard.enabled)
        XCTAssertThrowsError(
            try pendingCard.inspect().find(ViewType.Button.self),
            "The pending card must stay non-interactive without disabled-button dimming"
        )
        XCTAssertThrowsError(try view.find(text: SDKStrings.attachmentProcessing))
    }

    func testPosterIsVisibleWhileExportIsSuspendedAndReadyAttachmentsKeepOrder() async throws {
        let preparer = ControlledVideoPreparer()
        let model = makeModel(preparer: preparer)
        let source = try fixtureCopy()
        let output = try fixtureCopy()
        defer { model.cleanupVideos() }
        let work = Task {
            await model.addPickedAttachments([.image(TestHelpers.solidImage()), .video(source), .image(TestHelpers.solidImage())])
        }
        await fulfillment(of: [preparer.exportStarted], timeout: 2)

        XCTAssertTrue(model.pendingAttachments.first?.image === preparer.poster)
        XCTAssertTrue(model.isPreparingMedia)
        XCTAssertEqual(model.screenshots.count, 1)
        XCTAssertTrue(model.videos.isEmpty)
        XCTAssertFalse(model.canSubmit)
        let cards = try BugReportView(viewModel: model).inspect().findAll(AttachmentThumb.self)
        let pendingCard = try XCTUnwrap(cards.first { try $0.actualView().isPreparing }).actualView()
        XCTAssertTrue(pendingCard.image === preparer.poster)
        XCTAssertTrue(pendingCard.isPreparing)

        preparer.finish(.success(PreparedVideo(file: output, poster: preparer.poster, durationSeconds: 1)))
        await work.value
        XCTAssertFalse(model.isPreparingMedia)
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        XCTAssertEqual(model.screenshots.count, 3)
        XCTAssertNotNil(model.videos[1])
        XCTAssertTrue(model.canSubmit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testFailedExportRemovesPendingCardAndPreservesOtherAttachments() async throws {
        let preparer = ControlledVideoPreparer()
        let model = makeModel(preparer: preparer)
        let source = try fixtureCopy()
        let work = Task {
            await model.addPickedAttachments([.video(source), .image(TestHelpers.solidImage())])
        }
        await fulfillment(of: [preparer.exportStarted], timeout: 2)
        preparer.finish(.failure(ImportFailure()))
        await work.value

        XCTAssertFalse(model.isPreparingMedia)
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        XCTAssertEqual(model.screenshots.count, 1)
        XCTAssertTrue(model.videos.isEmpty)
        XCTAssertEqual(model.submissionState, .error)
        XCTAssertEqual(model.lastError?.userMessage, SDKStrings.videoFailure("processing"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testSpecificPreparationStagesReachThePrimaryReporterMessage() async throws {
        let failures: [(VideoPreparationError, String)] = [
            (.configuration, "configuration"), (.importing, "import"), (.container, "container"),
            (.empty, "empty"), (.decoding, "decode"), (.videoTrack, "track"), (.resolution, "resolution"),
            (.duration, "duration"), (.encoding, "encoding"), (.preview, "preview"),
        ]
        for (failure, key) in failures {
            let preparer = ControlledVideoPreparer()
            let model = makeModel(preparer: preparer)
            let source = try fixtureCopy()
            let work = Task { await model.addPickedAttachments([.video(source), .image(TestHelpers.solidImage())]) }
            await fulfillment(of: [preparer.exportStarted], timeout: 2)
            preparer.finish(.failure(failure))
            await work.value
            XCTAssertEqual(model.lastError?.userMessage, SDKStrings.videoFailure(key))
            XCTAssertNil(model.lastError?.technicalDetail)
            XCTAssertEqual(model.screenshots.count, 1)
            XCTAssertTrue(model.videos.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testEmptyPickerVideoPreservesItsSpecificCopyFailureInTheReporter() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let model = makeModel()
        model.addScreenshots([TestHelpers.solidImage()])
        let provider = SuspendedMovieProvider()
        let received = expectation(description: "Picker returns the empty-file failure")
        var picked: [PickedAttachment] = []
        let sheet = PhotoPickerSheet(selectionLimit: 1, includeVideos: true, onImportStarted: model.beginMediaImport) {
            picked = $0
            received.fulfill()
        }
        let coordinator = PhotoPickerSheet.Coordinator(sheet, itemProviders: { _ in [provider] })
        let picker = PHPickerViewController(configuration: PhotoPickerConfiguration.make(selectionLimit: 1, includeVideos: true))
        coordinator.picker(picker, didFinishPicking: [])
        provider.completion?(source, nil)
        await fulfillment(of: [received], timeout: 2)
        await model.addPickedAttachments(picked)
        XCTAssertEqual(model.lastError?.userMessage, SDKStrings.videoFailure("empty"))
        XCTAssertEqual(model.screenshots.count, 1)
        XCTAssertTrue(model.videos.isEmpty)
    }

    func testDiscardClearsPendingPosterAndCleansLateExportResult() async throws {
        let preparer = ControlledVideoPreparer()
        let model = makeModel(preparer: preparer)
        let source = try fixtureCopy()
        let output = try fixtureCopy()
        let work = Task { await model.addPickedAttachments([.video(source)]) }
        await fulfillment(of: [preparer.exportStarted], timeout: 2)

        model.cleanupVideos()
        XCTAssertFalse(model.isPreparingMedia)
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        preparer.finish(.success(PreparedVideo(file: output, poster: preparer.poster, durationSeconds: 1)))
        await work.value
        XCTAssertTrue(model.screenshots.isEmpty)
        XCTAssertTrue(model.videos.isEmpty)
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        XCTAssertNil(model.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testDiscardBeforePosterCompletesDoesNotPublishItOrStartExport() async throws {
        let preparer = ControlledVideoPreparer()
        preparer.holdPoster = true
        let model = makeModel(preparer: preparer)
        let source = try fixtureCopy()
        let work = Task { await model.addPickedAttachments([.video(source)]) }
        await fulfillment(of: [preparer.posterStarted], timeout: 2)

        model.cleanupVideos()
        preparer.finishPoster()
        await work.value
        XCTAssertFalse(preparer.exportRequested)
        XCTAssertFalse(model.isPreparingMedia)
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        XCTAssertTrue(model.screenshots.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testPosterFailureStillAllowsExportAndSpinnerUntilCompletion() async throws {
        let preparer = ControlledVideoPreparer()
        preparer.posterFails = true
        let model = makeModel(preparer: preparer)
        let source = try fixtureCopy()
        let output = try fixtureCopy()
        defer { model.cleanupVideos() }
        let work = Task { await model.addPickedAttachments([.video(source)]) }
        await fulfillment(of: [preparer.exportStarted], timeout: 2)
        XCTAssertTrue(model.isPreparingMedia)
        XCTAssertNil(model.pendingAttachments.first?.image)

        preparer.finish(.success(PreparedVideo(file: output, poster: preparer.poster, durationSeconds: 1)))
        await work.value
        XCTAssertEqual(model.screenshots.count, 1)
        XCTAssertNil(model.lastError)
    }

    func testPickerReservesEverySelectedCardAndCountsPendingSlots() throws {
        let model = makeModel()
        model.addScreenshots([TestHelpers.solidImage()])
        model.beginMediaImport(count: 3)
        let view = try BugReportView(viewModel: model).inspect()
        let cards = try view.findAll(AttachmentThumb.self).map { try $0.actualView() }

        XCTAssertEqual(cards.count, 4)
        XCTAssertEqual(cards.filter(\.isPreparing).count, 3)
        XCTAssertEqual(view.findAll(ViewType.ProgressView.self).count, 3)
        XCTAssertEqual(model.attachmentCount, 4)
        XCTAssertEqual(model.remainingScreenshotSlots, 0)
        XCTAssertFalse(model.canAddMoreScreenshots)
        XCTAssertFalse(model.canSubmit)
        XCTAssertThrowsError(try view.find(button: "Add"))
        XCTAssertThrowsError(try view.find(text: SDKStrings.attachmentProcessing))
    }

    func testBatchPostersAppearTogetherAndSpinnersClearIndividuallyInSelectionOrder() async throws {
        let sources = try [fixtureCopy(), fixtureCopy()]
        let outputs = try [fixtureCopy(), fixtureCopy()]
        let preparer = BatchVideoPreparer(sources: sources)
        let model = makeModel(preparer: preparer)
        let images = [TestHelpers.solidImage(), TestHelpers.solidImage()]
        defer { model.cleanupVideos() }
        model.beginMediaImport(count: 4)
        let reservedIDs = model.pendingAttachments.map(\.id)
        let work = Task {
            await model.addPickedAttachments([.video(sources[0]), .image(images[0]), .video(sources[1]), .image(images[1])])
        }
        await fulfillment(of: [preparer.exportStarted[0]], timeout: 2)
        XCTAssertEqual(model.pendingAttachments.map(\.id), reservedIDs)
        let cards = try BugReportView(viewModel: model).inspect().findAll(AttachmentThumb.self).map { try $0.actualView() }
        XCTAssertEqual(cards.count, 4)
        XCTAssertTrue(cards[0].image === preparer.posters[0])
        XCTAssertTrue(cards[1].image === images[0])
        XCTAssertTrue(cards[2].image === preparer.posters[1])
        XCTAssertTrue(cards[3].image === images[1])
        XCTAssertEqual(cards.map(\.isPreparing), [true, false, true, false])
        XCTAssertTrue(model.screenshots.isEmpty)
        XCTAssertFalse(model.canSubmit)

        preparer.finish(
            source: sources[0],
            result: .success(PreparedVideo(file: outputs[0], poster: preparer.posters[0], durationSeconds: 1))
        )
        await fulfillment(of: [preparer.exportStarted[1]], timeout: 2)
        XCTAssertEqual(model.screenshots.count, 2)
        XCTAssertTrue(model.screenshots[1] === images[0])
        XCTAssertEqual(model.attachmentCount, 4)
        XCTAssertEqual(model.pendingAttachments.filter(\.isPreparing).count, 1)
        XCTAssertNotNil(model.videos[0])
        XCTAssertFalse(model.canSubmit)

        preparer.finish(
            source: sources[1],
            result: .success(PreparedVideo(file: outputs[1], poster: preparer.posters[1], durationSeconds: 1))
        )
        await work.value
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        XCTAssertEqual(model.screenshots.count, 4)
        XCTAssertTrue(model.screenshots[3] === images[1])
        XCTAssertNotNil(model.videos[2])
        XCTAssertTrue(model.canSubmit)
        XCTAssertTrue(sources.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testSlowPosterDoesNotPreventOtherSelectedVideoPosterAppearing() async throws {
        let sources = try [fixtureCopy(), fixtureCopy()]
        let preparer = BatchVideoPreparer(sources: sources)
        preparer.holdFirstPoster = true
        let model = makeModel(preparer: preparer)
        let work = Task { await model.addPickedAttachments(sources.map(PickedAttachment.video)) }
        await fulfillment(of: [preparer.postersStarted], timeout: 2)
        // Let the task-group consumer publish the completed second poster.
        for _ in 0 ..< 20 where model.pendingAttachments.last?.image == nil {
            await Task.yield()
        }
        XCTAssertEqual(model.pendingAttachments.count, 2)
        XCTAssertNil(model.pendingAttachments[0].image)
        XCTAssertTrue(model.pendingAttachments[1].image === preparer.posters[1])
        XCTAssertTrue(model.pendingAttachments.allSatisfy(\.isPreparing))

        model.cleanupVideos()
        preparer.finishFirstPoster()
        await work.value
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        XCTAssertTrue(preparer.exportedSources.isEmpty)
        XCTAssertTrue(sources.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testFailedBatchItemLeavesOtherVideoVisibleAndAllowsItToFinish() async throws {
        let sources = try [fixtureCopy(), fixtureCopy()]
        let output = try fixtureCopy()
        let preparer = BatchVideoPreparer(sources: sources)
        let model = makeModel(preparer: preparer)
        defer { model.cleanupVideos() }
        let work = Task { await model.addPickedAttachments(sources.map(PickedAttachment.video)) }
        await fulfillment(of: [preparer.exportStarted[0]], timeout: 2)
        let survivingID = model.pendingAttachments[1].id
        preparer.finish(source: sources[0], result: .failure(ImportFailure()))
        await fulfillment(of: [preparer.exportStarted[1]], timeout: 2)
        XCTAssertEqual(model.pendingAttachments.map(\.id), [survivingID])
        XCTAssertTrue(model.pendingAttachments[0].image === preparer.posters[1])
        XCTAssertFalse(model.canSubmit)
        XCTAssertNotNil(model.lastError)

        preparer.finish(source: sources[1], result: .success(PreparedVideo(file: output, poster: preparer.posters[1], durationSeconds: 1)))
        await work.value
        XCTAssertEqual(model.screenshots.count, 1)
        XCTAssertNotNil(model.videos[0])
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        XCTAssertTrue(model.canSubmit)
        XCTAssertTrue(sources.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testDiscardBatchRemovesAllCardsAndCleansLateResultWithoutStartingNextExport() async throws {
        let sources = try [fixtureCopy(), fixtureCopy()]
        let output = try fixtureCopy()
        let preparer = BatchVideoPreparer(sources: sources)
        let model = makeModel(preparer: preparer)
        let work = Task { await model.addPickedAttachments(sources.map(PickedAttachment.video)) }
        await fulfillment(of: [preparer.exportStarted[0]], timeout: 2)
        model.cleanupVideos()
        XCTAssertTrue(model.pendingAttachments.isEmpty)
        XCTAssertFalse(model.isPreparingMedia)
        preparer.finish(source: sources[0], result: .success(PreparedVideo(file: output, poster: preparer.posters[0], durationSeconds: 1)))
        await work.value
        XCTAssertEqual(preparer.exportedSources, [sources[0]])
        XCTAssertTrue(model.screenshots.isEmpty)
        XCTAssertTrue(model.videos.isEmpty)
        XCTAssertNil(model.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(sources.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    private func makeModel(preparer: VideoPreparing = DefaultVideoPreparer()) -> BugReportViewModel {
        BugReportViewModel(onDismiss: {}, submitter: FeedbackSubmitter(), videoPreparer: preparer,
                           videoAttachmentLimits: VideoAttachmentLimits(maxSizeBytes: 10_000_000, maxDurationSeconds: 60))
    }

    private func fixtureCopy() throws -> URL {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "valid.mp4", withExtension: nil, subdirectory: "Fixtures"))
        return try VideoPreparation.copySelection(fixture)
    }
}

private struct ImportFailure: Error {}

private final class SuspendedMovieProvider: NSItemProvider {
    var completion: (@Sendable (URL?, Error?) -> Void)?

    override func hasItemConformingToTypeIdentifier(_ typeIdentifier: String) -> Bool {
        typeIdentifier == UTType.movie.identifier
    }

    override func loadFileRepresentation(forTypeIdentifier _: String,
                                         completionHandler: @escaping @Sendable (URL?, Error?) -> Void) -> Progress
    {
        completion = completionHandler
        return Progress(totalUnitCount: 1)
    }
}

@MainActor
private final class ControlledVideoPreparer: VideoPreparing {
    let poster = TestHelpers.solidImage()
    let posterStarted = XCTestExpectation(description: "Poster extraction started")
    let exportStarted = XCTestExpectation(description: "Export started after poster generation")
    var posterFails = false
    var holdPoster = false
    private(set) var exportRequested = false
    private var posterContinuation: CheckedContinuation<UIImage, Error>?
    private var continuation: CheckedContinuation<PreparedVideo, Error>?

    func poster(for _: URL) async throws -> UIImage {
        posterStarted.fulfill()
        if posterFails { throw ImportFailure() }
        if holdPoster {
            return try await withCheckedThrowingContinuation { posterContinuation = $0 }
        }
        return poster
    }

    func prepare(_: URL, limits _: VideoAttachmentLimits) async throws -> PreparedVideo {
        exportRequested = true
        return try await withCheckedThrowingContinuation {
            continuation = $0
            exportStarted.fulfill()
        }
    }

    func finishPoster() {
        posterContinuation?.resume(returning: poster)
        posterContinuation = nil
    }

    func finish(_ result: Result<PreparedVideo, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

@MainActor
private final class FeedbackSubmitter: VideoReportSubmitting {
    func submitBugReport(description _: String, screenshots _: [PreparedScreenshot], type _: String?,
                         severity _: String?) async throws -> ReportReceipt
    {
        ReportReceipt(partialFailures: [])
    }

    func submitVideoBugReport(description _: String, screenshots _: [PreparedScreenshot], videos _: [PreparedVideo],
                              visualOrder _: [ReportMediaOrder], type _: String?, severity _: String?) async throws -> ReportReceipt
    {
        ReportReceipt(partialFailures: [])
    }
}

@MainActor
private final class BatchVideoPreparer: VideoPreparing {
    let sources: [URL]
    let posters = [TestHelpers.solidImage(), TestHelpers.solidImage()]
    let postersStarted = XCTestExpectation(description: "All source posters started")
    let exportStarted = [XCTestExpectation(description: "First export started"), XCTestExpectation(description: "Second export started")]
    var holdFirstPoster = false
    private(set) var exportedSources: [URL] = []
    private var posterContinuation: CheckedContinuation<UIImage, Error>?
    private var continuations: [URL: CheckedContinuation<PreparedVideo, Error>] = [:]

    init(sources: [URL]) {
        self.sources = sources
        postersStarted.expectedFulfillmentCount = sources.count
    }

    func poster(for source: URL) async throws -> UIImage {
        let index = sources.firstIndex(of: source)!
        if index == 0, holdFirstPoster {
            return try await withCheckedThrowingContinuation {
                posterContinuation = $0
                postersStarted.fulfill()
            }
        }
        postersStarted.fulfill()
        return posters[index]
    }

    func prepare(_ source: URL, limits _: VideoAttachmentLimits) async throws -> PreparedVideo {
        exportedSources.append(source)
        return try await withCheckedThrowingContinuation {
            continuations[source] = $0
            exportStarted[sources.firstIndex(of: source)!].fulfill()
        }
    }

    func finishFirstPoster() {
        posterContinuation?.resume(returning: posters[0])
        posterContinuation = nil
    }

    func finish(source: URL, result: Result<PreparedVideo, Error>) {
        continuations.removeValue(forKey: source)?.resume(with: result)
    }
}
