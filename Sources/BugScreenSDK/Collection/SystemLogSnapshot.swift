import Foundation

final class SystemLogLifetime: @unchecked Sendable {
    let enabledAt: Date
    private let lock = NSLock()
    private var active = true
    private let parent: SystemLogLifetime?

    init(enabledAt: Date = Date(), parent: SystemLogLifetime? = nil) {
        self.enabledAt = parent?.enabledAt ?? enabledAt
        self.parent = parent
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active && parent?.isActive != false
    }

    func invalidate() {
        lock.lock()
        active = false
        lock.unlock()
    }

    func belongs(to ancestor: SystemLogLifetime) -> Bool {
        self === ancestor || parent?.belongs(to: ancestor) == true
    }
}

struct SystemLogSnapshot: Sendable {
    static let maximumBytes = 1_048_576
    let lifetime: SystemLogLifetime
    let records: [Data]

    func payload(maximumBytes: Int = Self.maximumBytes) -> Data? {
        guard lifetime.isActive, !records.isEmpty else { return nil }
        let limit = min(maximumBytes, Self.maximumBytes)
        guard limit > 1 else { return nil }

        var tail: [Data] = []
        var remaining = limit
        for record in records.reversed() {
            if record.count <= remaining {
                tail.append(record)
                remaining -= record.count
            } else {
                // Keep a UTF-8-safe tail even when the newest record alone exceeds the budget.
                if tail.isEmpty, let clipped = Self.suffix(record, maximumBytes: remaining) {
                    tail.append(clipped)
                }
                break
            }
        }
        guard !tail.isEmpty else { return nil }
        var result = Data()
        for record in tail.reversed() {
            result.append(record)
        }
        return result.count <= limit ? result : nil
    }

    private static func suffix(_ data: Data, maximumBytes: Int) -> Data? {
        var start = data.index(data.endIndex, offsetBy: -min(maximumBytes, data.count))
        while start < data.endIndex, data[start] & 0xC0 == 0x80 {
            start = data.index(after: start)
        }
        guard data.distance(from: start, to: data.endIndex) > 1 else { return nil }
        return Data(data[start...])
    }
}

struct SystemLogRecordBuffer {
    private static let maximumRecords = 8192
    private var slots = [Data?](repeating: nil, count: maximumRecords)
    private var head = 0
    private var recordCount = 0
    private(set) var byteCount = 0
    let maximumBytes: Int

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    mutating func append(_ fields: [String]) {
        guard maximumBytes > 1 else { return }
        var record = Data()
        record.reserveCapacity(min(maximumBytes, 4096))
        for field in fields {
            let bytes = field.utf8
            let remaining = maximumBytes - record.count - 1
            var end = bytes.index(bytes.startIndex, offsetBy: remaining, limitedBy: bytes.endIndex) ?? bytes.endIndex
            while end != bytes.endIndex, end > bytes.startIndex, bytes[end] & 0xC0 == 0x80 {
                end = bytes.index(before: end)
            }
            record.append(contentsOf: bytes[..<end])
            if end != bytes.endIndex {
                break
            }
        }
        record.append(10)
        while recordCount > 0, byteCount + record.count > maximumBytes || recordCount == Self.maximumRecords {
            byteCount -= slots[head]?.count ?? 0
            slots[head] = nil
            head = (head + 1) % Self.maximumRecords
            recordCount -= 1
        }
        slots[(head + recordCount) % Self.maximumRecords] = record
        recordCount += 1
        byteCount += record.count
    }

    var records: [Data] {
        (0 ..< recordCount).compactMap { slots[(head + $0) % Self.maximumRecords] }
    }
}
