@testable import BugScreenSDK
import ReplayKit
import XCTest

@MainActor
final class RecordingControllerTests: XCTestCase {
    func testExplicitDeadlineUsesPolicyAndSixtySecondCeiling() async {
        for maximum in [0.05, 120.0] {
            let source = FakeRecordingCapture()
            var requested: UInt64?
            var release: CheckedContinuation<Void, Error>?
            let controller = ScreenRecordingController(options: .init(), recorder: source, foregroundEligibility: { true },
                                                       hardwareAvailable: { true }, observesNotifications: false,
                                                       deadlineSleep: { delay in
                                                           requested = delay
                                                           try await withCheckedThrowingContinuation { release = $0 }
                                                       })
            var completions = 0
            controller.beginExplicit(maximumSeconds: maximum) { evidence, _ in completions += 1; evidence?.cancel() }
            source.completeStart()
            await flush()
            XCTAssertEqual(requested, UInt64(min(60, maximum) * 1_000_000_000))
            XCTAssertEqual(completions, 0)
            release?.resume()
            await flush()
            XCTAssertEqual(completions, 1)
            XCTAssertTrue(controller.explicitReachedLimit)
            controller.reportDidClose()
            controller.shutdown()
            await flush()
        }
    }

    func testExplicitStopTransfersOnceAndDisarmsRollingRestart() async {
        let source = FakeRecordingCapture()
        let controller = makeController(source, observesNotifications: true)
        defer { controller.shutdown() }
        controller.setEnabled(true)
        source.completeStart()
        await flush()
        var completions = 0
        var evidence: AutomaticVideoSource?
        XCTAssertTrue(controller.beginExplicit(maximumSeconds: 45) { video, _ in completions += 1; evidence = video })
        XCTAssertNotNil(controller.explicitStartedAt)
        controller.finishExplicit()
        controller.finishExplicit()
        await flush()
        XCTAssertEqual(completions, 1)
        XCTAssertNotNil(evidence)
        XCTAssertEqual(source.starts, 1)
        XCTAssertEqual(source.stops, 1)
        XCTAssertEqual(controller.state, .disabled)
        controller.reportDidClose()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await flush()
        XCTAssertEqual(source.starts, 1)
        evidence?.cancel()
    }

    func testExplicitDenialAndShutdownNeverDeliverLateEvidence() async {
        let source = FakeRecordingCapture()
        let controller = makeController(source)
        var completions = 0
        XCTAssertTrue(controller.beginExplicit(maximumSeconds: 60) { evidence, reason in
            completions += 1
            XCTAssertNil(evidence)
            XCTAssertEqual(reason, .permissionDenied)
        })
        source.completeStart(error: NSError(domain: RPRecordingErrorDomain, code: -5801))
        await flush()
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(controller.explicitActive)
        XCTAssertTrue(controller.beginExplicit(maximumSeconds: 60) { _, _ in completions += 1 })
        controller.shutdown()
        source.completeStart()
        await flush()
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(source.isRecording)
    }

    func testExplicitSystemStopKeepsEvidenceWithoutStoppingAnotherPlatformSession() async {
        let source = FakeRecordingCapture()
        let controller = makeController(source)
        defer { controller.shutdown() }
        var evidence: AutomaticVideoSource?
        controller.beginExplicit(maximumSeconds: 60) { video, reason in
            evidence = video
            XCTAssertEqual(reason, .stopped)
        }
        source.completeStart()
        await flush()
        controller.screenRecorder(RPScreenRecorder.shared(), didStopRecordingWith: nil, error: nil)
        await flush()
        XCTAssertNotNil(evidence)
        XCTAssertEqual(source.stops, 0)
        XCTAssertEqual(controller.state, .disabled)
        evidence?.cancel()
    }

    func testPendingConsentOwnerSurvivesShutdownAndStopsLateSuccessfulCapture() async {
        let source = FakeRecordingCapture()
        var controller: ScreenRecordingController? = makeController(source)
        weak var owner = controller
        controller?.setEnabled(true)
        XCTAssertEqual(source.starts, 1)
        controller?.shutdown()
        controller = nil
        XCTAssertNotNil(owner, "Pending consent needs a live owner to stop its late result")
        source.completeStart()
        await flush()
        XCTAssertEqual(source.stops, 1)
        XCTAssertFalse(source.isRecording)
        XCTAssertNil(owner)
    }

    func testRepeatedEnableDoesNotDuplicatePromptAndDenialRequiresExplicitRetry() async {
        let source = FakeRecordingCapture()
        let controller = makeController(source)
        defer { controller.shutdown() }
        controller.setEnabled(true)
        controller.setEnabled(true)
        XCTAssertEqual(source.starts, 1)
        source.completeStart(error: NSError(domain: RPRecordingErrorDomain, code: -5801))
        await flush()
        XCTAssertEqual(controller.state, .unavailable(.permissionDenied))
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await flush()
        XCTAssertEqual(source.starts, 1)
        controller.setEnabled(true)
        XCTAssertEqual(source.starts, 2)
        source.completeStart(error: NSError(domain: RPRecordingErrorDomain, code: -5801))
        await flush()
    }

    func testUnsupportedHardwareAndThermalPressureNeverPrompt() {
        for (hardware, thermal, reason) in [
            (false, ProcessInfo.ThermalState.nominal, ScreenRecordingUnavailableReason.hardwareEncoderUnavailable),
            (true, .serious, .thermalPressure),
        ] {
            let source = FakeRecordingCapture()
            let controller = ScreenRecordingController(options: .init(), recorder: source, foregroundEligibility: { true },
                                                       hardwareAvailable: { hardware }, thermalState: { thermal },
                                                       observesNotifications: false)
            controller.setEnabled(true)
            XCTAssertEqual(controller.state, .unavailable(reason))
            XCTAssertEqual(source.starts, 0)
            controller.shutdown()
        }
    }

    func testPendingOldConfigurationCannotOverlapNewConsent() async {
        let source = FakeRecordingCapture()
        let old = makeController(source)
        let replacement = makeController(source)
        old.setEnabled(true)
        old.shutdown()
        replacement.setEnabled(true)
        XCTAssertEqual(source.starts, 1)
        XCTAssertEqual(replacement.state, .waitingForForeground)
        source.completeStart()
        await flush()
        XCTAssertEqual(source.stops, 1)
        XCTAssertEqual(source.starts, 2)
        replacement.shutdown()
        source.completeStart()
        await flush()
    }

    func testReplacementWaitsForOwnedStopAndReporterDismissal() async {
        let source = FakeRecordingCapture()
        source.automaticallyCompletesStop = false
        let old = makeController(source)
        let replacement = makeController(source)
        old.setEnabled(true)
        source.completeStart()
        await flush()
        old.shutdown()
        replacement.setEnabled(true)
        XCTAssertEqual(source.starts, 1)
        let evidence = replacement.reportWillOpen()
        source.completeStop()
        await flush()
        XCTAssertEqual(source.starts, 1)
        evidence?.cancel()
        replacement.reportDidClose()
        XCTAssertEqual(source.starts, 2)
        source.completeStart()
        await flush()
        XCTAssertEqual(replacement.state, .recording)
        replacement.shutdown()
        source.completeStop()
        await flush()
    }

    func testQueuedReplacementCancelsForDisableOrPlatformStop() async {
        for platformStop in [false, true] {
            let source = FakeRecordingCapture()
            source.automaticallyCompletesStop = false
            let old = makeController(source)
            let replacement = makeController(source)
            old.setEnabled(true)
            source.completeStart()
            await flush()
            old.shutdown()
            replacement.setEnabled(true)
            if platformStop {
                old.screenRecorder(RPScreenRecorder.shared(), didStopRecordingWith: nil, error: nil)
                await flush()
            } else { replacement.setEnabled(false) }
            source.completeStop()
            await flush()
            XCTAssertEqual(source.starts, 1)
            XCTAssertEqual(replacement.state, platformStop ? .unavailable(.stopped) : .disabled)
            replacement.shutdown()
        }
    }

    func testQueuedReplacementDoesNotRepeatDeniedConsent() async {
        let source = FakeRecordingCapture()
        let old = makeController(source)
        let replacement = makeController(source)
        old.setEnabled(true)
        old.shutdown()
        replacement.setEnabled(true)
        source.completeStart(error: NSError(domain: RPRecordingErrorDomain, code: -5801))
        await flush()
        XCTAssertEqual(source.starts, 1)
        XCTAssertEqual(replacement.state, .unavailable(.permissionDenied))
        replacement.shutdown()
    }

    func testFailedStopDisarmsQueuedReplacement() async {
        let source = FakeRecordingCapture()
        source.automaticallyCompletesStop = false
        let old = makeController(source)
        let replacement = makeController(source)
        old.setEnabled(true)
        source.completeStart()
        await flush()
        old.shutdown()
        replacement.setEnabled(true)
        source.completeStop(error: NSError(domain: RPRecordingErrorDomain, code: -5800))
        await flush()
        XCTAssertEqual(source.starts, 1)
        XCTAssertEqual(replacement.state, .unavailable(.interrupted))
        replacement.shutdown()
    }

    func testHostOwnedCaptureIsNeverQueuedOrStopped() async {
        let source = FakeRecordingCapture()
        source.isRecording = true
        let controller = makeController(source)
        controller.setEnabled(true)
        XCTAssertEqual(controller.state, .unavailable(.recorderBusy))
        XCTAssertEqual(source.starts, 0)
        source.isRecording = false
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await flush()
        XCTAssertEqual(source.starts, 0)
        controller.shutdown()
        XCTAssertEqual(source.stops, 0)
    }

    func testBackgroundStopsThenRestartsOnlyAfterReporterDismissal() async {
        let source = FakeRecordingCapture()
        let controller = makeController(source, observesNotifications: true)
        defer { controller.shutdown() }
        controller.setEnabled(true)
        source.completeStart()
        await flush()
        XCTAssertEqual(controller.state, .recording)
        let evidence = controller.reportWillOpen()
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await flush()
        XCTAssertEqual(source.stops, 1)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await flush()
        XCTAssertEqual(source.starts, 1)
        evidence?.cancel()
        controller.reportDidClose()
        XCTAssertEqual(source.starts, 2)
        source.completeStart()
        await flush()
        controller.shutdown()
        await flush()
    }

    private func makeController(_ source: FakeRecordingCapture, observesNotifications: Bool = false) -> ScreenRecordingController {
        ScreenRecordingController(options: .init(), recorder: source, foregroundEligibility: { true },
                                  hardwareAvailable: { true }, thermalState: { .nominal }, observesNotifications: observesNotifications)
    }

    private func flush() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }
}

@MainActor
final class FakeRecordingCapture: RecordingCaptureSource {
    var isAvailable = true
    var isRecording = false
    weak var delegate: RPScreenRecorderDelegate?
    private var completion: (@Sendable (Error?) -> Void)?
    private var stopCompletion: (@Sendable (Error?) -> Void)?
    var automaticallyCompletesStop = true
    private(set) var starts = 0
    private(set) var stops = 0

    func start(handler _: @escaping (CMSampleBuffer, RPSampleBufferType, Error?) -> Void,
               completion: @escaping @Sendable (Error?) -> Void)
    {
        starts += 1
        self.completion = completion
    }

    func completeStart(error: Error? = nil) {
        isRecording = error == nil
        let pending = completion
        completion = nil
        pending?(error)
    }

    func stop(completion: @escaping @Sendable (Error?) -> Void) {
        stops += 1
        stopCompletion = completion
        if automaticallyCompletesStop { completeStop() }
    }

    func completeStop(error: Error? = nil) {
        isRecording = false
        let pending = stopCompletion
        stopCompletion = nil
        pending?(error)
    }
}
