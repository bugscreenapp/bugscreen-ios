import AVFoundation
@testable import BugScreenSDK
import UIKit
import XCTest

@MainActor
final class RecentVideoTests: XCTestCase {
    private let limits = VideoAttachmentLimits(maxSizeBytes: 50_000_000, maxDurationSeconds: 60)

    func testCompressedFixtureRemuxesWithoutAudioOrReencodingAndFullyDecodes() async throws {
        let samples = try await fixtureSamples()
        let selected = EncodedRecordingBuffer.selection(samples, maximumDuration: 5, endingAt: 1.2)
        XCTAssertFalse(selected.isEmpty)
        let file = try RecordingFileStore.newFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try await RecordingExporter.write(selected, to: file, check: {})
        let bytes = try Data(contentsOf: file)
        let prepared = try await VideoPreparation.adoptGenerated(file, limits: limits, check: {})
        XCTAssertEqual(prepared.file, file)
        XCTAssertEqual(try Data(contentsOf: prepared.file), bytes, "Adoption must not encode or replace the MP4")
        XCTAssertLessThanOrEqual(prepared.durationSeconds, 5)
        let audioTracks = try await AVURLAsset(url: file).loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty)
    }

    func testActualRemuxRespectsThirtyAndSixtySecondCeilings() async throws {
        let oneClip = try await fixtureSamples()
        let end = try XCTUnwrap(oneClip.last)
        let span = end.timestamp + end.duration
        var history: [RecordedSample] = []
        for repetition in 0 ..< Int(ceil(65 / span)) {
            history += oneClip.map {
                RecordedSample(buffer: $0.buffer, timestamp: $0.timestamp + Double(repetition) * span,
                               duration: $0.duration, bytes: $0.bytes, keyframe: $0.keyframe)
            }
        }
        for duration in [30.0, 60.0] {
            let frozen = FrozenRecording(maximumDuration: duration, triggerTimestamp: Double(Int(ceil(65 / span))) * span)
            frozen.install(history)
            let prepared = try await frozen.prepare(limits: limits)
            XCTAssertLessThanOrEqual(prepared.durationSeconds, duration)
            XCTAssertGreaterThanOrEqual(prepared.durationSeconds, duration - 1.001)
            try? FileManager.default.removeItem(at: prepared.file)
        }
    }

    func testAutomaticVideoWaitsForConfigRetryAndUntouchedDraftCanDismiss() async throws {
        var ready = false
        var loads = 0
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("owned test file".utf8).write(to: file)
        let controller = BugReportHostingController(host: ReporterHost(submitter: RecentSubmitter(), showBranding: false,
                                                                       configurationLoader: { _ in ready ? .ready(ReporterConfiguration(
                                                                           showBranding: false,
                                                                           reportTypes: [],
                                                                           videoAttachmentLimits: self.limits
                                                                       )) : .unavailable }),
                                                    automaticVideo: AutomaticVideoSource(load: { _ in
                                                        loads += 1
                                                        return PreparedVideo(
                                                            file: file,
                                                            poster: TestHelpers.solidImage(),
                                                            durationSeconds: 3
                                                        )
                                                    }))
        controller.viewModel.loadConfigurationIfNeeded()
        await flush()
        XCTAssertEqual(loads, 0)
        ready = true
        controller.viewModel.retryConfiguration()
        await flush()
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(controller.viewModel.videos.count, 1)
        XCTAssertTrue(controller.viewModel.canDismissWithoutConfirmation)
        controller.viewModel.description = "Edited description"
        XCTAssertFalse(controller.viewModel.canDismissWithoutConfirmation)
        controller.viewModel.removeScreenshot(at: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        controller.dismissFromHost()
    }

    func testAutomaticClipUsesFourthSlotAndFullDraftDoesNotBlockSubmission() async throws {
        for count in [3, 4] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("owned slot test".utf8).write(to: file)
            var loads = 0
            let originalImages = (0 ..< count).map { _ in TestHelpers.solidImage() }
            let controller = BugReportHostingController(host: ReporterHost(submitter: RecentSubmitter(), showBranding: false,
                                                                           configurationLoader: { _ in .ready(ReporterConfiguration(
                                                                               showBranding: false,
                                                                               reportTypes: [],
                                                                               videoAttachmentLimits: self.limits
                                                                           )) }),
                                                        screenshots: originalImages,
                                                        automaticVideo: AutomaticVideoSource(load: { _ in
                                                            loads += 1
                                                            return PreparedVideo(
                                                                file: file,
                                                                poster: TestHelpers.solidImage(),
                                                                durationSeconds: 3
                                                            )
                                                        }, cancel: { if loads == 0 { try? FileManager.default.removeItem(at: file) } }))
            controller.viewModel.loadConfigurationIfNeeded()
            await flush()
            XCTAssertEqual(loads, count == 3 ? 1 : 0)
            XCTAssertEqual(controller.viewModel.screenshots.count, 4)
            XCTAssertTrue(controller.viewModel.canSubmit)
            XCTAssertFalse(controller.viewModel.isPreparingMedia)
            for (actual, original) in zip(controller.viewModel.screenshots, originalImages) {
                XCTAssertTrue(actual === original)
            }
            if count == 4 {
                XCTAssertEqual(controller.viewModel.lastError?.userMessage, SDKStrings.recordingFailure("noSlot"))
                XCTAssertEqual(controller.viewModel.lastError?.userMessage,
                               "Recent video was not attached because this report already has four attachments. You can still submit this report.")
                XCTAssertEqual(controller.viewModel.submissionState, .error)
            } else {
                XCTAssertNil(controller.viewModel.lastError)
                XCTAssertEqual(controller.viewModel.submissionState, .idle)
            }
            controller.dismissFromHost()
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testRepeatedReadyCallbacksOnlyStartAutomaticAdoptionOnce() async throws {
        var loads = 0
        var continuation: CheckedContinuation<PreparedVideo, Error>?
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("owned single adoption".utf8).write(to: file)
        let controller = BugReportHostingController(host: ReporterHost(submitter: RecentSubmitter(), showBranding: false,
                                                                       configurationLoader: { _ in .ready(ReporterConfiguration(
                                                                           showBranding: false,
                                                                           reportTypes: [],
                                                                           videoAttachmentLimits: self.limits
                                                                       )) }),
                                                    automaticVideo: AutomaticVideoSource(load: { _ in
                                                        loads += 1
                                                        return try await withCheckedThrowingContinuation { continuation = $0 }
                                                    }))
        controller.viewModel.loadConfigurationIfNeeded()
        await flush()
        controller.viewModel.retryConfiguration()
        controller.viewModel.retryConfiguration()
        await flush()
        XCTAssertEqual(loads, 1)
        XCTAssertTrue(controller.viewModel.isPreparingMedia)
        continuation?.resume(returning: PreparedVideo(file: file, poster: TestHelpers.solidImage(), durationSeconds: 3))
        await flush()
        XCTAssertEqual(controller.viewModel.videos.count, 1)
        XCTAssertFalse(controller.viewModel.isPreparingMedia)
        controller.dismissFromHost()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testUnavailableRecordingShowsReasonAndDoesNotBlockOrdinaryReport() async {
        let controller = BugReportHostingController(host: ReporterHost(submitter: RecentSubmitter(), showBranding: false,
                                                                       configurationLoader: { _ in .ready(ReporterConfiguration(
                                                                           showBranding: false,
                                                                           reportTypes: [],
                                                                           videoAttachmentLimits: self.limits
                                                                       )) }),
                                                    automaticVideo: AutomaticVideoSource(load: { _ in
                                                        throw VideoPreparationError.recording("permissionDenied")
                                                    }))
        controller.viewModel.loadConfigurationIfNeeded()
        await flush()
        XCTAssertTrue(controller.viewModel.canSubmit)
        XCTAssertTrue(controller.viewModel.videos.isEmpty)
        XCTAssertEqual(controller.viewModel.lastError?.userMessage, SDKStrings.recordingFailure("permissionDenied"))
        controller.dismissFromHost()
    }

    func testDismissalDeletesLateUnclaimedAutomaticFile() async throws {
        var continuation: CheckedContinuation<PreparedVideo, Error>?
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("owned late file".utf8).write(to: file)
        let controller = BugReportHostingController(host: ReporterHost(submitter: RecentSubmitter(), showBranding: false,
                                                                       configurationLoader: { _ in .ready(ReporterConfiguration(
                                                                           showBranding: false,
                                                                           reportTypes: [],
                                                                           videoAttachmentLimits: self.limits
                                                                       )) }),
                                                    automaticVideo: AutomaticVideoSource(load: { _ in
                                                        try await withCheckedThrowingContinuation { continuation = $0 }
                                                    }))
        controller.viewModel.loadConfigurationIfNeeded()
        await flush()
        XCTAssertTrue(controller.viewModel.isPreparingMedia)
        controller.dismissFromHost()
        continuation?.resume(returning: PreparedVideo(file: file, poster: TestHelpers.solidImage(), durationSeconds: 3))
        await flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(controller.viewModel.videos.isEmpty)
    }

    private func fixtureSamples() async throws -> [RecordedSample] {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "generated-recording", withExtension: "mp4", subdirectory: "Fixtures"))
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [RecordedSample] = []
        while let buffer = output.copyNextSampleBuffer() {
            // AVAssetReader also emits empty boundary markers, which are not encoder frames.
            guard CMSampleBufferGetTotalSampleSize(buffer) > 0,
                  CMSampleBufferGetFormatDescription(buffer) != nil else { continue }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
            samples.append(RecordedSample(buffer: buffer, timestamp: CMSampleBufferGetPresentationTimeStamp(buffer).seconds,
                                          duration: CMSampleBufferGetDuration(buffer).seconds,
                                          bytes: CMSampleBufferGetTotalSampleSize(buffer),
                                          keyframe: attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true))
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(samples.count, 18)
        return samples
    }

    private func flush() async {
        for _ in 0 ..< 15 {
            await Task.yield()
        }
    }
}

private struct RecentSubmitter: VideoReportSubmitting {
    func submitBugReport(description _: String, screenshots _: [PreparedScreenshot], type _: String?,
                         severity _: String?) async throws -> ReportReceipt
    {
        ReportReceipt(partialFailures: [])
    }

    func submitVideoBugReport(
        description _: String,
        screenshots _: [PreparedScreenshot],
        videos _: [PreparedVideo],
        visualOrder _: [ReportMediaOrder],
        type _: String?,
        severity _: String?
    ) async throws -> ReportReceipt {
        ReportReceipt(partialFailures: [])
    }
}
