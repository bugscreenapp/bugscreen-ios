import AVFoundation
@testable import BugScreenSDK
import UIKit
import XCTest

@MainActor
final class VideoPreparationTests: XCTestCase {
    private let limits = VideoAttachmentLimits(maxSizeBytes: 10_000_000, maxDurationSeconds: 60)
    private func source(_ name: String) throws -> URL {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try VideoPreparation.copySelection(fixture)
    }

    func testEncoderTargetsFourMegabitsWithoutChangingFrameTimingOrUpscaling() {
        let settings = VideoEncoder.videoSettings(size: CGSize(width: 640, height: 480), scale: 1)
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Int]
        XCTAssertEqual(compression?[AVVideoAverageBitRateKey], 4_000_000)
        XCTAssertEqual(settings[AVVideoWidthKey] as? Int, 640)
        XCTAssertEqual(settings[AVVideoHeightKey] as? Int, 480)
        XCTAssertNil(compression?[AVVideoExpectedSourceFrameRateKey])
    }

    func testPreparationFailuresReachThePrimaryReporterMessageWithFetchedLimits() async throws {
        for (policy, expected) in [(VideoAttachmentLimits(maxSizeBytes: 1, maxDurationSeconds: 120), "0.00 MB"),
                                   (VideoAttachmentLimits(maxSizeBytes: 50_000_000, maxDurationSeconds: 0.01), "0.01 seconds")]
        {
            let model = BugReportViewModel(onDismiss: {}, submitter: VideoSubmitter(), videoAttachmentLimits: policy)
            await model.addPickedAttachments([.video(try source("valid.mp4"))])
            XCTAssertTrue(model.videos.isEmpty)
            XCTAssertTrue(model.lastError?.userMessage.contains(expected) == true, model.lastError?.userMessage ?? "Missing error")
            XCTAssertNil(model.lastError?.technicalDetail)
        }
    }

    func testServerVideoValidationIsVisibleInsteadOfAConfigOrGenericError() {
        let message = "Prepared video audio must use AAC encoding"
        let error = BugScreenSDKError.httpError(status: 400, code: "validation.video_type", message: message)
        XCTAssertEqual(error.userMessage, message)
        XCTAssertNotEqual(
            BugScreenSDKError.httpError(status: 500, code: "server.video_validation", message: "private").userMessage,
            "private"
        )
    }

    func testCancelledPreparationRemovesOwnedSourceAndDoesNotBecomeAValidationError() async throws {
        let selected = try source("overlong.mp4")
        let work = Task { try await VideoPreparation.prepare(selected, limits: limits) }
        work.cancel()
        do {
            _ = try await work.value
            XCTFail("Cancelled preparation must not succeed")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
    }

    func testCancellingAnActiveExportFinishesAndRemovesItsFiles() async throws {
        let selected = try source("overlong.mp4")
        let directory = FileManager.default.temporaryDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
        let work = Task {
            try await VideoPreparation.prepare(selected, limits: VideoAttachmentLimits(maxSizeBytes: 50_000_000, maxDurationSeconds: 120))
        }
        var activeOutput: URL?
        for _ in 0 ..< 500 {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            activeOutput = files
                .first { !before.contains($0) && $0.lastPathComponent.hasPrefix("bugscreen-video-") && $0.pathExtension == "mp4" }
            if activeOutput != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        work.cancel()
        let finished = expectation(description: "Active reader/writer cancellation completes")
        Task {
            defer { finished.fulfill() }
            do {
                let result = try await work.value
                try? FileManager.default.removeItem(at: result.file)
                XCTFail("Cancelled active export must not succeed")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertNotNil(activeOutput, "Cancellation must occur after writer output is created")
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
        if let activeOutput { XCTAssertFalse(FileManager.default.fileExists(atPath: activeOutput.path)) }
    }

    func testPreservesVariableFrameTimestampsAndAudioOffset() async throws {
        let selected = try source("variable-timing.mp4")
        let original = AVURLAsset(url: selected)
        let originalVideo = try await original.loadTracks(withMediaType: .video)[0]
        let originalAudio = try await original.loadTracks(withMediaType: .audio)[0]
        let expectedTimes = try presentationTimes(originalVideo, asset: original)
        let expectedAudioStart = try firstAudibleTime(originalAudio, asset: original)
        XCTAssertGreaterThan(expectedAudioStart, 0.2)
        XCTAssertGreaterThan(
            expectedTimes[1] - expectedTimes[0],
            try XCTUnwrap(expectedTimes.last) - expectedTimes[expectedTimes.count - 2]
        )
        let result = try await VideoPreparation.prepare(selected, limits: limits)
        defer { try? FileManager.default.removeItem(at: result.file) }
        let asset = AVURLAsset(url: result.file)
        let video = try await asset.loadTracks(withMediaType: .video)[0]
        let audio = try await asset.loadTracks(withMediaType: .audio)[0]
        let actualTimes = try presentationTimes(video, asset: asset)
        XCTAssertEqual(actualTimes.count, expectedTimes.count)
        for (actual, expected) in zip(actualTimes, expectedTimes) {
            XCTAssertEqual(actual, expected, accuracy: 0.001)
        }
        XCTAssertEqual(try firstAudibleTime(audio, asset: asset), expectedAudioStart, accuracy: 0.025)
    }

    func testSourceFileChecksIdentifyConfigurationImportEmptyContainerAndDecodeFailures() async throws {
        let malformedHeader = Data([0, 0, 0, 12] + Array("ftyp".utf8) + [0, 0, 0, 0])
        let cases: [(Data?, VideoAttachmentLimits, String)] = [
            (Data("unavailable settings".utf8), VideoAttachmentLimits(maxSizeBytes: 0, maxDurationSeconds: 60), "configuration"),
            (nil, limits, "import"), (Data(), limits, "empty"),
            (Data("not an MP4 or MOV container".utf8), limits, "container"), (malformedHeader, limits, "decode"),
        ]
        for (bytes, policy, reason) in cases {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString).mov")
            try bytes?.write(to: file)
            do {
                _ = try await VideoPreparation.prepare(file, limits: policy)
                XCTFail("Expected \(reason) failure")
            } catch {
                XCTAssertEqual((error as? VideoPreparationError)?.errorDescription, SDKStrings.videoFailure(reason))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testSourcePosterIsOrientationAwareAndDoesNotConsumeSelectedFile() async throws {
        let selected = try source("rotated.mov")
        defer { try? FileManager.default.removeItem(at: selected) }
        let poster = try await VideoPreparation.poster(for: selected)
        XCTAssertGreaterThan(poster.size.height, poster.size.width)
        XCTAssertLessThanOrEqual(max(poster.size.width, poster.size.height), 224)
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected.path))
    }

    func testExportsAudioAndRotatedMOVIntoPlayableH264MP4() async throws {
        let source = try source("rotated.mov")
        let sourceAsset = AVURLAsset(url: source)
        let expectedDuration = try await sourceAsset.load(.duration).seconds
        let sourceTracks = try await sourceAsset.loadTracks(withMediaType: .video)
        let expectedFrames = try frameCount(sourceTracks[0], asset: sourceAsset)
        let video = try await VideoPreparation.prepare(source, limits: limits)
        defer { try? FileManager.default.removeItem(at: video.file) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertGreaterThan(video.durationSeconds, 0)
        XCTAssertLessThanOrEqual(video.durationSeconds, 60)
        XCTAssertLessThanOrEqual(try video.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max, 10_000_000)
        let asset = AVURLAsset(url: video.file)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let formats = try await tracks[0].load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first)), kCMVideoCodecType_H264)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
        XCTAssertEqual(video.durationSeconds, expectedDuration, accuracy: 0.05)
        XCTAssertEqual(try frameCount(tracks[0], asset: asset), expectedFrames)
        let transform = try await tracks[0].load(.preferredTransform)
        let size = try await tracks[0].load(.naturalSize).applying(transform)
        XCTAssertLessThan(abs(size.width), abs(size.height))
        XCTAssertGreaterThan(video.poster.size.height, video.poster.size.width)
    }

    private func frameCount(_ track: AVAssetTrack, asset: AVAsset) throws -> Int {
        try presentationTimes(track, asset: asset).count
    }

    private func presentationTimes(_ track: AVAssetTrack, asset: AVAsset) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = track.mediaType == .video
            ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            : [AVFormatIDKey: kAudioFormatLinearPCM]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        XCTAssertEqual(reader.status, .completed)
        return times.sorted()
    }

    private func firstAudibleTime(_ track: AVAssetTrack, asset: AVAsset) throws -> Double {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: false,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetDataBuffer(sample),
                  let format = CMSampleBufferGetFormatDescription(sample),
                  let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format)
            else { continue }
            var bytes = [Int16](repeating: 0, count: CMBlockBufferGetDataLength(buffer) / 2)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            XCTAssertEqual(status, noErr)
            if let onset = bytes.firstIndex(where: { abs(Int($0)) > 256 }) {
                return CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    + Double(onset / Int(audio.pointee.mChannelsPerFrame)) / audio.pointee.mSampleRate
            }
        }
        XCTFail("Expected audible samples after the fixture's initial silence")
        return .nan
    }

    func testConvertsHEVCToH264WithoutRemovingAudio() async throws {
        let video = try await VideoPreparation.prepare(source("hevc.mov"), limits: limits)
        defer { try? FileManager.default.removeItem(at: video.file) }
        let asset = AVURLAsset(url: video.file)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let formats = try await tracks[0].load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first)), kCMVideoCodecType_H264)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
    }

    func testRejectsLongAndAudioOnlySourcesAndRemovesOwnedFiles() async throws {
        for name in ["overlong.mp4", "audio-only.mp4"] {
            let copy = try source(name)
            do { _ = try await VideoPreparation.prepare(copy, limits: limits); XCTFail("Expected rejection for \(name)") } catch {
                if name == "audio-only.mp4" {
                    guard case VideoPreparationError.videoTrack = error
                    else { return XCTFail("Expected missing video track, got \(error)") }
                } else {
                    guard case VideoPreparationError.tooLong = error else { return XCTFail("Expected duration failure, got \(error)") }
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
            }
        }
    }

    func testSourceLargerThanUploadLimitCanBePreparedIntoASmallerUpload() async throws {
        let fixture = try source("rotated.mov")
        let handle = try FileHandle(forWritingTo: fixture)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0, count: 10_000_001))
        try handle.close()
        let sourceSize = try fixture.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertGreaterThan(Int64(sourceSize), limits.maxSizeBytes)
        let copied = try VideoPreparation.copySelection(fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let video = try await VideoPreparation.prepare(copied, limits: limits)
        defer { try? FileManager.default.removeItem(at: video.file) }
        XCTAssertLessThanOrEqual(Int64(try video.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max), limits.maxSizeBytes)
    }

    func testUsesConfiguredOutputSizeAndDurationLimits() async throws {
        for policy in [VideoAttachmentLimits(maxSizeBytes: 1, maxDurationSeconds: 120),
                       VideoAttachmentLimits(maxSizeBytes: 20_000_000, maxDurationSeconds: 0.01)]
        {
            let selected = try source("valid.mp4")
            do {
                _ = try await VideoPreparation.prepare(selected, limits: policy)
                XCTFail("Expected configured limit rejection")
            } catch {
                XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
            }
        }
        let video = try await VideoPreparation.prepare(source("overlong.mp4"),
                                                       limits: VideoAttachmentLimits(maxSizeBytes: 20_000_000, maxDurationSeconds: 120))
        defer { try? FileManager.default.removeItem(at: video.file) }
        XCTAssertGreaterThan(video.durationSeconds, 60)
    }

    func testVideoCapableHostWithoutServerLimitsOnlyAcceptsImages() async throws {
        let model = BugReportViewModel(onDismiss: {}, submitter: VideoSubmitter())
        let copy = try source("valid.mp4")
        await model.addPickedAttachments([.video(copy), .image(TestHelpers.solidImage())])
        XCTAssertFalse(model.supportsVideoAttachments)
        XCTAssertTrue(model.videos.isEmpty)
        XCTAssertEqual(model.screenshots.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    func testMixedSelectionSubmissionPreservesOrderAndNeverMarksUpVideo() async throws {
        let submitter = VideoSubmitter()
        let model = BugReportViewModel(onDismiss: {}, submitter: submitter, videoAttachmentLimits: limits)
        model.description = "Video evidence"
        await model.addPickedAttachments([
            .image(TestHelpers.solidImage()),
            .video(try source("valid.mp4")),
            .image(TestHelpers.solidImage(color: .blue)),
        ])
        defer { model.cleanupVideos() }
        XCTAssertTrue(model.supportsVideoAttachments)
        XCTAssertEqual(model.screenshots.count, 3)
        let poster = try XCTUnwrap(model.videos[1]?.poster)
        model.replaceScreenshot(at: 1, with: TestHelpers.solidImage(color: .green))
        XCTAssertTrue(model.screenshots[1] === poster)
        await model.submit()
        XCTAssertEqual(submitter.imageCount, 2)
        XCTAssertEqual(submitter.videoCount, 1)
        XCTAssertEqual(submitter.order.map(\.isVideo), [false, true, false])
        XCTAssertEqual(submitter.order.map(\.index), [0, 0, 1])
        let file = try XCTUnwrap(model.videos[1]?.file)
        model.removeScreenshot(at: 0)
        XCTAssertNotNil(model.videos[0])
        model.removeScreenshot(at: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testImportBlocksSubmissionAndLateFilesAreCleanedAfterDismissal() async throws {
        let model = BugReportViewModel(onDismiss: {}, submitter: VideoSubmitter(), videoAttachmentLimits: limits)
        model.description = "Selected video importing"
        model.beginMediaImport()
        XCTAssertFalse(model.canSubmit)
        await model.submit()
        XCTAssertEqual(model.submissionState, .idle)
        model.cleanupVideos()
        let late = try source("valid.mp4")
        await model.addPickedAttachments([.video(late)])
        XCTAssertTrue(model.videos.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
    }

    func testInvalidSelectionUsesVisibleErrorStateWithoutDroppingValidImages() async {
        let model = BugReportViewModel(onDismiss: {}, submitter: VideoSubmitter(), videoAttachmentLimits: limits)
        await model.addPickedAttachments([.unavailable(.importing), .image(TestHelpers.solidImage())])
        XCTAssertEqual(model.submissionState, .error)
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(model.screenshots.count, 1)
        XCTAssertTrue(model.canSubmit)
    }

    func testLegacyHostRejectsVideoAndStillAcceptsImages() async throws {
        let model = BugReportViewModel(onDismiss: {}, submitter: ImageSubmitter())
        let copy = try source("valid.mp4")
        await model.addPickedAttachments([.video(copy), .image(TestHelpers.solidImage())])
        XCTAssertFalse(model.supportsVideoAttachments)
        XCTAssertTrue(model.videos.isEmpty)
        XCTAssertEqual(model.screenshots.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }
}

@MainActor
private class ImageSubmitter: BugReportSubmitting {
    func submitBugReport(description _: String, screenshots _: [PreparedScreenshot], type _: String?,
                         severity _: String?) async throws -> ReportReceipt
    {
        ReportReceipt(partialFailures: [])
    }
}

@MainActor
private final class VideoSubmitter: ImageSubmitter, VideoReportSubmitting {
    var imageCount = 0
    var videoCount = 0
    var order: [ReportMediaOrder] = []
    func submitVideoBugReport(
        description _: String,
        screenshots: [PreparedScreenshot],
        videos: [PreparedVideo],
        visualOrder: [ReportMediaOrder],
        type _: String?,
        severity _: String?
    ) async throws -> ReportReceipt {
        imageCount = screenshots.count
        videoCount = videos.count
        order = visualOrder
        return ReportReceipt(partialFailures: [])
    }
}
