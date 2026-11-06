@_spi(Wrapper) @testable import BugScreenSDK
import UIKit
import XCTest

final class ShakeDetectorTests: XCTestCase {
    func testBurstRequiresSeparatedPeaksAndQuietBeforeRearming() {
        var recognizer = ShakeRecognizer()
        recognizer.reset(at: 0)
        XCTAssertFalse(recognizer.accept(gForce: 1, at: 1))
        XCTAssertFalse(recognizer.accept(gForce: 3, at: 1.1))
        XCTAssertFalse(recognizer.accept(gForce: 1, at: 1.15))
        XCTAssertFalse(recognizer.accept(gForce: 3, at: 1.25))
        XCTAssertFalse(recognizer.accept(gForce: 1, at: 1.3))
        XCTAssertTrue(recognizer.accept(gForce: 3, at: 1.4))
        for time in stride(from: 1.5, through: 4.0, by: 0.1) {
            XCTAssertFalse(recognizer.accept(gForce: 3, at: time))
        }
        XCTAssertFalse(recognizer.accept(gForce: 1, at: 4.1))
        XCTAssertFalse(recognizer.accept(gForce: 1, at: 4.6))
        XCTAssertFalse(recognizer.accept(gForce: 3, at: 4.7))
        XCTAssertFalse(recognizer.accept(gForce: 1, at: 4.75))
        XCTAssertFalse(recognizer.accept(gForce: 3, at: 4.85))
        XCTAssertFalse(recognizer.accept(gForce: 1, at: 4.9))
        XCTAssertTrue(recognizer.accept(gForce: 3, at: 5.0))
    }

    func testRotationAndIsolatedBumpsDoNotTrigger() {
        var recognizer = ShakeRecognizer()
        recognizer.reset(at: 0)
        for time in stride(from: 1.0, through: 3.0, by: 0.02) {
            XCTAssertFalse(recognizer.accept(gForce: 1.2, at: time))
        }
        for time in stride(from: 4.0, through: 10.0, by: 1.0) {
            XCTAssertFalse(recognizer.accept(gForce: 3, at: time))
            XCTAssertFalse(recognizer.accept(gForce: 1, at: time + 0.05))
        }
        XCTAssertFalse(recognizer.accept(gForce: .nan, at: 11))
    }

    @MainActor
    func testLifecycleDiscardsQueuedEventsAndRestartsOnce() {
        let source = FakeShakeMotionSource()
        let notifications = NotificationCenter()
        var now: TimeInterval = 0
        var reports = 0
        let detector = ShakeDetector(source: source, notifications: notifications, clock: { now }, onShake: { reports += 1 })
        detector.start(active: true)
        detector.start(active: true)
        XCTAssertEqual(source.starts, 1)
        let stale = source.receive
        notifications.post(name: UIApplication.willResignActiveNotification, object: nil)
        for (time, force) in [(1.0, 1.0), (1.1, 3.0), (1.15, 1.0), (1.25, 3.0), (1.3, 1.0), (1.4, 3.0)] {
            now = time
            stale?(force)
        }
        XCTAssertEqual(reports, 0)
        notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(source.starts, 2)
        for (time, force) in [(3.0, 1.0), (3.1, 3.0), (3.15, 1.0), (3.25, 3.0), (3.3, 1.0), (3.4, 3.0)] {
            now = time
            source.receive?(force)
        }
        XCTAssertEqual(reports, 1)
        detector.stop()
        notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(source.starts, 2)
    }

    @MainActor
    func testShakeAttachesSnapshotAndPreservesExistingDraftUntilDismissed() throws {
        defer { BugScreenSDK.shutdown() }
        BugScreenSDK.configure(apiKey: "", enableScreenshotDetection: false, enableShakeDetection: true)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        let presenter = RecordingShakePresenter()
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        presenter.loadViewIfNeeded()
        defer { window.isHidden = true }
        BugScreenSDK.presentAfterShake(window: window, active: true)
        let first = try XCTUnwrap(presenter.recorded as? BugReportHostingController)
        XCTAssertEqual(first.viewModel.screenshots.count, 1)
        first.viewModel.description = "Keep this draft"
        BugScreenSDK.setShakeDetectionEnabled(false)
        XCTAssertEqual(first.viewModel.screenshots.count, 1)
        BugScreenSDK.setShakeDetectionEnabled(true)
        first.addChild(UIViewController())
        BugScreenSDK.presentAfterShake(window: window, active: true)
        XCTAssertIdentical(presenter.recorded, first)
        XCTAssertEqual(first.viewModel.description, "Keep this draft")
        XCTAssertEqual(presenter.presentations, 1)
        presenter.finishReport()
        BugScreenSDK.presentAfterShake(window: window, active: true)
        XCTAssertEqual(presenter.presentations, 2)
    }

    @MainActor
    func testShakeWithoutSnapshotOpensEmptyDraftButInactiveOrDisabledDoesNot() throws {
        defer { BugScreenSDK.shutdown() }
        BugScreenSDK.configure(apiKey: "", enableScreenshotDetection: false, enableShakeDetection: true)
        let window = UIWindow(frame: .zero)
        let presenter = RecordingShakePresenter()
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        presenter.loadViewIfNeeded()
        defer { window.isHidden = true }
        BugScreenSDK.presentAfterShake(window: window, active: false)
        XCTAssertEqual(presenter.presentations, 0)
        BugScreenSDK.presentAfterShake(window: window, active: true)
        let report = try XCTUnwrap(presenter.recorded as? BugReportHostingController)
        XCTAssertTrue(report.viewModel.screenshots.isEmpty)
        presenter.finishReport()
        BugScreenSDK.configure(apiKey: "", enableScreenshotDetection: false)
        BugScreenSDK.presentAfterShake(window: window, active: true)
        XCTAssertEqual(presenter.presentations, 1)
    }

    @MainActor
    func testSnapshotIsBoundedAndEmptyWindowHasNoImage() throws {
        let empty = UIWindow(frame: .zero)
        XCTAssertNil(ReporterWindow.captureWindowSnapshot(empty, maxDimension: 1440))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1200, height: 2400))
        window.backgroundColor = .red
        window.isHidden = false
        defer { window.isHidden = true }
        let image = ReporterWindow.captureWindowSnapshot(window, maxDimension: 1440)
        XCTAssertNotNil(image)
        XCTAssertLessThanOrEqual(try XCTUnwrap(image?.cgImage?.height), 1440)
        XCTAssertLessThanOrEqual(try XCTUnwrap(image?.cgImage?.width), 1440)
    }

    @MainActor
    func testRuntimeToggleIsIdempotentAndReconfigurationRestoresInitialOption() throws {
        BugScreenSDK.shutdown()
        let source = FakeShakeMotionSource()
        var creations = 0
        BugScreenSDK.makeShakeMotionSource = { creations += 1; return source }
        defer {
            BugScreenSDK.shutdown()
            BugScreenSDK.makeShakeMotionSource = { AccelerometerSource() }
        }
        BugScreenSDK.setShakeDetectionEnabled(true)
        XCTAssertEqual(creations, 0)
        BugScreenSDK.configure(apiKey: "", enableScreenshotDetection: false)
        BugScreenSDK.setShakeDetectionEnabled(true)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(try XCTUnwrap(BugScreenSDK.configuration?.enableShakeDetection))
        XCTAssertEqual(creations, 1)
        let starts = source.starts
        BugScreenSDK.setShakeDetectionEnabled(true)
        XCTAssertEqual(source.starts, starts)
        XCTAssertEqual(creations, 1)
        BugScreenSDK.setShakeDetectionEnabled(false)
        XCTAssertFalse(try XCTUnwrap(BugScreenSDK.configuration?.enableShakeDetection))
        XCTAssertGreaterThan(source.stops, 0)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(source.starts, starts)
        BugScreenSDK.setShakeDetectionEnabled(false)
        BugScreenSDK.setShakeDetectionEnabled(true)
        XCTAssertEqual(creations, 2)
        BugScreenSDK.configure(apiKey: "", enableScreenshotDetection: false)
        XCTAssertFalse(try XCTUnwrap(BugScreenSDK.configuration?.enableShakeDetection))
        BugScreenSDK.shutdown()
        BugScreenSDK.setShakeDetectionEnabled(true)
        XCTAssertEqual(creations, 2)
    }

    @MainActor
    func testWrapperConfigurationCombinesOptionsAndAcceptsExistingCallShapes() throws {
        defer { BugScreenSDK.shutdown() }
        BugScreenSDK.configure(apiKey: "", enableScreenshotDetection: false, wrapperSdk: "rn/test")
        BugScreenSDK.configure(apiKey: "", enableScreenshotDetection: false, captureSystemLogs: true, wrapperSdk: "rn/test")
        BugScreenSDK.configure(apiKey: "", enableScreenshotDetection: false, showReportNotification: false, wrapperSdk: "rn/test")
        BugScreenSDK.configure(apiKey: "", enableScreenshotDetection: false, enableShakeDetection: true,
                               captureSystemLogs: true, showReportNotification: false, requestNotificationPermission: false,
                               startScreenRecordingImmediately: false, screenRecordingOptions: .init(durationSeconds: 15),
                               showFloatingButton: true, wrapperSdk: "rn/test")
        XCTAssertTrue(try XCTUnwrap(BugScreenSDK.configuration?.enableShakeDetection))
        XCTAssertTrue(try XCTUnwrap(BugScreenSDK.configuration?.captureSystemLogs))
        XCTAssertFalse(try XCTUnwrap(BugScreenSDK.configuration?.requestNotificationPermission))
        XCTAssertEqual(BugScreenSDK.configuration?.screenRecordingOptions.durationSeconds, 15)
    }

    @MainActor
    func testShakeWaitsForFloatingAndNotificationRecordingToFinish() async throws {
        for fromNotification in [false, true] {
            let window = ShakeCaptureWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
            let presenter = RecordingShakePresenter()
            window.rootViewController = presenter
            window.makeKeyAndVisible()
            presenter.loadViewIfNeeded()
            let layer = try XCTUnwrap(window.layer as? ShakeCaptureLayer)
            let source = FakeRecordingCapture()
            let engine = ScreenRecordingController(options: .init(), recorder: source, foregroundEligibility: { true },
                                                   hardwareAvailable: { true }, thermalState: { .nominal }, observesNotifications: false)
            var closeRecordingReport: (() -> Void)?
            let control = FloatingControlCoordinator(initiallyVisible: !fromNotification, prepareReport: { _ in
                FloatingReport(present: { _, _, _, _, closed in closeRecordingReport = closed }, discard: {})
            }, maximumDuration: { 60 }, recording: { engine }, windowProvider: { window }, isActive: { _ in true })
            BugScreenSDK.configureForTesting(apiKey: TestHelpers.validAPIKey,
                                             baseURL: try XCTUnwrap(URL(string: "https://example.test")),
                                             session: StubURLProtocol.makeSession(), floatingControl: control)
            BugScreenSDK.setShakeDetectionEnabled(true)
            defer {
                presenter.finishReport()
                BugScreenSDK.shutdown()
                engine.shutdown()
                window.isHidden = true
            }
            if fromNotification {
                XCTAssertTrue(control.startRecordingFromNotification(in: window, finished: {}))
            } else {
                control.startRecording()
            }
            XCTAssertTrue(control.busy)
            BugScreenSDK.presentAfterShake(window: window, active: true)
            XCTAssertEqual(layer.captures, 0)
            XCTAssertEqual(presenter.presentations, 0)
            for _ in 0 ..< 30 {
                await Task.yield()
            }
            XCTAssertEqual(source.starts, 1)
            source.completeStart()
            for _ in 0 ..< 30 {
                await Task.yield()
            }
            XCTAssertNotNil(engine.explicitStartedAt)
            BugScreenSDK.setShakeDetectionEnabled(false)
            BugScreenSDK.setShakeDetectionEnabled(true)
            BugScreenSDK.presentAfterShake(window: window, active: true)
            XCTAssertTrue(control.busy)
            XCTAssertEqual(layer.captures, 0)
            XCTAssertEqual(presenter.presentations, 0)
            engine.finishExplicit()
            XCTAssertNotNil(closeRecordingReport)
            BugScreenSDK.presentAfterShake(window: window, active: true)
            XCTAssertEqual(layer.captures, 0)
            closeRecordingReport?()
            XCTAssertFalse(control.busy)
            BugScreenSDK.presentAfterShake(window: window, active: true)
            XCTAssertEqual(layer.captures, 1)
            XCTAssertEqual(presenter.presentations, 1)
        }
    }

    @MainActor
    func testConfigurationDefaultsOffAndCanCombineOptions() throws {
        defer { BugScreenSDK.shutdown() }
        BugScreenSDK.configure(apiKey: "", enableScreenshotDetection: false)
        XCTAssertFalse(try XCTUnwrap(BugScreenSDK.configuration?.enableShakeDetection))
        BugScreenSDK.configure(apiKey: "", enableScreenshotDetection: false, enableShakeDetection: true,
                               captureSystemLogs: true, showReportNotification: false, requestNotificationPermission: false,
                               screenRecordingOptions: .init(durationSeconds: 15), showFloatingButton: false)
        XCTAssertTrue(try XCTUnwrap(BugScreenSDK.configuration?.enableShakeDetection))
        XCTAssertTrue(try XCTUnwrap(BugScreenSDK.configuration?.captureSystemLogs))
        XCTAssertFalse(try XCTUnwrap(BugScreenSDK.configuration?.requestNotificationPermission))
        XCTAssertEqual(BugScreenSDK.configuration?.screenRecordingOptions.durationSeconds, 15)
        XCTAssertFalse(try XCTUnwrap(BugScreenSDK.configuration?.enableScreenshotDetection))
        BugScreenSDK.configure(apiKey: "", enableScreenshotDetection: false)
        XCTAssertFalse(try XCTUnwrap(BugScreenSDK.configuration?.enableShakeDetection))
    }
}

@MainActor
private final class FakeShakeMotionSource: ShakeMotionSource {
    var starts = 0
    var stops = 0
    var receive: (@MainActor (Double) -> Void)?
    func start(_ receive: @escaping @MainActor (Double) -> Void) {
        starts += 1
        self.receive = receive
    }

    func stop() {
        stops += 1
    }
}

@MainActor
private final class RecordingShakePresenter: UIViewController {
    var recorded: UIViewController?
    var presentations = 0
    func finishReport() {
        if let report = recorded as? BugReportHostingController {
            report.presentationControllerDidDismiss(UIPresentationController(presentedViewController: report, presenting: self))
        }
        recorded = nil
    }

    override var presentedViewController: UIViewController? {
        recorded
    }

    override func present(_ viewControllerToPresent: UIViewController, animated _: Bool, completion: (() -> Void)? = nil) {
        recorded = viewControllerToPresent
        presentations += 1
        completion?()
    }
}

@MainActor
private class ShakeCaptureWindow: UIWindow {
    override class var layerClass: AnyClass {
        ShakeCaptureLayer.self
    }
}

private final class ShakeCaptureLayer: CALayer {
    var captures = 0
    override func render(in context: CGContext) {
        captures += 1
        super.render(in: context)
    }
}
