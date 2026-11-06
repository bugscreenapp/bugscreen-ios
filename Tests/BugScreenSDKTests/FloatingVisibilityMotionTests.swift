@testable import BugScreenSDK
import XCTest

final class FloatingVisibilityMotionTests: XCTestCase {
    func testOpeningAndClosingSettleAcrossRefreshRates() {
        for rate in [30, 60, 120] {
            let motion = FloatingVisibilityMotion()
            motion.setVisible(true, animate: true)
            motion.advance(1.0 / Double(rate))
            XCTAssertGreaterThan(motion.progress, 0)
            XCTAssertLessThan(motion.progress, 1)
            for _ in 0 ..< rate {
                motion.advance(1.0 / Double(rate))
            }
            XCTAssertEqual(motion.progress, 1)
            XCTAssertFalse(motion.settling)
            motion.setVisible(false, animate: true)
            for _ in 0 ..< rate {
                motion.advance(1.0 / Double(rate))
            }
            XCTAssertEqual(motion.progress, 0)
            XCTAssertFalse(motion.settling)
        }
    }

    func testReversalPreservesPositionAndLatestIntentWins() {
        let motion = FloatingVisibilityMotion()
        motion.setVisible(true, animate: true)
        for _ in 0 ..< 6 {
            motion.advance(1.0 / 60)
        }
        let position = motion.progress
        motion.setVisible(false, animate: true)
        XCTAssertFalse(motion.visible)
        XCTAssertEqual(motion.progress, position)
        for _ in 0 ..< 3 {
            motion.advance(1.0 / 60)
        }
        let reversed = motion.progress
        motion.setVisible(true, animate: true)
        XCTAssertEqual(motion.progress, reversed)
        for _ in 0 ..< 120 {
            motion.advance(1.0 / 120)
        }
        XCTAssertTrue(motion.visible)
        XCTAssertEqual(motion.progress, 1)
    }

    func testDisabledMotionAndCancellationDiscardMomentum() {
        let motion = FloatingVisibilityMotion()
        motion.setVisible(true, animate: true)
        for _ in 0 ..< 4 {
            motion.advance(1.0 / 60)
        }
        motion.setVisible(false, animate: false)
        for _ in 0 ..< 60 {
            motion.advance(1.0 / 60)
        }
        XCTAssertFalse(motion.visible)
        XCTAssertFalse(motion.settling)
        XCTAssertEqual(motion.progress, 0)
        motion.setVisible(true, animate: false)
        XCTAssertEqual(motion.progress, 1)
        XCTAssertFalse(motion.settling)
    }
}
