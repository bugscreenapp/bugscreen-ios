@testable import BugScreenSDK
import XCTest

@MainActor
final class SystemLogReportTests: XCTestCase {
    func testFirstCaptureFinishesWhileFormIsOpenAndIsReused() async {
        let openedAt = Date()
        let capture = SystemLogCapture { request, _ in
            XCTAssertEqual(request.capturedAt, openedAt)
            XCTAssertTrue(request.includes(date: openedAt, processIdentifier: request.processIdentifier))
            XCTAssertFalse(request.includes(date: openedAt.addingTimeInterval(1), processIdentifier: request.processIdentifier))
            return makeSystemLogSnapshot(lifetime: request.lifetime)
        }
        let captured = expectation(description: "Capture completes while the report is open")
        var calls = 0
        let report = SystemLogReport(lifetime: SystemLogLifetime(enabledAt: openedAt.addingTimeInterval(-60)),
                                     openedAt: openedAt)
        { lifetime, cutoff in
            calls += 1
            let snapshot = await capture.capture(lifetime: lifetime, capturedAt: cutoff)
            captured.fulfill()
            return snapshot
        }
        await fulfillment(of: [captured], timeout: 10)
        let first = await report.snapshot(waitBudget: 0)
        let retry = await report.snapshot(waitBudget: 0)
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.payload(), retry?.payload())
        XCTAssertEqual(calls, 1)
        report.discard()
    }

    func testImmediateSubmissionJoinsPendingCapture() async throws {
        var finish: CheckedContinuation<SystemLogSnapshot?, Never>?
        var capturedLifetime: SystemLogLifetime?
        let report = SystemLogReport(lifetime: SystemLogLifetime()) { lifetime, _ in
            capturedLifetime = lifetime
            return await withCheckedContinuation { finish = $0 }
        }
        while finish == nil {
            await Task.yield()
        }
        let submission = Task { await report.snapshot() }
        await Task.yield()
        finish?.resume(returning: makeSystemLogSnapshot(lifetime: try XCTUnwrap(capturedLifetime)))
        let snapshot = await submission.value
        XCTAssertNotNil(snapshot)
        report.discard()
    }

    func testSubmitDeadlineDiscardsLateResultAndDoesNotRecapture() async throws {
        var finish: CheckedContinuation<SystemLogSnapshot?, Never>?
        var capturedLifetime: SystemLogLifetime?
        let report = SystemLogReport(lifetime: SystemLogLifetime()) { lifetime, _ in
            capturedLifetime = lifetime
            return await withCheckedContinuation { finish = $0 }
        }
        while finish == nil {
            await Task.yield()
        }
        let timedOut = await report.snapshot(waitBudget: 0.01)
        XCTAssertNil(timedOut)
        XCTAssertFalse(try XCTUnwrap(capturedLifetime?.isActive))
        finish?.resume(returning: makeSystemLogSnapshot(lifetime: try XCTUnwrap(capturedLifetime)))
        await Task.yield()
        let retry = await report.snapshot()
        XCTAssertNil(retry)
    }

    func testDismissalInvalidatesReadySnapshotAndNewReportGetsFreshEvidence() async {
        let parent = SystemLogLifetime()
        let first = SystemLogReport(lifetime: parent) { lifetime, _ in makeSystemLogSnapshot(lifetime: lifetime) }
        let previous = await first.snapshot()
        XCTAssertNotNil(previous?.payload())
        first.discard()
        XCTAssertNil(previous?.payload())
        let second = SystemLogReport(lifetime: parent) { lifetime, _ in makeSystemLogSnapshot(lifetime: lifetime) }
        let fresh = await second.snapshot()
        XCTAssertNotNil(fresh?.payload())
        parent.invalidate()
        XCTAssertNil(fresh?.payload())
        let invalidated = await second.snapshot()
        XCTAssertNil(invalidated)
        second.discard()
    }

    func testDismissalResumesPendingSubmissionAndDropsLateCapture() async throws {
        var finish: CheckedContinuation<SystemLogSnapshot?, Never>?
        var capturedLifetime: SystemLogLifetime?
        let report = SystemLogReport(lifetime: SystemLogLifetime()) { lifetime, _ in
            capturedLifetime = lifetime
            return await withCheckedContinuation { finish = $0 }
        }
        while finish == nil {
            await Task.yield()
        }
        let submission = Task { await report.snapshot() }
        await Task.yield()
        report.discard()
        let result = await submission.value
        XCTAssertNil(result)
        finish?.resume(returning: makeSystemLogSnapshot(lifetime: try XCTUnwrap(capturedLifetime)))
    }

    func testCancellingPendingSubmissionDiscardsCaptureAndLateOutput() async throws {
        var finish: CheckedContinuation<SystemLogSnapshot?, Never>?
        var capturedLifetime: SystemLogLifetime?
        let report = SystemLogReport(lifetime: SystemLogLifetime()) { lifetime, _ in
            capturedLifetime = lifetime
            return await withCheckedContinuation { finish = $0 }
        }
        while finish == nil {
            await Task.yield()
        }
        let submission = Task { await report.snapshot() }
        await Task.yield()
        submission.cancel()
        let result = await submission.value
        XCTAssertNil(result)
        let lifetime = try XCTUnwrap(capturedLifetime)
        XCTAssertFalse(lifetime.isActive)
        finish?.resume(returning: makeSystemLogSnapshot(lifetime: lifetime))
        await Task.yield()
        let retry = await report.snapshot()
        XCTAssertNil(retry)
    }
}
