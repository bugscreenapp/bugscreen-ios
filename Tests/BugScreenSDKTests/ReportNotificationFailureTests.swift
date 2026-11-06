@testable import BugScreenSDK
import UIKit
import UserNotifications
import XCTest

@MainActor
final class ReportNotificationFailureTests: XCTestCase {
    func testExpiredRecordingHandoffRestoresNotificationAndCannotStartOnLateActivation() async throws {
        let center = FakeReportNotificationCenter()
        let window = UIWindow()
        var active = false
        var starts = 0
        var deadline: CheckedContinuation<Void, Never>?
        let controller = ReportNotificationController(center: center, windowProvider: { window }, eligible: { _ in true },
                                                      capture: { _ in XCTFail("Expired recording must not capture an image"); return nil },
                                                      isActive: { _ in active },
                                                      handoffSleep: { _ in await withCheckedContinuation { deadline = $0 } },
                                                      startRecording: { _, _ in starts += 1; return true },
                                                      present: { _, _ in XCTFail("Expired recording must not open a report") })
        defer { controller.stop() }
        await controller.start()
        let old = try XCTUnwrap(controller.requestID)
        controller.handle(identifier: old, action: ReportNotificationController.recordAction)
        await flush()
        XCTAssertNotNil(deadline)
        XCTAssertTrue(center.present.isEmpty)
        deadline?.resume()
        await flush()
        await controller.activate()
        XCTAssertFalse(controller.hidden)
        XCTAssertEqual(center.present.count, 1)
        XCTAssertNotEqual(controller.requestID, old)
        active = true
        controller.handle(identifier: old, action: ReportNotificationController.recordAction)
        await controller.activate()
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(center.present.count, 1)
    }

    func testCancelledDeadlineCannotExpireANewerRecordingHandoff() async throws {
        let center = FakeReportNotificationCenter()
        let window = UIWindow()
        var deadlines: [CheckedContinuation<Void, Never>] = []
        let controller = ReportNotificationController(center: center, windowProvider: { window }, eligible: { _ in true },
                                                      isActive: { _ in false },
                                                      handoffSleep: { _ in await withCheckedContinuation { deadlines.append($0) } },
                                                      present: { _, _ in XCTFail("Unexpected report") })
        defer { controller.stop() }
        await controller.start()
        controller.handle(identifier: try XCTUnwrap(controller.requestID), action: ReportNotificationController.recordAction)
        await flush()
        controller.hide()
        controller.show()
        await controller.activate()
        controller.handle(identifier: try XCTUnwrap(controller.requestID), action: ReportNotificationController.recordAction)
        await flush()
        XCTAssertEqual(deadlines.count, 2)
        deadlines[0].resume()
        await flush()
        await controller.activate()
        XCTAssertTrue(center.present.isEmpty)
        deadlines[1].resume()
        await flush()
        await controller.activate()
        XCTAssertEqual(center.present.count, 1)
    }

    func testDeliveryFailureSuppressesAutomaticRetriesAndExplicitShowRecovers() async {
        let center = FakeReportNotificationCenter()
        center.addError = NotificationDeliveryFailure.unavailable
        let window = UIWindow()
        let controller = ReportNotificationController(
            center: center,
            windowProvider: { window },
            eligible: { _ in true },
            present: { _, _ in }
        )
        defer { controller.stop() }
        await controller.start()
        XCTAssertNil(controller.requestID)
        XCTAssertTrue(controller.hidden)
        XCTAssertTrue(center.present.isEmpty)
        await controller.activate()
        await controller.activate()
        XCTAssertEqual(center.addAttempts.count, 1)
        center.addError = nil
        controller.show()
        await controller.activate()
        XCTAssertFalse(controller.hidden)
        XCTAssertNotNil(controller.requestID)
        XCTAssertEqual(center.addAttempts.count, 2)
        XCTAssertEqual(center.present.count, 1)
    }

    func testLateDeliveryFailureDoesNotHideNewExplicitVisibilityRequest() async throws {
        let center = FakeReportNotificationCenter()
        center.addError = NotificationDeliveryFailure.unavailable
        center.suspendAdding = true
        let window = UIWindow()
        let controller = ReportNotificationController(
            center: center,
            windowProvider: { window },
            eligible: { _ in true },
            present: { _, _ in }
        )
        defer { controller.stop() }
        let starting = Task { await controller.start() }
        for _ in 0 ..< 100 where center.suspendedAdd == nil {
            await Task.yield()
        }
        let old = try XCTUnwrap(controller.requestID)
        controller.show()
        center.addError = nil
        center.suspendAdding = false
        center.suspendedAdd?.resume()
        await starting.value
        await flush()
        await controller.activate()
        XCTAssertFalse(controller.hidden)
        XCTAssertNotEqual(controller.requestID, old)
        XCTAssertEqual(center.addAttempts.count, 2)
        XCTAssertEqual(center.present.count, 1)
    }

    private func flush() async {
        for _ in 0 ..< 50 {
            await Task.yield()
        }
    }
}

private enum NotificationDeliveryFailure: Error {
    case unavailable
}
