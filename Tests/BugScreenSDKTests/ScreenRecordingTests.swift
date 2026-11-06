@testable import BugScreenSDK
import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest

final class ScreenRecordingTests: XCTestCase {
    @MainActor
    func testCancelledExportKeepsAdmissionUntilItsWorkerActuallyExits() async throws {
        let admission = RecordingExportAdmission()
        var completion: CheckedContinuation<Void, Never>?
        let worker = Task {
            try await admission.run { _ in
                await withCheckedContinuation { completion = $0 }
                try Task.checkCancellation()
            }
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertNotNil(completion)
        worker.cancel()
        XCTAssertNil(admission.acquire())
        do {
            try await admission.run { _ in XCTFail("A second export must not start or queue") }
            XCTFail("Busy admission must fail gracefully")
        } catch VideoPreparationError.processing {} catch { XCTFail("Unexpected failure: \(error)") }
        completion?.resume()
        do { try await worker.value; XCTFail("Cancelled worker must fail") } catch is CancellationError {}
        XCTAssertNotNil(admission.acquire())
    }

    func testPendingPlatformCallbackRetainsExportAdmissionAfterWorkerReturns() async throws {
        let admission = RecordingExportAdmission()
        var callbackOwner: RecordingExportLease?
        try await admission.run { lease in callbackOwner = lease }
        XCTAssertNotNil(callbackOwner)
        XCTAssertNil(admission.acquire())
        callbackOwner = nil
        XCTAssertNotNil(admission.acquire())
    }

    func testModernHardwareSelectionDoesNotRequireOptionalEnumerationMetadata() {
        var enumerated = false
        let selection = HardwareRecordingEncoder.select(canRequireHardware: true) { enumerated = true; return [] }
        XCTAssertEqual(selection, .requiredHardware)
        XCTAssertFalse(enumerated)
        XCTAssertTrue(selection?.verifies(selectedID: nil, usingHardware: true) == true)
        XCTAssertFalse(selection?.verifies(selectedID: "hardware-looking-name", usingHardware: false) == true)
        XCTAssertFalse(selection?.verifies(selectedID: "hardware-looking-name", usingHardware: nil) == true)
        if #available(iOS 17.4, *) {
            XCTAssertEqual(selection?.specification?[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] as? Bool, true)
            XCTAssertEqual(selection?.specification?[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] as? Bool, true)
        }
    }

    func testLegacyHardwareSelectionRequiresExplicitMetadataAndMatchingSelectedID() {
        let unspecified: [String: Any] = [kVTVideoEncoderList_CodecType as String: kCMVideoCodecType_H264,
                                          kVTVideoEncoderList_EncoderID as String: "hardware-looking-name"]
        XCTAssertNil(HardwareRecordingEncoder.select(canRequireHardware: false) { [unspecified] })
        var verified = unspecified
        verified[kVTVideoEncoderList_IsHardwareAccelerated as String] = true
        let selection = HardwareRecordingEncoder.select(canRequireHardware: false) { [verified] }
        XCTAssertEqual(selection, .identifiedHardware("hardware-looking-name"))
        XCTAssertTrue(selection?.verifies(selectedID: "hardware-looking-name", usingHardware: nil) == true)
        XCTAssertFalse(selection?.verifies(selectedID: "different-encoder", usingHardware: true) == true)
        verified[kVTVideoEncoderList_IsHardwareAccelerated as String] = false
        XCTAssertNil(HardwareRecordingEncoder.select(canRequireHardware: false) { [verified] })
    }

    func testOptionsClampAndProfilesPreserveAspectWithoutUpscaling() {
        XCTAssertEqual(ScreenRecordingOptions(durationSeconds: -1).durationSeconds, 5)
        XCTAssertEqual(ScreenRecordingOptions(durationSeconds: 100).durationSeconds, 60)
        XCTAssertEqual(ScreenRecordingOptions().durationSeconds, 30)
        XCTAssertEqual(ScreenRecordingOptions().quality, .balanced)
        let profile = RecordingProfile(.balanced)
        let (width, height) = profile.dimensions(CGSize(width: 1170, height: 2532))
        XCTAssertEqual(width, 720)
        XCTAssertLessThanOrEqual(height, 1600)
        XCTAssertEqual(profile.dimensions(CGSize(width: 100, height: 200)).0, 100)
    }

    func testOnlyApprovedBackgroundStopArmsAutomaticRestart() {
        var lifecycle = RecordingLifecycle()
        lifecycle.enable(true)
        lifecycle.foreground(true)
        XCTAssertTrue(lifecycle.requestIfEligible())
        XCTAssertFalse(lifecycle.requestIfEligible())
        XCTAssertTrue(lifecycle.started())
        lifecycle.foreground(false)
        XCTAssertTrue(lifecycle.armed)
        lifecycle.foreground(true)
        XCTAssertTrue(lifecycle.requestIfEligible())
        lifecycle.fail(.stopped)
        lifecycle.foreground(false)
        lifecycle.foreground(true)
        XCTAssertFalse(lifecycle.requestIfEligible())
        lifecycle.enable(true)
        XCTAssertTrue(lifecycle.requestIfEligible())
    }

    func testReporterSuppressesRestartAndStopWinsOverForeground() {
        var lifecycle = RecordingLifecycle()
        lifecycle.enable(true)
        lifecycle.foreground(true)
        XCTAssertTrue(lifecycle.requestIfEligible())
        XCTAssertTrue(lifecycle.started())
        lifecycle.report(true)
        lifecycle.foreground(false)
        lifecycle.foreground(true)
        XCTAssertFalse(lifecycle.requestIfEligible())
        lifecycle.fail(.interrupted)
        lifecycle.report(false)
        XCTAssertFalse(lifecycle.requestIfEligible())
        XCTAssertEqual(lifecycle.state, .unavailable(.interrupted))
    }

    func testFailureBeforeReporterRemainsInspectableAfterDismissal() {
        var lifecycle = RecordingLifecycle()
        lifecycle.enable(true)
        lifecycle.fail(.hardwareEncoderUnavailable)
        lifecycle.report(true)
        lifecycle.report(false)
        XCTAssertEqual(lifecycle.state, .unavailable(.hardwareEncoderUnavailable))
        lifecycle.foreground(true)
        XCTAssertFalse(lifecycle.requestIfEligible())
    }

    func testDenialAndResourceFailureRequireExplicitRetry() {
        for reason: ScreenRecordingUnavailableReason in [.permissionDenied, .memoryPressure, .thermalPressure, .encodingFailed] {
            var lifecycle = RecordingLifecycle()
            lifecycle.enable(true)
            lifecycle.foreground(true)
            XCTAssertTrue(lifecycle.requestIfEligible())
            lifecycle.fail(reason)
            lifecycle.foreground(true)
            XCTAssertFalse(lifecycle.requestIfEligible())
            lifecycle.enable(true)
            XCTAssertTrue(lifecycle.requestIfEligible())
            lifecycle.enable(false)
            XCTAssertFalse(lifecycle.started())
            XCTAssertEqual(lifecycle.state, .disabled)
        }
    }

    func testRingEvictsWholeGroupsAndHonorsByteBound() throws {
        var ring = EncodedRecordingBuffer(duration: 5, byteLimit: 40)
        for frame in 0 ..< 20 {
            ring.append(try sample(Double(frame), keyframe: frame.isMultiple(of: 2)))
        }
        XCTAssertLessThanOrEqual(ring.byteCount, 40)
        XCTAssertTrue(ring.samples.first?.keyframe == true)
        XCTAssertEqual(ring.samples.count, 4)
        let frozen = ring.take()
        XCTAssertEqual(frozen.count, 4)
        XCTAssertEqual(ring.byteCount, 0)
        XCTAssertTrue(ring.samples.isEmpty)
    }

    func testOversizedSampleAndMissingKeyframesCannotGrowBuffer() throws {
        var ring = EncodedRecordingBuffer(duration: 30, byteLimit: 20)
        ring.append(try sample(0, keyframe: true))
        ring.append(try sample(1, keyframe: false))
        ring.append(try sample(2, keyframe: false))
        XCTAssertTrue(ring.samples.isEmpty)
        ring.append(try sample(3, keyframe: false))
        XCTAssertTrue(ring.samples.isEmpty)
        ring.append(try sample(4, keyframe: true, bytes: 30))
        XCTAssertTrue(ring.samples.isEmpty)
        ring.append(try sample(5, keyframe: true))
        XCTAssertEqual(ring.samples.count, 1)
    }

    func testExpiredGroupWithoutNextKeyframeReleasesPayloadAndWaitsForRecovery() throws {
        let budget = RecordingPayloadBudget()
        var ring = EncodedRecordingBuffer(duration: 5, byteLimit: 1_000_000, budget: budget)
        let fixture = try sample(0, keyframe: true, bytes: 1)
        for frame in 0 ..< 1000 {
            ring.append(RecordedSample(buffer: fixture.buffer, timestamp: Double(frame) / 100, duration: 0.01,
                                       bytes: 1, keyframe: frame == 0))
            XCTAssertLessThanOrEqual(ring.byteCount, 500)
        }
        XCTAssertTrue(ring.samples.isEmpty)
        XCTAssertEqual(budget.retainedBytes, 0)
        ring.append(try sample(10, keyframe: false, bytes: 1))
        XCTAssertTrue(ring.samples.isEmpty)
        ring.append(try sample(11, keyframe: true, bytes: 1))
        XCTAssertEqual(ring.samples.first?.timestamp, 11)
        XCTAssertEqual(budget.retainedBytes, 1)
    }

    func testDenseTinySamplesCannotGrowMetadataBeyondIndependentCountLimit() throws {
        let budget = RecordingPayloadBudget()
        var ring = EncodedRecordingBuffer(duration: 60, byteLimit: 1_000_000, budget: budget)
        let fixture = try sample(0, keyframe: true, bytes: 1)
        for frame in 0 ..< 1800 {
            ring.append(RecordedSample(buffer: fixture.buffer, timestamp: Double(frame) / 10000, duration: 0.0001,
                                       bytes: 1, keyframe: frame == 0))
        }
        XCTAssertEqual(ring.samples.count, 1800)
        XCTAssertEqual(budget.retainedBytes, 1800)
        for frame in 1800 ..< 2000 {
            ring.append(RecordedSample(buffer: fixture.buffer, timestamp: Double(frame) / 10000, duration: 0.0001,
                                       bytes: 1, keyframe: false))
            XCTAssertTrue(ring.samples.isEmpty)
        }
        XCTAssertEqual(budget.retainedBytes, 0)
        ring.append(try sample(1, keyframe: true, bytes: 1))
        XCTAssertEqual(ring.samples.count, 1)
        XCTAssertEqual(budget.retainedBytes, 1)
    }

    func testWindowIncludesFinalFrameDurationAndNeverChoosesOlderKeyframe() throws {
        let samples = try (0 ..< 62).map { try sample(Double($0), keyframe: $0.isMultiple(of: 2)) }
        for limit in [5.0, 30.0, 60.0] {
            let chosen = EncodedRecordingBuffer.selection(samples, maximumDuration: limit, endingAt: 62)
            let first = try XCTUnwrap(chosen.first)
            let last = try XCTUnwrap(chosen.last)
            XCTAssertTrue(first.keyframe)
            XCTAssertLessThanOrEqual(last.timestamp + last.duration - first.timestamp, limit)
        }
        XCTAssertTrue(EncodedRecordingBuffer.selection([try sample(0, keyframe: false)], maximumDuration: 5, endingAt: 1).isEmpty)
    }

    func testTriggerClockRejectsStaleStaticHistoryAndClipsFinalFrame() throws {
        let samples = try [sample(10, keyframe: true), sample(11, keyframe: false), sample(20, keyframe: true), sample(21, keyframe: false)]
        XCTAssertTrue(EncodedRecordingBuffer.selection(samples, maximumDuration: 30, endingAt: 60).isEmpty)
        let recent = EncodedRecordingBuffer.selection(samples, maximumDuration: 30, endingAt: 45)
        XCTAssertEqual(recent.first?.timestamp, 20)
        let clipped = EncodedRecordingBuffer.selection(samples, maximumDuration: 30, endingAt: 21.25)
        XCTAssertEqual(clipped.last?.duration, 0.25)
        XCTAssertTrue(EncodedRecordingBuffer.selection(samples, maximumDuration: 30, endingAt: 5).isEmpty)
    }

    func testCancelledFrozenRecordingRejectsLateSamples() async throws {
        let frozen = FrozenRecording(maximumDuration: 30, triggerTimestamp: 1)
        frozen.cancel()
        frozen.install([try sample(0, keyframe: true)])
        do {
            _ = try await frozen.prepare(limits: VideoAttachmentLimits(maxSizeBytes: 50_000_000, maxDurationSeconds: 60))
            XCTFail("Cancelled evidence must not export")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testPreviousReporterCannotSubmitIntoReconfiguredApp() async throws {
        defer { BugScreenSDK.shutdown() }
        let url = try XCTUnwrap(URL(string: "https://recording-tests.invalid"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        BugScreenSDK.configureForTesting(apiKey: "", baseURL: url, session: session)
        let old = DefaultBugReportSubmitter(client: try XCTUnwrap(BugScreenSDK.apiClient))
        BugScreenSDK.configureForTesting(apiKey: "", baseURL: url, session: session)
        do {
            _ = try await old.submitBugReport(description: "Old draft", screenshots: [], type: nil, severity: nil)
            XCTFail("Reconfiguration must invalidate the old transport identity")
        } catch BugScreenSDKError.notConfigured {} catch { XCTFail("Unexpected failure: \(error)") }
    }

    @MainActor
    func testConfigurationWithRecordingOffDoesNotDeleteActiveExport() throws {
        defer { BugScreenSDK.shutdown() }
        let file = try RecordingFileStore.newFile()
        try Data("active generated draft".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let url = try XCTUnwrap(URL(string: "https://recording-tests.invalid"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        BugScreenSDK.configureForTesting(apiKey: "", baseURL: url, session: session)
        XCTAssertEqual(BugScreenSDK.screenRecordingState, .disabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testFrozenReferencesStayChargedUntilReleasedAcrossNewRings() throws {
        let budget = RecordingPayloadBudget()
        var first = EncodedRecordingBuffer(duration: 30, byteLimit: 20, budget: budget)
        first.append(try sample(0, keyframe: true))
        first.append(try sample(1, keyframe: false))
        var frozen: [RecordedSample]? = first.take()
        XCTAssertEqual(budget.retainedBytes, 20)
        var next = EncodedRecordingBuffer(duration: 30, byteLimit: 20, budget: budget)
        next.append(try sample(2, keyframe: true))
        XCTAssertTrue(next.samples.isEmpty)
        XCTAssertEqual(frozen?.count, 2)
        frozen = nil
        XCTAssertEqual(budget.retainedBytes, 0)
        next.append(try sample(3, keyframe: false))
        XCTAssertTrue(next.samples.isEmpty)
        next.append(try sample(4, keyframe: true))
        XCTAssertEqual(next.byteCount, 10)
    }

    private func sample(_ time: Double, keyframe: Bool, bytes: Int = 10) throws -> RecordedSample {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format),
            noErr
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 1),
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var buffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: try XCTUnwrap(format),
                                                     sampleTiming: &timing, sampleBufferOut: &buffer),
            noErr
        )
        return RecordedSample(buffer: try XCTUnwrap(buffer), timestamp: time, duration: 1, bytes: bytes, keyframe: keyframe)
    }
}
