@testable import BugScreenSDK
import XCTest

@MainActor
final class FloatingIdleControlTests: XCTestCase {
    func testHostInteractionClosesMenuAndTucksWithoutWaitingForIdle() throws {
        let view = FloatingControlView(motion: FloatingMotion(), uptime: { 0 })
        defer { view.dispose() }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.layoutIfNeeded()
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
        let menu = try XCTUnwrap(view.subviews.compactMap { $0 as? UIStackView }.first)
        let full = button.frame.minX
        invoke(button, target: view, event: .touchUpInside)
        settle(view)
        XCTAssertNil(view.hitTest(CGPoint(x: 100, y: 100), with: nil))
        view.hostInteraction()
        view.advanceAnimations(1.0 / 60)
        XCTAssertGreaterThan(button.frame.minX, full)
        XCTAssertFalse(menu.isUserInteractionEnabled)
        settle(view)
        XCTAssertEqual(button.frame.maxX - view.bounds.maxX, button.bounds.width / 3, accuracy: 0.001)
    }

    func testExitKeepsItsEdgeDuringAnOppositeThrowAndIgnoresLateTap() throws {
        let motion = FloatingMotion()
        let view = FloatingControlView(motion: motion)
        defer { view.dispose() }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.layoutIfNeeded()
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
        let area = CGRect(x: 40, y: 40, width: 320, height: 720)
        motion.place(CGPoint(x: 270, y: 400), bounds: area)
        motion.release(CGPoint(x: -1600, y: 0), bounds: area)
        view.exit {}
        invoke(button, target: view, event: .touchUpInside)
        settle(view)
        XCTAssertEqual(motion.position.x, area.minX, accuracy: 0.001)
        XCTAssertEqual(button.frame.minX, view.bounds.maxX, accuracy: 0.001)
        XCTAssertTrue(view.subviews.compactMap { $0 as? UIStackView }.first?.isHidden == true)
    }

    func testSlidesFromBeyondTheEdgeToTheTuckedPositionAndBack() throws {
        let view = FloatingControlView(motion: FloatingMotion())
        defer { view.dispose() }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.layoutIfNeeded()
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
        view.enter()
        XCTAssertEqual(button.frame.minX, view.bounds.maxX, accuracy: 0.001)
        view.advanceAnimations(1.0 / 60)
        XCTAssertLessThan(button.frame.minX, view.bounds.maxX)
        settle(view)
        let tucked = button.frame.minX
        XCTAssertEqual(button.frame.maxX - view.bounds.maxX, button.bounds.width / 3, accuracy: 0.001)
        var dismissed = false
        view.exit { dismissed = true }
        view.advanceAnimations(1.0 / 60)
        XCTAssertGreaterThan(button.frame.minX, tucked)
        XCTAssertFalse(dismissed)
        view.enter()
        settle(view)
        XCTAssertFalse(dismissed)
        XCTAssertEqual(button.frame.minX, tucked, accuracy: 0.001)
        view.exit { dismissed = true }
        settle(view)
        XCTAssertTrue(dismissed)
        XCTAssertEqual(button.frame.minX, view.bounds.maxX, accuracy: 0.001)
    }

    func testPeekTapOpensMenuAndOnlyRearmsAfterClosing() throws {
        var now: TimeInterval = 0
        let view = FloatingControlView(motion: FloatingMotion(), uptime: { now })
        defer { view.dispose() }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.layoutIfNeeded()
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
        let full = button.frame.minX
        now = 2.9
        view.advanceAnimations(0)
        XCTAssertEqual(button.frame.minX, full)
        now = 3
        view.advanceAnimations(0)
        settle(view)
        XCTAssertEqual(button.frame.maxX - view.bounds.width, button.bounds.width / 3, accuracy: 0.001)
        let exposed = CGPoint(x: view.bounds.maxX - 4, y: button.center.y)
        XCTAssertTrue(view.hitTest(exposed, with: nil) === button)
        XCTAssertNil(view.hitTest(CGPoint(x: 100, y: 100), with: nil))
        invoke(button, target: view, event: .touchDown)
        let held = button.frame
        now = 30
        view.advanceAnimations(0)
        XCTAssertEqual(button.frame, held)
        invoke(button, target: view, event: .touchUpInside)
        settle(view)
        XCTAssertEqual(button.frame.minX, full, accuracy: 0.001)
        let menu = try XCTUnwrap(view.subviews.compactMap { $0 as? UIStackView }.first)
        XCTAssertEqual(menu.alpha, 1)
        now = 60
        view.advanceAnimations(0)
        XCTAssertEqual(button.frame.minX, full, accuracy: 0.001)
        invoke(button, target: view, event: .touchUpInside)
        settle(view)
        now = 62.9
        view.advanceAnimations(0)
        XCTAssertEqual(button.frame.minX, full, accuracy: 0.001)
        now = 63
        view.advanceAnimations(0)
        settle(view)
        XCTAssertEqual(button.frame.maxX - view.bounds.width, button.bounds.width / 3, accuracy: 0.001)
    }

    func testDragBusyRecordingAndDisposalKeepControlFullyVisible() throws {
        var now: TimeInterval = 0
        let view = FloatingControlView(motion: FloatingMotion(), uptime: { now })
        defer { view.dispose() }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.layoutIfNeeded()
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
        now = 3
        view.advanceAnimations(0)
        settle(view)
        view.beginDragging()
        view.layoutIfNeeded()
        now = 30
        view.advanceAnimations(0)
        XCTAssertTrue(view.bounds.contains(button.frame))
        view.update(preparing: true, startedAt: nil)
        view.layoutIfNeeded()
        settle(view)
        now = 60
        view.advanceAnimations(0)
        XCTAssertTrue(view.bounds.contains(button.frame))
        view.update(preparing: false, startedAt: 1)
        view.layoutIfNeeded()
        now = 90
        view.advanceAnimations(0)
        XCTAssertTrue(view.bounds.contains(button.frame))
        view.update(preparing: false, startedAt: nil)
        view.layoutIfNeeded()
        view.dispose()
        now = 120
        view.advanceAnimations(0)
        settle(view)
        XCTAssertTrue(view.bounds.contains(button.frame))
    }

    func testSpokenFeedbackPreventsIdlePeekAndCancelledPressRearms() throws {
        var now: TimeInterval = 0
        var spoken = true
        let view = FloatingControlView(motion: FloatingMotion(), spokenFeedback: { spoken }, uptime: { now })
        defer { view.dispose() }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.layoutIfNeeded()
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
        now = 10
        view.advanceAnimations(0)
        settle(view)
        XCTAssertTrue(view.bounds.contains(button.frame))
        spoken = false
        view.advanceAnimations(0)
        now = 13
        view.advanceAnimations(0)
        settle(view)
        invoke(button, target: view, event: .touchDown)
        invoke(button, target: view, event: .touchCancel)
        settle(view)
        XCTAssertTrue(view.bounds.contains(button.frame))
        now = 16
        view.advanceAnimations(0)
        settle(view)
        XCTAssertEqual(button.frame.maxX - view.bounds.width, button.bounds.width / 3, accuracy: 0.001)
        spoken = true
        NotificationCenter.default.post(name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
        XCTAssertTrue(view.bounds.contains(button.frame))
    }

    func testPanFromPeekResetsTranslationTracksFingerAndRearmsAfterRelease() throws {
        for ending in [UIGestureRecognizer.State.ended, .cancelled] {
            var now: TimeInterval = 0
            let motion = FloatingMotion()
            let view = FloatingControlView(motion: motion, uptime: { now })
            defer { view.dispose() }
            view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
            view.layoutIfNeeded()
            let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
            now = 3
            view.advanceAnimations(0)
            settle(view)
            XCTAssertGreaterThan(button.frame.maxX, view.bounds.maxX)
            let fullCenter = motion.position
            invoke(button, target: view, event: .touchDown)
            let gesture = FloatingIdleTestPan()
            gesture.phase = .began
            gesture.delta = CGPoint(x: -18, y: -10)
            view.perform(NSSelectorFromString("pan:"), with: gesture)
            view.layoutIfNeeded()
            XCTAssertEqual(gesture.resets, 1)
            XCTAssertEqual(gesture.delta, .zero)
            XCTAssertEqual(button.center, fullCenter)
            XCTAssertTrue(view.bounds.contains(button.frame))
            invoke(button, target: view, event: .touchCancel)
            gesture.phase = .changed
            gesture.delta = CGPoint(x: -100, y: -75)
            view.perform(NSSelectorFromString("pan:"), with: gesture)
            XCTAssertEqual(button.center, CGPoint(x: fullCenter.x - 100, y: fullCenter.y - 75))
            now = 30
            view.advanceAnimations(0)
            XCTAssertTrue(view.bounds.contains(button.frame))
            gesture.phase = ending
            view.perform(NSSelectorFromString("pan:"), with: gesture)
            settle(view)
            let docked = button.frame
            XCTAssertTrue(view.bounds.contains(docked))
            now = 32.9
            view.advanceAnimations(0)
            XCTAssertEqual(button.frame, docked)
            now = 33
            view.advanceAnimations(0)
            settle(view)
            let outside = max(-button.frame.minX, button.frame.maxX - view.bounds.maxX)
            XCTAssertEqual(outside, button.bounds.width / 3, accuracy: 0.001)
            XCTAssertEqual(button.center.y, fullCenter.y - 75, accuracy: 0.001)
        }
    }

    func testRealTimerTucksWithoutFurtherLayoutOrInteraction() async throws {
        var now: TimeInterval = 0
        let view = FloatingControlView(motion: FloatingMotion(), uptime: { now })
        defer { view.dispose() }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.layoutIfNeeded()
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
        let full = button.frame.minX
        now = 3
        try await Task.sleep(nanoseconds: 3_200_000_000)
        XCTAssertGreaterThan(button.frame.minX, full + 1)
        settle(view)
        XCTAssertEqual(button.frame.maxX - view.bounds.width, button.bounds.width / 3, accuracy: 0.001)
    }

    private func settle(_ view: FloatingControlView) {
        for _ in 0 ..< 180 {
            view.advanceAnimations(1.0 / 120)
        }
    }

    private func invoke(_ button: UIButton, target: FloatingControlView, event: UIControl.Event) {
        let actions = button.actions(forTarget: target, forControlEvent: event) ?? []
        XCTAssertEqual(actions.count, 1)
        for action in actions {
            target.perform(NSSelectorFromString(action))
        }
    }
}

private final class FloatingIdleTestPan: UIPanGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    var delta = CGPoint.zero
    var resets = 0
    override var state: UIGestureRecognizer.State {
        get { phase }
        set { phase = newValue }
    }

    override func translation(in _: UIView?) -> CGPoint {
        delta
    }

    override func setTranslation(_ translation: CGPoint, in _: UIView?) {
        delta = translation
        resets += 1
    }

    override func velocity(in _: UIView?) -> CGPoint {
        .zero
    }
}
