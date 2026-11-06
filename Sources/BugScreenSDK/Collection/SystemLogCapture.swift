import Foundation
import OSLog

struct SystemLogCaptureRequest: Sendable {
    let lifetime: SystemLogLifetime
    let capturedAt: Date
    var processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier

    var start: Date {
        max(lifetime.enabledAt, capturedAt.addingTimeInterval(-300))
    }

    func includes(date: Date, processIdentifier: Int32) -> Bool {
        processIdentifier == self.processIdentifier && date >= start && date <= capturedAt
    }
}

@MainActor
final class SystemLogCapture {
    typealias Worker = @Sendable (SystemLogCaptureRequest, SystemLogLifetime) -> SystemLogSnapshot?
    static let shared = SystemLogCapture()

    private struct Pending {
        let id: UUID
        let lifetime: SystemLogLifetime
        let cancellation: SystemLogLifetime
        let deadline: DispatchTime
        let timer: DispatchWorkItem
        var continuation: CheckedContinuation<SystemLogSnapshot?, Never>?
    }

    private let queue = DispatchQueue(label: "app.bugscreen.system-log-capture", qos: .utility)
    private let worker: Worker
    private let waitBudget: TimeInterval
    private let now: @Sendable () -> DispatchTime
    private var pending: Pending?

    #if DEBUG
        var hasOutstandingWorker: Bool {
            pending != nil
        }
    #endif

    init(waitBudget: TimeInterval = 10, now: @escaping @Sendable () -> DispatchTime = { .now() },
         worker: @escaping Worker = { request, cancellation in
             SystemLogCapture.collect(request, cancellation: cancellation)
         })
    {
        self.waitBudget = waitBudget
        self.now = now
        self.worker = worker
    }

    func capture(lifetime: SystemLogLifetime, capturedAt: Date = Date()) async -> SystemLogSnapshot? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard lifetime.isActive, !Task.isCancelled, pending == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let cancellation = SystemLogLifetime()
                let deadline = now() + waitBudget
                let timer = DispatchWorkItem { [weak self] in
                    Task { @MainActor in self?.finish(id: id, result: nil) }
                }
                pending = Pending(id: id, lifetime: lifetime, cancellation: cancellation,
                                  deadline: deadline, timer: timer, continuation: continuation)
                let request = SystemLogCaptureRequest(lifetime: lifetime, capturedAt: capturedAt)
                let worker = worker
                queue.async { [weak self] in
                    let result = worker(request, cancellation)
                    Task { @MainActor in self?.workerFinished(id: id, result: result) }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline, execute: timer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id: id, result: nil) }
        }
    }

    func invalidate(_ lifetime: SystemLogLifetime) {
        lifetime.invalidate()
        if pending?.lifetime.belongs(to: lifetime) == true, let id = pending?.id { finish(id: id, result: nil) }
    }

    private func finish(id: UUID, result: SystemLogSnapshot?) {
        guard pending?.id == id, let continuation = pending?.continuation else { return }
        let withinDeadline = now().uptimeNanoseconds <= (pending?.deadline.uptimeNanoseconds ?? 0)
        let accepted = withinDeadline && pending?.lifetime.isActive == true && pending?.cancellation.isActive == true ? result : nil
        pending?.continuation = nil
        pending?.timer.cancel()
        pending?.cancellation.invalidate()
        continuation.resume(returning: accepted)
        // The worker owns the slot until its synchronous OS call actually returns.
    }

    private func workerFinished(id: UUID, result: SystemLogSnapshot?) {
        guard pending?.id == id else { return }
        finish(id: id, result: result)
        pending = nil
    }

    private nonisolated static func collect(_ request: SystemLogCaptureRequest,
                                            cancellation: SystemLogLifetime) -> SystemLogSnapshot?
    {
        do {
            guard cancellation.isActive, request.lifetime.isActive else { return nil }
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(at: store.position(date: request.start))
            var buffer = SystemLogRecordBuffer(maximumBytes: SystemLogSnapshot.maximumBytes)
            let formatter = ISO8601DateFormatter()
            for entry in entries {
                guard cancellation.isActive, request.lifetime.isActive else { return nil }
                guard let log = entry as? OSLogEntryLog,
                      request.includes(date: log.date, processIdentifier: log.processIdentifier) else { continue }
                autoreleasepool {
                    buffer.append([formatter.string(from: log.date), " [", String(log.level.rawValue), "] ",
                                   log.subsystem, "/", log.category, ": ", log.composedMessage])
                }
            }
            guard !buffer.records.isEmpty, cancellation.isActive, request.lifetime.isActive else { return nil }
            return SystemLogSnapshot(lifetime: request.lifetime, records: buffer.records)
        } catch {
            SDKLog.internalLog("System-log capture unavailable", type: .debug)
            return nil
        }
    }
}
