@testable import BugScreenSDK
import UIKit
import XCTest

@MainActor
final class FloatingControlCoordinatorTests: XCTestCase {
    func testNotificationRecordingRestoresPriorVisibilityAfterReportUnlessExplicitlyChanged() async {
        for initiallyVisible in [false, true] {
            for visibilityChange in 0 ..< 3 {
                let window = makeWindow()
                let source = FakeRecordingCapture()
                let engine = controller(source)
                var preparations = 0
                var finished = 0
                var closeReport: (() -> Void)?
                let control = FloatingControlCoordinator(initiallyVisible: initiallyVisible, prepareReport: { video in
                    preparations += 1
                    return FloatingReport(present: { _, screenshot, source, _, closed in
                        XCTAssertTrue(video)
                        XCTAssertNil(screenshot)
                        XCTAssertNotNil(source)
                        closeReport = closed
                    }, discard: {})
                }, maximumDuration: { 60 }, recording: { engine }, windowProvider: { window }, isActive: { _ in true })
                XCTAssertTrue(control.startRecordingFromNotification(in: window) { finished += 1 })
                XCTAssertFalse(control.startRecordingFromNotification(in: window) { XCTFail("Duplicate capture") })
                await flush()
                source.completeStart()
                await flush()
                XCTAssertNotNil(engine.explicitStartedAt)
                if visibilityChange == 1 { control.show() }
                if visibilityChange == 2 { control.hide() } else { engine.finishExplicit() }
                XCTAssertNotNil(closeReport)
                XCTAssertEqual(finished, 0)
                closeReport?()
                XCTAssertEqual(finished, 1)
                XCTAssertFalse(control.busy)
                control.makeReport()
                let visible = visibilityChange == 1 || (initiallyVisible && visibilityChange != 2)
                XCTAssertEqual(preparations, visible ? 2 : 1)
                control.shutdown()
                engine.shutdown()
                window.isHidden = true
            }
        }
    }

    func testNotificationPolicyFailureRestoresHiddenControlAndShowsExistingMessageInHost() async {
        let window = makeWindow()
        let source = FakeRecordingCapture()
        let engine = controller(source)
        defer { engine.shutdown(); window.isHidden = true }
        var preparations = 0
        var finished = 0
        let control = FloatingControlCoordinator(initiallyVisible: false, prepareReport: { _ in
            preparations += 1
            return FloatingReport(present: { _, _, _, _, _ in XCTFail("Empty report") }, discard: {})
        }, maximumDuration: { nil }, recording: { engine }, windowProvider: { window }, isActive: { _ in true })
        defer { control.shutdown() }
        XCTAssertTrue(control.startRecordingFromNotification(in: window) { finished += 1 })
        await flush()
        XCTAssertEqual(finished, 1)
        XCTAssertFalse(control.busy)
        XCTAssertEqual(source.starts, 0)
        XCTAssertTrue(window.rootViewController?.view.subviews.compactMap { $0 as? UILabel }
            .contains { $0.text == SDKStrings.floatingPolicyFailed } == true)
        control.makeReport()
        XCTAssertEqual(preparations, 1)
    }

    func testNotificationCancellationAndShutdownDoNotStartCaptureAfterPolicyCompletes() async {
        for shutdown in [false, true] {
            let window = makeWindow()
            let source = FakeRecordingCapture()
            let engine = controller(source)
            var release: CheckedContinuation<Double?, Never>?
            var finished = 0
            let control = FloatingControlCoordinator(initiallyVisible: false, prepareReport: { _ in
                FloatingReport(present: { _, _, _, _, _ in XCTFail("Stale report") }, discard: {})
            }, maximumDuration: { await withCheckedContinuation { release = $0 } }, recording: { engine },
            windowProvider: { window }, isActive: { _ in true })
            XCTAssertTrue(control.startRecordingFromNotification(in: window) { finished += 1 })
            await flush()
            if shutdown { control.shutdown() } else { control.hide() }
            release?.resume(returning: 60)
            await flush()
            XCTAssertEqual(finished, 1)
            XCTAssertEqual(source.starts, 0)
            XCTAssertFalse(control.busy)
            control.shutdown()
            engine.shutdown()
            window.isHidden = true
        }
    }

    func testNotificationRecordingRejectsDifferentOrInactiveHost() {
        let window = makeWindow()
        let other = makeWindow()
        let source = FakeRecordingCapture()
        let engine = controller(source)
        defer { engine.shutdown(); window.isHidden = true; other.isHidden = true }
        let control = FloatingControlCoordinator(initiallyVisible: false, prepareReport: { _ in fatalError("Unexpected capture") },
                                                 maximumDuration: { 60 }, recording: { engine }, windowProvider: { window },
                                                 isActive: { _ in false })
        defer { control.shutdown() }
        XCTAssertFalse(control.startRecordingFromNotification(in: other) { XCTFail("Unexpected completion") })
        XCTAssertFalse(control.startRecordingFromNotification(in: window) { XCTFail("Unexpected completion") })
        XCTAssertFalse(control.busy)
    }

    func testPolicyCompletionAfterOriginBackgroundDoesNotStartCapture() async {
        let window = makeWindow()
        var active = true
        var release: CheckedContinuation<Double?, Never>?
        var starts = 0
        var discards = 0
        let source = FakeRecordingCapture()
        let engine = controller(source)
        defer { engine.shutdown(); window.isHidden = true }
        let control = FloatingControlCoordinator(initiallyVisible: false,
                                                 prepareReport: { _ in FloatingReport(
                                                     present: { _, _, _, _, _ in XCTFail("Unexpected report") },
                                                     discard: { discards += 1 }
                                                 ) },
                                                 maximumDuration: { await withCheckedContinuation { release = $0 } },
                                                 recording: { starts += 1; return engine }, windowProvider: { window },
                                                 isActive: { _ in active })
        control.show()
        control.startRecording()
        await flush()
        active = false
        release?.resume(returning: 60)
        await flush()
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(discards, 1)
        XCTAssertFalse(control.busy)
        control.shutdown()
    }

    func testPendingVideoRetriesAfterPresenterTransitionAndHideStopsCapture() async throws {
        let root = TransitionPresenter()
        let window = makeWindow(root)
        let source = FakeRecordingCapture()
        let engine = controller(source)
        defer { engine.shutdown(); window.isHidden = true }
        var presentations = 0
        let control = FloatingControlCoordinator(initiallyVisible: false,
                                                 prepareReport: { _ in FloatingReport(present: { _, screenshot, video, _, closed in
                                                     presentations += 1
                                                     XCTAssertNil(screenshot)
                                                     XCTAssertNotNil(video)
                                                     closed()
                                                 }, discard: {}) }, maximumDuration: { 60 }, recording: { engine },
                                                 windowProvider: { window }, isActive: { _ in true })
        control.show()
        control.startRecording()
        await flush()
        XCTAssertEqual(source.starts, 1)
        source.completeStart()
        await flush()
        root.transitioning = true
        control.hide()
        XCTAssertEqual(presentations, 0)
        XCTAssertTrue(control.busy)
        root.transitioning = false
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(presentations, 1)
        XCTAssertFalse(control.busy)
        XCTAssertEqual(source.stops, 1)
        control.shutdown()
    }

    func testShutdownDiscardsPendingScreenshotWithoutPresentingIt() async {
        let window = makeWindow()
        let source = FakeRecordingCapture()
        let engine = controller(source)
        defer { engine.shutdown(); window.isHidden = true }
        var discards = 0
        let control = FloatingControlCoordinator(initiallyVisible: false,
                                                 prepareReport: { _ in FloatingReport(
                                                     present: { _, _, _, _, _ in XCTFail("Stale screenshot") },
                                                     discard: { discards += 1 }
                                                 ) },
                                                 maximumDuration: { 60 }, recording: { engine }, windowProvider: { window },
                                                 isActive: { _ in true })
        control.show()
        control.makeReport()
        control.shutdown()
        await flush()
        XCTAssertEqual(discards, 1)
    }

    private func makeWindow(_ root: UIViewController = UIViewController()) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = root
        window.isHidden = false
        root.loadViewIfNeeded()
        return window
    }

    private func controller(_ source: FakeRecordingCapture) -> ScreenRecordingController {
        ScreenRecordingController(options: .init(), recorder: source, foregroundEligibility: { true },
                                  hardwareAvailable: { true }, thermalState: { .nominal }, observesNotifications: false)
    }

    private func flush() async {
        for _ in 0 ..< 30 {
            await Task.yield()
        }
    }
}

@MainActor
private final class TransitionPresenter: UIViewController {
    var transitioning = false
    override var isBeingPresented: Bool {
        transitioning
    }
}
