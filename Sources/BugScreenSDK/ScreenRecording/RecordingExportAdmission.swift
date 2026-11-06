import Foundation

/// One generated export may own AVFoundation work, including cancellation callbacks, at a time.
final class RecordingExportAdmission: @unchecked Sendable {
    static let shared = RecordingExportAdmission()
    private let lock = NSLock()
    private var occupied = false

    func acquire() -> RecordingExportLease? {
        lock.lock()
        defer { lock.unlock() }
        guard !occupied else { return nil }
        occupied = true
        return RecordingExportLease(owner: self)
    }

    func run<Value>(_ operation: (RecordingExportLease) async throws -> Value) async throws -> Value {
        guard let lease = acquire() else { throw VideoPreparationError.processing }
        defer { withExtendedLifetime(lease) {} }
        return try await operation(lease)
    }

    fileprivate func release() {
        lock.lock()
        occupied = false
        lock.unlock()
    }
}

final class RecordingExportLease: @unchecked Sendable {
    private let owner: RecordingExportAdmission
    fileprivate init(owner: RecordingExportAdmission) {
        self.owner = owner
    }

    deinit { owner.release() }
}
