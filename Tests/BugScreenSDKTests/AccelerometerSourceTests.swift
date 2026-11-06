@testable import BugScreenSDK
import CoreMotion
import XCTest

final class AccelerometerSourceTests: XCTestCase {
    @MainActor
    func testMissingPurposeOrUnavailableSensorDoesNotStart() {
        let manager = TestMotionManager()
        for purpose in [nil, "", "   "] as [String?] {
            let source = AccelerometerSource(manager: manager, purpose: { purpose })
            source.start { _ in XCTFail("Missing purpose must not produce samples") }
        }
        XCTAssertEqual(manager.starts, 0)
        manager.available = false
        let source = AccelerometerSource(manager: manager, purpose: { "Open a report" })
        source.start { _ in XCTFail("Missing sensor must not produce samples") }
        XCTAssertEqual(manager.starts, 0)
    }

    @MainActor
    func testConversionErrorAndStoppedCallbacks() async {
        let manager = TestMotionManager()
        let source = AccelerometerSource(manager: manager, purpose: { "Open a report" })
        var received: [Double] = []
        source.start { received.append($0) }
        XCTAssertEqual(manager.starts, 1)
        XCTAssertEqual(manager.accelerometerUpdateInterval, 0.02, accuracy: 0.001)
        let stale = manager.receive
        manager.receive?(TestAcceleration(), nil)
        await Task.yield()
        XCTAssertEqual(received, [5])
        manager.receive?(nil, NSError(domain: "test", code: 1))
        await Task.yield()
        let stopsAfterError = manager.stops
        stale?(TestAcceleration(), nil)
        await Task.yield()
        XCTAssertEqual(received, [5])
        source.start { received.append($0) }
        XCTAssertEqual(manager.starts, 2)
        source.stop()
        manager.receive?(TestAcceleration(), nil)
        await Task.yield()
        XCTAssertEqual(received, [5])
        XCTAssertGreaterThan(manager.stops, stopsAfterError)
    }

    func testRapidPeaksAreNotSeparateShakes() {
        var recognizer = ShakeRecognizer()
        recognizer.reset(at: 0)
        for time in [1.1, 1.13, 1.16, 1.25] {
            _ = recognizer.accept(gForce: 1, at: time - 0.01)
            XCTAssertFalse(recognizer.accept(gForce: 3, at: time))
        }
        _ = recognizer.accept(gForce: 1, at: 1.3)
        XCTAssertTrue(recognizer.accept(gForce: 3, at: 1.4))
    }

    func testFreshPeaksRespectCooldownAndHalfASecondOfQuiet() {
        var recognizer = ShakeRecognizer()
        recognizer.reset(at: 0)
        for time in [1.1, 1.25] {
            _ = recognizer.accept(gForce: 1, at: time - 0.05)
            XCTAssertFalse(recognizer.accept(gForce: 3, at: time))
        }
        _ = recognizer.accept(gForce: 1, at: 1.3)
        XCTAssertTrue(recognizer.accept(gForce: 3, at: 1.4))
        for time in [2.1, 2.25, 2.4, 3.3, 3.6, 3.8, 4.0] {
            _ = recognizer.accept(gForce: 1, at: time - 0.05)
            XCTAssertFalse(recognizer.accept(gForce: 3, at: time))
        }
        for time in [4.8, 4.95] {
            _ = recognizer.accept(gForce: 1, at: time - 0.05)
            XCTAssertFalse(recognizer.accept(gForce: 3, at: time))
        }
        _ = recognizer.accept(gForce: 1, at: 5)
        XCTAssertTrue(recognizer.accept(gForce: 3, at: 5.1))
    }
}

private final class TestMotionManager: CMMotionManager {
    var available = true
    var starts = 0
    var stops = 0
    var receive: CMAccelerometerHandler?
    override var isAccelerometerAvailable: Bool {
        available
    }

    override func startAccelerometerUpdates(to _: OperationQueue, withHandler handler: @escaping CMAccelerometerHandler) {
        starts += 1
        receive = handler
    }

    override func stopAccelerometerUpdates() {
        stops += 1
    }
}

private final class TestAcceleration: CMAccelerometerData {
    override var acceleration: CMAcceleration {
        CMAcceleration(x: 3, y: 4, z: 0)
    }
}
