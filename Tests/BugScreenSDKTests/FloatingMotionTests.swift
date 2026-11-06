@testable import BugScreenSDK
import XCTest

final class FloatingMotionTests: XCTestCase {
    private let bounds = CGRect(x: 40, y: 60, width: 310, height: 680)

    func testDetachingMidThrowKeepsChosenDock() {
        let motion = FloatingMotion()
        motion.adaptBounds(bounds)
        motion.place(CGPoint(x: 100, y: 300), bounds: bounds)
        motion.release(CGPoint(x: 1800, y: 0), bounds: bounds)
        motion.advance(0.01, bounds: bounds)
        motion.dockForDetach()
        XCTAssertEqual(motion.position.x, bounds.maxX)
        XCTAssertFalse(motion.settling)
    }

    func testNewOverlayBoundsRetainDockAndRelativeHeight() {
        let motion = FloatingMotion()
        motion.adaptBounds(bounds)
        motion.place(CGPoint(x: bounds.maxX, y: bounds.minY + bounds.height * 0.75), bounds: bounds)
        motion.adaptBounds(CGRect(x: 40, y: 50, width: 710, height: 300))
        XCTAssertEqual(motion.position, CGPoint(x: 750, y: 275))
    }

    func testThrowCrossesScreenAndSettlesInsideUsableBounds() {
        let motion = FloatingMotion()
        motion.place(CGPoint(x: 100, y: 300), bounds: bounds)
        motion.release(.zero, bounds: bounds)
        XCTAssertEqual(motion.target.x, 40)
        motion.place(CGPoint(x: 100, y: 300), bounds: bounds)
        motion.release(CGPoint(x: 1800, y: 900), bounds: bounds)
        XCTAssertEqual(motion.target, CGPoint(x: 350, y: 462))
        for _ in 0 ..< 240 {
            let point = motion.advance(1.0 / 120, bounds: bounds)
            XCTAssertTrue(point.x >= bounds.minX - 8 && point.x <= bounds.maxX + 8)
            XCTAssertTrue(point.y >= bounds.minY && point.y <= bounds.maxY)
        }
        XCTAssertFalse(motion.settling)
        XCTAssertEqual(motion.position, motion.target)
    }

    func testCatchAndReducedMotionKeepTheSameDestination() {
        let motion = FloatingMotion()
        motion.place(CGPoint(x: 120, y: 250), bounds: bounds)
        motion.release(CGPoint(x: 1900, y: -800), bounds: bounds)
        motion.advance(0.016, bounds: bounds)
        let caught = motion.position
        motion.place(caught, bounds: bounds)
        XCTAssertFalse(motion.settling)
        XCTAssertEqual(motion.advance(0.05, bounds: bounds), caught)
        motion.release(CGPoint(x: -1200, y: 300), bounds: bounds, animate: false)
        XCTAssertEqual(motion.position, motion.target)
    }

    func testChangedBoundsAndFrameRatesReachSameTarget() {
        for fps in [60, 120] {
            let motion = FloatingMotion()
            motion.place(CGPoint(x: 300, y: 700), bounds: bounds)
            motion.release(CGPoint(x: 3000, y: 4000), bounds: bounds)
            let keyboard = CGRect(x: 40, y: 60, width: 310, height: 340)
            for _ in 0 ..< fps * 2 {
                motion.advance(1 / Double(fps), bounds: keyboard)
            }
            XCTAssertEqual(motion.position, CGPoint(x: 350, y: 400))
            XCTAssertFalse(motion.settling)
        }
    }
}
