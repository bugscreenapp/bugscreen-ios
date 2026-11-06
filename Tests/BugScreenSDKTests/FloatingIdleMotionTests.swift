@testable import BugScreenSDK
import XCTest

final class FloatingIdleMotionTests: XCTestCase {
    func testDeadlineIsStableAndIneligibleStateStartsAFreshDelay() {
        let motion = FloatingIdleMotion()
        motion.update(now: 10, eligible: true, animate: true)
        motion.update(now: 12.9, eligible: true, animate: true)
        XCTAssertEqual(motion.deadline, 13)
        XCTAssertEqual(motion.progress, 0)
        motion.update(now: 13, eligible: false, animate: true)
        XCTAssertNil(motion.deadline)
        motion.update(now: 14, eligible: true, animate: true)
        XCTAssertEqual(motion.deadline, 17)
        motion.update(now: 17, eligible: true, animate: true)
        XCTAssertNil(motion.deadline)
        XCTAssertTrue(motion.settling)
        for _ in 0 ..< 120 {
            motion.advance(1.0 / 120, animate: true)
        }
        XCTAssertEqual(motion.progress, 1)
        motion.update(now: 30, eligible: true, animate: true)
        XCTAssertNil(motion.deadline)
    }

    func testOneThirdOfWidthRestsOffEitherEdgeAfterResize() {
        let motion = FloatingIdleMotion()
        motion.update(now: 0, eligible: true, animate: false)
        motion.update(now: 3, eligible: true, animate: false)
        for viewport: CGFloat in [320, 800] {
            for width: CGFloat in [56, 64] {
                for anchor in [width / 2 + 12, viewport - width / 2 - 12] {
                    let center = anchor + motion.offset(anchor: anchor, buttonWidth: width, viewportWidth: viewport)
                    let outside = anchor < viewport / 2 ? width / 2 - center : center + width / 2 - viewport
                    XCTAssertEqual(outside, width / 3, accuracy: 0.0001)
                }
            }
        }
    }

    func testCatchFreezesPositionAndRevealReversesContinuously() {
        let motion = FloatingIdleMotion()
        motion.update(now: 0, eligible: true, animate: true)
        motion.update(now: 3, eligible: true, animate: true)
        for _ in 0 ..< 6 {
            motion.advance(1.0 / 60, animate: true)
        }
        let caught = motion.progress
        motion.hold()
        XCTAssertFalse(motion.settling)
        XCTAssertNil(motion.deadline)
        motion.advance(1.0 / 60, animate: true)
        XCTAssertEqual(motion.progress, caught)
        motion.reveal(animate: true)
        XCTAssertEqual(motion.progress, caught)
        for _ in 0 ..< 120 {
            motion.advance(1.0 / 120, animate: true)
        }
        XCTAssertEqual(motion.progress, 0)
        motion.update(now: 10, eligible: true, animate: true)
        XCTAssertEqual(motion.deadline, 13)
    }

    func testDisabledMotionAndTeardownDiscardMomentum() {
        let motion = FloatingIdleMotion()
        motion.update(now: 0, eligible: true, animate: true)
        motion.update(now: 3, eligible: true, animate: true)
        motion.advance(1.0 / 60, animate: false)
        XCTAssertEqual(motion.progress, 1)
        XCTAssertFalse(motion.settling)
        motion.reveal(animate: false)
        motion.update(now: 100, eligible: false, animate: true)
        XCTAssertEqual(motion.progress, 0)
        XCTAssertNil(motion.deadline)
    }
}
