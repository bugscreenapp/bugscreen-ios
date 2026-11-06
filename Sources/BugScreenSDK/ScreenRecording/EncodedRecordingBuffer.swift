import CoreMedia
import Foundation

struct RecordedSample {
    let buffer: CMSampleBuffer
    let timestamp: Double
    var duration: Double
    let bytes: Int
    let keyframe: Bool
    var retention: RecordingPayloadLease?
}

/// Owns compressed bytes only. A frozen export takes this array instead of copying its payload.
struct EncodedRecordingBuffer {
    // Bound metadata independently of compressed bytes at the largest supported duration and cadence.
    private static let maximumSampleCount = 60 * 30
    let duration: Double
    let byteLimit: Int
    var budget: RecordingPayloadBudget?
    private(set) var samples: [RecordedSample] = []
    private(set) var byteCount = 0

    mutating func append(_ incoming: RecordedSample) {
        var sample = incoming
        guard sample.timestamp.isFinite, sample.duration.isFinite, sample.duration > 0,
              sample.bytes > 0, sample.bytes <= byteLimit
        else { clear(); return }
        if let last = samples.last, sample.timestamp <= last.timestamp { return }
        if samples.isEmpty, !sample.keyframe { return }
        makeRoom(for: sample.bytes)
        if samples.isEmpty, !sample.keyframe { return }
        if let budget {
            guard let lease = budget.reserve(sample.bytes, limit: byteLimit) else { clear(); return }
            sample.retention = lease
        }
        samples.append(sample)
        byteCount += sample.bytes
        let cutoff = sample.timestamp + sample.duration - duration
        while let first = samples.first, first.timestamp < cutoff {
            guard let nextKeyframe = samples.dropFirst().firstIndex(where: \.keyframe) else { clear(); return }
            removeFirst(nextKeyframe)
        }
    }

    private mutating func makeRoom(for bytes: Int) {
        while byteCount + bytes > byteLimit || samples.count >= Self.maximumSampleCount {
            if let nextKeyframe = samples.dropFirst().firstIndex(where: \.keyframe) {
                removeFirst(nextKeyframe)
            } else { clear(); break }
        }
    }

    mutating func take() -> [RecordedSample] {
        let result = samples
        clear()
        return result
    }

    mutating func clear() {
        samples = []; byteCount = 0
    }

    private mutating func removeFirst(_ count: Int) {
        byteCount -= samples.prefix(count).reduce(0) { $0 + $1.bytes }
        samples.removeFirst(count)
    }

    static func selection(_ samples: [RecordedSample], maximumDuration: Double, endingAt trigger: Double) -> [RecordedSample] {
        guard maximumDuration.isFinite, maximumDuration > 0, trigger.isFinite else { return [] }
        let cutoff = trigger - maximumDuration
        guard let first = samples.firstIndex(where: { $0.keyframe && $0.timestamp >= cutoff && $0.timestamp < trigger }) else { return [] }
        var selected = Array(samples[first...].prefix { $0.timestamp < trigger })
        guard let last = selected.indices.last else { return [] }
        selected[last].duration = min(selected[last].duration, trigger - selected[last].timestamp)
        return selected
    }
}

/// Reservations follow payload references through frozen exports and SDK reconfiguration.
final class RecordingPayloadBudget: @unchecked Sendable {
    static let shared = RecordingPayloadBudget()
    private let lock = NSLock()
    private var bytes = 0

    var retainedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    func reserve(_ count: Int, limit: Int) -> RecordingPayloadLease? {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0, count <= limit, bytes <= limit - count else { return nil }
        bytes += count
        return RecordingPayloadLease(count: count, budget: self)
    }

    fileprivate func release(_ count: Int) {
        lock.lock()
        bytes -= count
        lock.unlock()
    }
}

final class RecordingPayloadLease {
    private let count: Int
    private let budget: RecordingPayloadBudget
    fileprivate init(count: Int, budget: RecordingPayloadBudget) {
        self.count = count; self.budget = budget
    }

    deinit { budget.release(count) }
}
