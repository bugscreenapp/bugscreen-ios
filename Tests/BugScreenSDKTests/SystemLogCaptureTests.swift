@testable import BugScreenSDK
import os
import XCTest

@MainActor
final class SystemLogCaptureTests: XCTestCase {
    func testOSLogStoreProbeRecordsActualAvailabilityAndPrivacy() async throws {
        let lifetime = SystemLogLifetime()
        let publicMarker = "bugscreen-system-log-probe-\(UUID().uuidString)"
        let privateMarker = "private-probe-\(UUID().uuidString)"
        let logger = os.Logger(subsystem: "app.bugscreen.tests", category: "system-log-probe")
        logger.notice("\(publicMarker, privacy: .public) \(privateMarker, privacy: .private)")
        try await Task.sleep(nanoseconds: 100_000_000)
        let result = await SystemLogCapture().capture(lifetime: lifetime)
        guard let payload = result?.payload(), let text = String(data: payload, encoding: .utf8), text.contains(publicMarker) else {
            throw XCTSkip("OSLogStore probe did not return the public marker within the capture budget on this test host")
        }
        XCTAssertLessThanOrEqual(payload.count, SystemLogSnapshot.maximumBytes)
        print("OSLogStore probe: public marker present; private sample visible: \(text.contains(privateMarker))")
    }

    func testSuccessAndUnavailableCapture() async {
        let capture = SystemLogCapture { request, _ in makeSystemLogSnapshot(lifetime: request.lifetime) }
        let result = await capture.capture(lifetime: SystemLogLifetime())
        XCTAssertNotNil(result)
        XCTAssertFalse(capture.hasOutstandingWorker)
        let unavailable = SystemLogCapture { _, _ in nil }
        let missing = await unavailable.capture(lifetime: SystemLogLifetime())
        XCTAssertNil(missing)
    }

    func testLateResultIsDiscardedBeforeTimeoutCallbackRuns() async {
        let clock = ControlledSystemLogClock()
        let capture = SystemLogCapture(waitBudget: 30, now: { clock.now }, worker: { request, _ in
            clock.advancePastDeadline()
            return makeSystemLogSnapshot(lifetime: request.lifetime)
        })
        let result = await capture.capture(lifetime: SystemLogLifetime())
        XCTAssertNil(result)
        XCTAssertFalse(capture.hasOutstandingWorker)
    }

    func testTimeoutReturnsWhileWorkerStaysBusyAcrossReconfiguration() async {
        let gate = BlockingSystemLogWorker()
        let capture = SystemLogCapture(waitBudget: 0.1, worker: { request, cancellation in gate.run(request, cancellation) })
        let firstLifetime = SystemLogLifetime()
        let result = await capture.capture(lifetime: firstLifetime)
        await waitUntil { gate.calls == 1 }
        XCTAssertNil(result)
        XCTAssertTrue(capture.hasOutstandingWorker)
        capture.invalidate(firstLifetime)
        let newLifetime = SystemLogLifetime()
        let skipped = await capture.capture(lifetime: newLifetime)
        XCTAssertNil(skipped)
        XCTAssertEqual(gate.calls, 1)
        gate.release()
        await drain(capture)
        XCTAssertFalse(capture.hasOutstandingWorker)
        gate.release()
        _ = await capture.capture(lifetime: newLifetime)
        await drain(capture)
        XCTAssertEqual(gate.calls, 2)
    }

    func testCancellationDiscardsLateResultWithoutFreeingWorkerSlot() async {
        let gate = BlockingSystemLogWorker()
        let capture = SystemLogCapture(waitBudget: 30, worker: { request, cancellation in gate.run(request, cancellation) })
        let task = Task { await capture.capture(lifetime: SystemLogLifetime()) }
        while !capture.hasOutstandingWorker {
            await Task.yield()
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertTrue(capture.hasOutstandingWorker)
        gate.release()
        await drain(capture)
    }

    func testInvalidationResumesWaiterBeforeOSCallReturns() async {
        let gate = BlockingSystemLogWorker()
        let capture = SystemLogCapture(waitBudget: 30, worker: { request, cancellation in gate.run(request, cancellation) })
        let lifetime = SystemLogLifetime()
        let task = Task { await capture.capture(lifetime: lifetime) }
        while !capture.hasOutstandingWorker {
            await Task.yield()
        }
        capture.invalidate(lifetime)
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertTrue(capture.hasOutstandingWorker)
        gate.release()
        await drain(capture)
    }

    func testReconfigurationInvalidatesPendingChildReportBeforeOSCallReturns() async {
        let gate = BlockingSystemLogWorker()
        let capture = SystemLogCapture(waitBudget: 30, worker: { request, cancellation in gate.run(request, cancellation) })
        let configuration = SystemLogLifetime()
        let child = SystemLogLifetime(parent: configuration)
        let task = Task { await capture.capture(lifetime: child) }
        await waitUntil { capture.hasOutstandingWorker }
        capture.invalidate(configuration)
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertFalse(child.isActive)
        XCTAssertTrue(capture.hasOutstandingWorker)
        gate.release()
        await drain(capture)
    }

    private func drain(_ capture: SystemLogCapture) async {
        await waitUntil { !capture.hasOutstandingWorker }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition())
    }
}

private final class ControlledSystemLogClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = DispatchTime.now()

    var now: DispatchTime {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advancePastDeadline() {
        lock.lock()
        value = .distantFuture
        lock.unlock()
    }
}

private final class BlockingSystemLogWorker: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var callCount = 0

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    func run(_ request: SystemLogCaptureRequest, _: SystemLogLifetime) -> SystemLogSnapshot? {
        lock.lock()
        callCount += 1
        lock.unlock()
        _ = semaphore.wait(timeout: .now() + 5)
        return makeSystemLogSnapshot(lifetime: request.lifetime)
    }

    func release() {
        semaphore.signal()
    }
}
