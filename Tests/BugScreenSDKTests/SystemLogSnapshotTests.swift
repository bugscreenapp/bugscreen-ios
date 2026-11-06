@testable import BugScreenSDK
import XCTest

final class SystemLogSnapshotTests: XCTestCase {
    func testWindowRejectsOtherProcessesAndRecordsOutsideOptInAndFiveMinutes() {
        let end = Date(timeIntervalSince1970: 1000)
        let lifetime = SystemLogLifetime(enabledAt: end.addingTimeInterval(-600))
        var request = SystemLogCaptureRequest(lifetime: lifetime, capturedAt: end)
        request.processIdentifier = 42
        XCTAssertTrue(request.includes(date: end.addingTimeInterval(-300), processIdentifier: 42))
        XCTAssertTrue(request.includes(date: end, processIdentifier: 42))
        XCTAssertFalse(request.includes(date: end.addingTimeInterval(-301), processIdentifier: 42))
        XCTAssertFalse(request.includes(date: end.addingTimeInterval(1), processIdentifier: 42))
        XCTAssertFalse(request.includes(date: end, processIdentifier: 43))
        let recent = SystemLogCaptureRequest(lifetime: SystemLogLifetime(enabledAt: end.addingTimeInterval(-10)), capturedAt: end)
        XCTAssertEqual(recent.start, end.addingTimeInterval(-10))
    }

    func testNoisyRecordsRemainBoundedAndRetainNewestInOrder() throws {
        var buffer = SystemLogRecordBuffer(maximumBytes: 256)
        for index in 0 ..< 100_000 {
            buffer.append(["record-\(index)"])
            XCTAssertLessThanOrEqual(buffer.byteCount, 256)
        }
        let text = try XCTUnwrap(String(data: buffer.records.reduce(into: Data()) { $0.append($1) }, encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("record-99998\nrecord-99999\n"))
        XCTAssertFalse(text.contains("record-0\n"))
    }

    func testOversizedMultibyteRecordIsBoundedDuringEncoding() throws {
        var buffer = SystemLogRecordBuffer(maximumBytes: 19)
        buffer.append([String(repeating: "🧪", count: 100_000)])
        let record = try XCTUnwrap(buffer.records.first)
        XCTAssertLessThanOrEqual(buffer.byteCount, 19)
        XCTAssertEqual(String(data: record, encoding: .utf8), "🧪🧪🧪🧪\n")
    }

    func testPayloadContainsOnlyOriginalRecords() throws {
        let snapshot = makeSystemLogSnapshot(records: ["first record\n", "second record\n"])
        let bytes = try XCTUnwrap(snapshot.payload())
        XCTAssertEqual(String(data: bytes, encoding: .utf8), "first record\nsecond record\n")
    }

    func testPayloadContainsOnlyRecordsAndTrimsOnlyOldestRecords() throws {
        let snapshot = makeSystemLogSnapshot(records: ["old\n", "middle\n", "new🧪\n"])
        let limit = "new🧪\n".utf8.count
        let bytes = try XCTUnwrap(snapshot.payload(maximumBytes: limit))
        XCTAssertEqual(bytes.count, limit)
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertEqual(text, "new🧪\n")
        XCTAssertFalse(text.contains("middle\n"))
        XCTAssertNil(snapshot.payload(maximumBytes: 1))
        XCTAssertNil(snapshot.payload(maximumBytes: 0))
        XCTAssertNil(snapshot.payload(maximumBytes: -1))
    }

    func testPartialRecordTruncationNeverSplitsUTF8() throws {
        let snapshot = makeSystemLogSnapshot(records: ["🧪🧪🧪\n"])
        let limit = 7
        let bytes = try XCTUnwrap(snapshot.payload(maximumBytes: limit))
        XCTAssertNotNil(String(data: bytes, encoding: .utf8))
        XCTAssertTrue(try XCTUnwrap(String(data: bytes, encoding: .utf8)).hasSuffix("🧪\n"))
        XCTAssertLessThanOrEqual(bytes.count, limit)
    }

    func testEmptyAndInvalidatedSnapshotsProduceNoFile() {
        XCTAssertNil(makeSystemLogSnapshot(records: []).payload())
        let snapshot = makeSystemLogSnapshot()
        snapshot.lifetime.invalidate()
        XCTAssertNil(snapshot.payload())
    }

    func testDefaultPayloadLimitRetainsOnlyNewestRecords() throws {
        let snapshot = makeSystemLogSnapshot(records: [String(repeating: "a", count: 600_000) + "\n",
                                                       String(repeating: "b", count: 600_000) + "\n"])
        let bytes = try XCTUnwrap(snapshot.payload())
        XCTAssertLessThanOrEqual(bytes.count, SystemLogSnapshot.maximumBytes)
        XCTAssertEqual(String(data: bytes, encoding: .utf8), String(repeating: "b", count: 600_000) + "\n")
    }
}

func makeSystemLogSnapshot(lifetime: SystemLogLifetime = SystemLogLifetime(),
                           records: [String] = ["native marker\n"]) -> SystemLogSnapshot
{
    SystemLogSnapshot(lifetime: lifetime, records: records.map { Data($0.utf8) })
}
