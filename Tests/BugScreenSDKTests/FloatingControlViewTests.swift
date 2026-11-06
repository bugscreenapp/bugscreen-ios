@testable import BugScreenSDK
import XCTest

@MainActor
final class FloatingControlViewTests: XCTestCase {
    func testTouchesPassThroughExceptControlAndExpandedMenu() throws {
        let view = FloatingControlView(motion: FloatingMotion())
        defer { view.dispose() }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.layoutIfNeeded()
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
        XCTAssertNil(view.hitTest(CGPoint(x: 100, y: 100), with: nil))
        XCTAssertNotNil(view.hitTest(button.center, with: nil))
        activate(button, target: view)
        view.layoutIfNeeded()
        XCTAssertNil(view.hitTest(CGPoint(x: 100, y: 100), with: nil))
        XCTAssertEqual(button.accessibilityCustomActions?.count, 3)
        view.update(preparing: true, startedAt: nil)
        XCTAssertNil(view.hitTest(CGPoint(x: 100, y: 100), with: nil))
    }

    func testRecordingPillStopsOncePerTapAndReturnsToCollapsedControl() throws {
        let view = FloatingControlView(motion: FloatingMotion())
        defer { view.dispose() }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        var stops = 0
        view.stop = { stops += 1 }
        view.update(preparing: false, startedAt: ProcessInfo.processInfo.systemUptime - 12)
        view.layoutIfNeeded()
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
        XCTAssertGreaterThanOrEqual(button.bounds.width, 112)
        XCTAssertTrue(button.accessibilityLabel?.contains("Stop recording") == true)
        activate(button, target: view)
        XCTAssertEqual(stops, 1)
        view.update(preparing: false, startedAt: nil)
        view.layoutIfNeeded()
        XCTAssertEqual(button.bounds.width, 56)
    }

    func testRecordingClockUpdatesDuringTouchTrackingWithoutChangingPillLayout() throws {
        var now: TimeInterval = 100
        let view = FloatingControlView(motion: FloatingMotion(), uptime: { now })
        defer { view.dispose() }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.update(preparing: false, startedAt: 100)
        view.layoutIfNeeded()
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
        let clock = try XCTUnwrap(button.subviews.compactMap { $0 as? UILabel }.first { !$0.isHidden })
        let frame = button.frame
        let clockFrame = clock.frame
        XCTAssertEqual(clock.text, "0:00")

        // The package test host has no UIApplication to register UIKit’s tracking mode.
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: RunLoop.Mode.tracking.rawValue as CFString))
        now += 1
        let deadline = Date(timeIntervalSinceNow: 2)
        while clock.text == "0:00", Date() < deadline {
            if !RunLoop.main.run(mode: .tracking, before: deadline) { break }
        }
        XCTAssertEqual(clock.text, "0:01")
        XCTAssertTrue(button.accessibilityLabel?.contains("0:01") == true)
        view.layoutIfNeeded()
        XCTAssertEqual(button.frame, frame)
        XCTAssertEqual(clock.frame, clockFrame)
    }

    func testMenuHideActionUsesTheSameSessionDismissalCallback() throws {
        let view = FloatingControlView(motion: FloatingMotion())
        defer { view.dispose() }
        var hidden = 0
        view.hide = { hidden += 1 }
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
        activate(button, target: view)
        let menu = try XCTUnwrap(view.subviews.compactMap { $0 as? UIStackView }.first)
        XCTAssertEqual(menu.arrangedSubviews.count, 3)
        let hide = try XCTUnwrap(menu.arrangedSubviews.last as? UIButton)
        activate(hide, target: view)
        XCTAssertEqual(hidden, 1)
        XCTAssertTrue(menu.isHidden)
    }

    func testThreeActionMenuDoesNotCoverRootButtonInLandscape() throws {
        let view = FloatingControlView(motion: FloatingMotion())
        defer { view.dispose() }
        view.frame = CGRect(x: 0, y: 0, width: 640, height: 320)
        view.layoutIfNeeded()
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
        activate(button, target: view)
        view.layoutIfNeeded()
        let menu = try XCTUnwrap(view.subviews.compactMap { $0 as? UIStackView }.first)
        XCTAssertFalse(button.frame.intersects(menu.frame))
        XCTAssertTrue(view.hitTest(button.center, with: nil) === button)
    }

    func testMenuReversesContinuouslyAndReleasesActionsWhileClosing() throws {
        let view = FloatingControlView(motion: FloatingMotion())
        defer { view.dispose() }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.layoutIfNeeded()
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
        let menu = try XCTUnwrap(view.subviews.compactMap { $0 as? UIStackView }.first)
        var reports = 0
        view.report = { reports += 1 }
        activate(button, target: view)
        for _ in 0 ..< 6 {
            view.advanceAnimations(1.0 / 60)
        }
        XCTAssertGreaterThan(menu.alpha, 0)
        XCTAssertLessThan(menu.alpha, 1)
        let shown = menu.alpha
        let glyphs = button.subviews.compactMap { $0 as? UIImageView }.filter { !$0.isHidden }
        XCTAssertEqual(glyphs.count, 2)
        XCTAssertNotNil(glyphs.first?.image)
        XCTAssertEqual(glyphs[0].alpha, 1 - shown, accuracy: 0.001)
        XCTAssertEqual(glyphs[1].alpha, shown, accuracy: 0.001)
        XCTAssertGreaterThan(atan2(glyphs[0].transform.b, glyphs[0].transform.a), 0)
        XCTAssertLessThan(atan2(glyphs[1].transform.b, glyphs[1].transform.a), 0)
        activate(button, target: view)
        XCTAssertEqual(menu.alpha, shown)
        XCTAssertFalse(menu.isUserInteractionEnabled)
        XCTAssertTrue(menu.accessibilityElementsHidden)
        let report = try XCTUnwrap(menu.arrangedSubviews.first as? UIButton)
        activate(report, target: view)
        XCTAssertEqual(reports, 0)
        XCTAssertNil(view.hitTest(menu.center, with: nil))
        activate(button, target: view)
        XCTAssertEqual(menu.alpha, shown)
        for _ in 0 ..< 120 {
            view.advanceAnimations(1.0 / 120)
        }
        XCTAssertEqual(menu.alpha, 1)
        XCTAssertEqual(menu.transform, .identity)
        XCTAssertEqual(glyphs[0].alpha, 0)
        XCTAssertEqual(glyphs[1].alpha, 1)
        XCTAssertEqual(glyphs[1].transform, .identity)
        activate(button, target: view)
        for _ in 0 ..< 120 {
            view.advanceAnimations(1.0 / 120)
        }
        XCTAssertTrue(menu.isHidden)
    }

    func testPreparationAndDisabledAnimationsClearMenuMomentum() throws {
        let view = FloatingControlView(motion: FloatingMotion())
        defer { view.dispose() }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.layoutIfNeeded()
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
        let menu = try XCTUnwrap(view.subviews.compactMap { $0 as? UIStackView }.first)
        activate(button, target: view)
        for _ in 0 ..< 4 {
            view.advanceAnimations(1.0 / 60)
        }
        view.update(preparing: true, startedAt: nil)
        for _ in 0 ..< 60 {
            view.advanceAnimations(1.0 / 60)
        }
        XCTAssertTrue(menu.isHidden)
        view.update(preparing: false, startedAt: nil)
        let enabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(enabled) }
        activate(button, target: view)
        XCTAssertEqual(menu.alpha, 1)
        XCTAssertEqual(menu.transform, .identity)
        activate(button, target: view)
        XCTAssertTrue(menu.isHidden)
        for _ in 0 ..< 60 {
            view.advanceAnimations(1.0 / 60)
        }
        XCTAssertEqual(menu.alpha, 0)
        view.beginDragging()
        let trash = try XCTUnwrap(view.subviews.compactMap { $0 as? UIImageView }.first)
        XCTAssertEqual(trash.alpha, 1)
        pan(FloatingTestPan(), phase: .ended, translation: .zero, target: view)
        XCTAssertTrue(trash.isHidden)
    }

    func testSpokenFeedbackUsesImmediateMenuStates() throws {
        let view = FloatingControlView(motion: FloatingMotion(), spokenFeedback: { true })
        defer { view.dispose() }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.layoutIfNeeded()
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
        let menu = try XCTUnwrap(view.subviews.compactMap { $0 as? UIStackView }.first)
        activate(button, target: view)
        XCTAssertEqual(menu.alpha, 1)
        XCTAssertEqual(menu.transform, .identity)
        activate(button, target: view)
        XCTAssertTrue(menu.isHidden)
        view.beginDragging()
        let trash = try XCTUnwrap(view.subviews.compactMap { $0 as? UIImageView }.first)
        XCTAssertEqual(trash.alpha, 1)
        pan(FloatingTestPan(), phase: .ended, translation: .zero, target: view)
        XCTAssertTrue(trash.isHidden)
    }

    func testDragAndDisposalCancelUnfinishedTransitions() throws {
        for drag in [true, false] {
            let view = FloatingControlView(motion: FloatingMotion())
            defer { view.dispose() }
            view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
            view.layoutIfNeeded()
            let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
            let menu = try XCTUnwrap(view.subviews.compactMap { $0 as? UIStackView }.first)
            activate(button, target: view)
            for _ in 0 ..< 4 {
                view.advanceAnimations(1.0 / 60)
            }
            if drag { view.beginDragging() } else { view.dispose() }
            for _ in 0 ..< 60 {
                view.advanceAnimations(1.0 / 60)
            }
            XCTAssertTrue(menu.isHidden)
            XCTAssertFalse(menu.isUserInteractionEnabled)
        }
    }

    func testHideTargetStaysVisibleThroughoutDragAndClearsOnRelease() throws {
        let view = FloatingControlView(motion: FloatingMotion())
        defer { view.dispose() }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.layoutIfNeeded()
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
        let trash = try XCTUnwrap(view.subviews.compactMap { $0 as? UIImageView }.first)
        let origin = button.center
        var hidden = 0
        view.hide = { hidden += 1 }
        let drag = FloatingTestPan()
        XCTAssertTrue(trash.isHidden)
        pan(drag, phase: .began, translation: .zero, target: view)
        XCTAssertFalse(trash.isHidden)
        XCTAssertNotNil(trash.image)
        let restingColor = trash.backgroundColor
        pan(drag, phase: .changed, translation: CGPoint(x: -100, y: -200), target: view)
        XCTAssertLessThan(button.center.y, view.bounds.midY)
        XCTAssertFalse(trash.isHidden)
        pan(drag, phase: .changed, translation: CGPoint(x: trash.center.x - origin.x, y: trash.center.y - origin.y), target: view)
        XCTAssertFalse(trash.isHidden)
        XCTAssertNotEqual(trash.backgroundColor, restingColor)
        pan(drag, phase: .changed, translation: CGPoint(x: -100, y: -200), target: view)
        XCTAssertFalse(trash.isHidden)
        XCTAssertEqual(trash.backgroundColor, restingColor)
        pan(drag, phase: .ended, translation: .zero, target: view)
        XCTAssertTrue(trash.isHidden)
        XCTAssertEqual(hidden, 0)
    }

    func testOnlyReleasingOverTargetHidesTheControl() throws {
        for terminal in [UIGestureRecognizer.State.cancelled, .failed, .ended] {
            let view = FloatingControlView(motion: FloatingMotion())
            defer { view.dispose() }
            view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
            view.layoutIfNeeded()
            let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
            let trash = try XCTUnwrap(view.subviews.compactMap { $0 as? UIImageView }.first)
            let origin = button.center
            var hidden = 0
            view.hide = { hidden += 1 }
            let drag = FloatingTestPan()
            pan(drag, phase: .began, translation: .zero, target: view)
            pan(drag, phase: .changed, translation: CGPoint(x: trash.center.x - origin.x, y: trash.center.y - origin.y), target: view)
            pan(drag, phase: terminal, translation: .zero, target: view)
            XCTAssertTrue(trash.isHidden)
            XCTAssertEqual(hidden, terminal == .ended ? 1 : 0)
        }
    }

    func testReleasingOnTrashDuringEntranceFadesBothViewsInPlace() throws {
        let view = FloatingControlView(motion: FloatingMotion())
        defer { view.dispose() }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.layoutIfNeeded()
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
        let trash = try XCTUnwrap(view.subviews.compactMap { $0 as? UIImageView }.first)
        let origin = button.center
        view.enter()
        for _ in 0 ..< 6 {
            view.advanceAnimations(1.0 / 60)
        }
        var dismissed = false
        view.hide = { [weak view] in view?.exit { dismissed = true } }
        let drag = FloatingTestPan()
        pan(drag, phase: .began, translation: .zero, target: view)
        for _ in 0 ..< 4 {
            view.advanceAnimations(1.0 / 60)
        }
        pan(drag, phase: .changed, translation: CGPoint(x: trash.center.x - origin.x, y: trash.center.y - origin.y), target: view)
        let dropped = button.center
        XCTAssertGreaterThan(abs(dropped.x - view.motion.position.x), 1)
        let trashCenter = trash.center
        let trashOpacity = trash.alpha
        XCTAssertGreaterThan(trashOpacity, 0)
        pan(drag, phase: .ended, translation: .zero, target: view)
        XCTAssertEqual(view.alpha, 1)
        view.advanceAnimations(1.0 / 60)
        XCTAssertLessThan(view.alpha, 1)
        XCTAssertGreaterThan(view.alpha, 0)
        XCTAssertFalse(trash.isHidden)
        XCTAssertEqual(trash.alpha, trashOpacity)
        XCTAssertEqual(button.center, dropped)
        XCTAssertEqual(trash.center, trashCenter)
        XCTAssertFalse(dismissed)
        for _ in 0 ..< 120 {
            view.advanceAnimations(1.0 / 120)
        }
        XCTAssertTrue(dismissed)
        XCTAssertEqual(view.alpha, 0)
    }

    func testHideTargetFadesAndSlidesAcrossInterruptedDrags() throws {
        let view = FloatingControlView(motion: FloatingMotion())
        defer { view.dispose() }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.layoutIfNeeded()
        let trash = try XCTUnwrap(view.subviews.compactMap { $0 as? UIImageView }.first)
        let drag = FloatingTestPan()
        pan(drag, phase: .began, translation: .zero, target: view)
        pan(drag, phase: .changed, translation: CGPoint(x: -100, y: -200), target: view)
        XCTAssertFalse(trash.isHidden)
        XCTAssertEqual(trash.alpha, 0)
        let entryY = trash.center.y
        for _ in 0 ..< 6 {
            view.advanceAnimations(1.0 / 60)
        }
        XCTAssertGreaterThan(trash.alpha, 0)
        XCTAssertLessThan(trash.alpha, 1)
        XCTAssertLessThan(trash.center.y, entryY)
        let shown = trash.alpha
        let shownY = trash.center.y
        pan(drag, phase: .ended, translation: .zero, target: view)
        XCTAssertFalse(trash.isHidden)
        XCTAssertEqual(trash.alpha, shown)
        XCTAssertNil(view.hitTest(trash.center, with: nil))
        pan(drag, phase: .began, translation: .zero, target: view)
        XCTAssertEqual(trash.alpha, shown)
        XCTAssertEqual(trash.center.y, shownY)
        for _ in 0 ..< 120 {
            view.advanceAnimations(1.0 / 120)
        }
        XCTAssertEqual(trash.alpha, 1)
        XCTAssertEqual(trash.center.y, entryY - 16)
        pan(drag, phase: .cancelled, translation: .zero, target: view)
        XCTAssertFalse(trash.isHidden)
        for _ in 0 ..< 6 {
            view.advanceAnimations(1.0 / 60)
        }
        XCTAssertGreaterThan(trash.alpha, 0)
        XCTAssertLessThan(trash.alpha, 1)
        for _ in 0 ..< 120 {
            view.advanceAnimations(1.0 / 120)
        }
        XCTAssertTrue(trash.isHidden)
        XCTAssertEqual(trash.alpha, 0)
    }

    func testDropUsesRestingTargetBoundaryDuringEntry() throws {
        let view = FloatingControlView(motion: FloatingMotion())
        defer { view.dispose() }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.layoutIfNeeded()
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
        let trash = try XCTUnwrap(view.subviews.compactMap { $0 as? UIImageView }.first)
        let origin = button.center
        var hidden = 0
        view.hide = { hidden += 1 }
        let drag = FloatingTestPan()
        pan(drag, phase: .began, translation: .zero, target: view)
        XCTAssertEqual(trash.alpha, 0)
        let restingY = trash.center.y - 16
        pan(drag, phase: .changed, translation: CGPoint(x: trash.center.x - origin.x, y: restingY - 60 - origin.y), target: view)
        pan(drag, phase: .ended, translation: .zero, target: view)
        XCTAssertEqual(hidden, 1)
        XCTAssertTrue(trash.isHidden)
    }

    func testPreparationAndDisposalClearTargetMotion() throws {
        for preparing in [true, false] {
            let view = FloatingControlView(motion: FloatingMotion())
            defer { view.dispose() }
            view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
            view.layoutIfNeeded()
            let trash = try XCTUnwrap(view.subviews.compactMap { $0 as? UIImageView }.first)
            view.beginDragging()
            for _ in 0 ..< 4 {
                view.advanceAnimations(1.0 / 60)
            }
            if preparing { view.update(preparing: true, startedAt: nil) } else { view.dispose() }
            XCTAssertTrue(trash.isHidden)
            XCTAssertEqual(trash.alpha, 0)
            let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
            let stopped = button.center
            pan(FloatingTestPan(), phase: .changed, translation: CGPoint(x: 100, y: 100), target: view)
            pan(FloatingTestPan(), phase: .ended, translation: .zero, target: view)
            XCTAssertEqual(button.center, stopped)
            for _ in 0 ..< 120 {
                view.advanceAnimations(1.0 / 120)
            }
            XCTAssertTrue(trash.isHidden)
        }
    }

    func testAnimationSettingChangeClearsAnExitingTarget() throws {
        let view = FloatingControlView(motion: FloatingMotion())
        defer { view.dispose() }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.layoutIfNeeded()
        let trash = try XCTUnwrap(view.subviews.compactMap { $0 as? UIImageView }.first)
        view.beginDragging()
        for _ in 0 ..< 6 {
            view.advanceAnimations(1.0 / 60)
        }
        pan(FloatingTestPan(), phase: .ended, translation: .zero, target: view)
        XCTAssertFalse(trash.isHidden)
        let enabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(enabled) }
        NotificationCenter.default.post(name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        XCTAssertTrue(trash.isHidden)
        XCTAssertEqual(trash.alpha, 0)
    }

    func testCaptureClearsTargetWhileMenuOpensDuringExit() throws {
        let view = FloatingControlView(motion: FloatingMotion())
        defer { view.dispose() }
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.layoutIfNeeded()
        let trash = try XCTUnwrap(view.subviews.compactMap { $0 as? UIImageView }.first)
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? UIButton }.first)
        let menu = try XCTUnwrap(view.subviews.compactMap { $0 as? UIStackView }.first)
        var reports = 0
        view.report = {
            XCTAssertTrue(trash.isHidden)
            reports += 1
        }
        view.beginDragging()
        for _ in 0 ..< 6 {
            view.advanceAnimations(1.0 / 60)
        }
        pan(FloatingTestPan(), phase: .ended, translation: .zero, target: view)
        activate(button, target: view)
        for _ in 0 ..< 3 {
            view.advanceAnimations(1.0 / 60)
        }
        XCTAssertGreaterThan(menu.alpha, 0)
        XCTAssertFalse(trash.isHidden)
        activate(try XCTUnwrap(menu.arrangedSubviews.first as? UIButton), target: view)
        XCTAssertEqual(reports, 1)
        XCTAssertTrue(trash.isHidden)
    }

    private func pan(_ gesture: FloatingTestPan, phase: UIGestureRecognizer.State, translation: CGPoint, target: UIView) {
        gesture.phase = phase
        gesture.delta = translation
        target.perform(NSSelectorFromString("pan:"), with: gesture)
    }

    private func activate(_ button: UIButton, target: UIView) {
        // Package tests have no UIApplication event dispatcher. Exercise the registered target/action.
        let actions = button.actions(forTarget: target, forControlEvent: .touchUpInside) ?? []
        XCTAssertEqual(actions.count, 1)
        for action in actions {
            target.perform(NSSelectorFromString(action))
        }
    }
}

private final class FloatingTestPan: UIPanGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    var delta = CGPoint.zero
    override var state: UIGestureRecognizer.State {
        get { phase }
        set { phase = newValue }
    }

    override func translation(in _: UIView?) -> CGPoint {
        delta
    }
}
