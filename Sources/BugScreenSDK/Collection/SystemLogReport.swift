import Foundation

@MainActor
final class SystemLogReport {
    typealias Capture = @MainActor (SystemLogLifetime, Date) async -> SystemLogSnapshot?

    private let lifetime: SystemLogLifetime
    private var task: Task<Void, Never>?
    private var result: SystemLogSnapshot?
    private var completed = false
    private struct Waiter {
        let continuation: CheckedContinuation<SystemLogSnapshot?, Never>
        let deadline: DispatchTime
    }

    private var waiters: [UUID: Waiter] = [:]

    init(lifetime: SystemLogLifetime, openedAt: Date = Date(), capture: @escaping Capture) {
        let reportLifetime = SystemLogLifetime(parent: lifetime)
        self.lifetime = reportLifetime
        task = Task { [weak self] in
            let snapshot = await capture(reportLifetime, openedAt)
            self?.complete(snapshot)
        }
    }

    deinit {
        lifetime.invalidate()
        task?.cancel()
    }

    func snapshot(waitBudget: TimeInterval = 2) async -> SystemLogSnapshot? {
        guard !Task.isCancelled else {
            discard()
            return nil
        }
        guard lifetime.isActive else { return nil }
        if completed { return result }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard lifetime.isActive, !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                let deadline = DispatchTime.now() + waitBudget
                waiters[id] = Waiter(continuation: continuation, deadline: deadline)
                DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
                    guard self?.waiters[id] != nil else { return }
                    self?.discard()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.discard() }
        }
    }

    func discard() {
        lifetime.invalidate()
        task?.cancel()
        complete(nil)
    }

    private func complete(_ snapshot: SystemLogSnapshot?) {
        if waiters.values.contains(where: { DispatchTime.now() > $0.deadline }) {
            lifetime.invalidate()
        }
        result = lifetime.isActive ? snapshot : nil
        completed = true
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(returning: result)
        }
    }
}
