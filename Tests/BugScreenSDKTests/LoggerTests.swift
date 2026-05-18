import XCTest
@testable import BugScreenSDK

/// Tests for Logger circular buffer functionality.
final class LoggerTests: XCTestCase {

    var logger: Logger!

    override func setUp() {
        super.setUp()
        logger = Logger()
    }

    override func tearDown() {
        logger = nil
        super.tearDown()
    }

    // MARK: - Basic Logging Tests

    func testLogSingleMessage() {
        logger.log("Test message", level: .info)

        XCTAssertEqual(logger.entryCount(), 1, "Should have 1 log entry")
        XCTAssertGreaterThan(logger.bufferSize(), 0, "Buffer size should be greater than 0")
    }

    func testLogMultipleMessages() {
        logger.log("Message 1", level: .info)
        logger.log("Message 2", level: .debug)
        logger.log("Message 3", level: .error)

        XCTAssertEqual(logger.entryCount(), 3, "Should have 3 log entries")
    }

    func testLogWithDifferentLevels() {
        logger.log("Verbose", level: .verbose)
        logger.log("Debug", level: .debug)
        logger.log("Info", level: .info)
        logger.log("Warn", level: .warning)
        logger.log("Error", level: .error)

        XCTAssertEqual(logger.entryCount(), 5, "Should have 5 log entries")
    }

    // MARK: - Circular Buffer Tests

    func testCircularBufferPruning() {
        // Generate enough logs to exceed 1MB
        // Assuming ~100 bytes per entry, we need ~11,000 entries
        let largeMessage = String(repeating: "X", count: 100)

        for i in 0..<15000 {
            logger.log("Message \(i): \(largeMessage)", level: .info)
        }

        // Buffer should have pruned old entries
        XCTAssertLessThan(
            logger.bufferSize(),
            1_024_000 + 10000, // Allow small margin
            "Buffer size should not significantly exceed 1MB"
        )
        XCTAssertLessThan(
            logger.entryCount(),
            15000,
            "Entry count should be less than total logged (oldest removed)"
        )
    }

    func testBufferSizeTracking() {
        let message = "Test"
        logger.log(message, level: .info)

        let bufferSize = logger.bufferSize()

        XCTAssertGreaterThan(bufferSize, 0, "Buffer size should be greater than 0")
        XCTAssertGreaterThan(
            bufferSize,
            message.count,
            "Buffer size should include timestamp and level formatting"
        )
    }

    // MARK: - Export Tests

    func testExportToFile() {
        logger.log("Message 1", level: .info)
        logger.log("Message 2", level: .debug)
        logger.log("Message 3", level: .error)

        let fileURL = logger.exportToFile()

        XCTAssertNotNil(fileURL, "Export should return a file URL")

        if let url = fileURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "File should exist")

            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                XCTAssertTrue(content.contains("Message 1"), "Content should contain Message 1")
                XCTAssertTrue(content.contains("Message 2"), "Content should contain Message 2")
                XCTAssertTrue(content.contains("Message 3"), "Content should contain Message 3")
                XCTAssertTrue(content.contains("[INFO]"), "Content should contain log level")
                XCTAssertTrue(content.contains("[DEBUG]"), "Content should contain log level")
                XCTAssertTrue(content.contains("[ERROR]"), "Content should contain log level")

                // Clean up
                try FileManager.default.removeItem(at: url)
            } catch {
                XCTFail("Failed to read or clean up exported file: \(error)")
            }
        }
    }

    func testExportEmptyLogger() {
        let fileURL = logger.exportToFile()

        XCTAssertNotNil(fileURL, "Export should return a file URL even when empty")

        if let url = fileURL {
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                XCTAssertTrue(content.isEmpty, "Content should be empty")

                // Clean up
                try FileManager.default.removeItem(at: url)
            } catch {
                XCTFail("Failed to read or clean up exported file: \(error)")
            }
        }
    }

    func testExportFileFormat() {
        logger.log("Test message", level: .info)

        let fileURL = logger.exportToFile()

        if let url = fileURL {
            do {
                let content = try String(contentsOf: url, encoding: .utf8)

                // Verify timestamp format (YYYY-MM-DD HH:mm:ss.SSS)
                let timestampPattern = "\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d{3}"
                let regex = try NSRegularExpression(pattern: timestampPattern)
                let range = NSRange(content.startIndex..<content.endIndex, in: content)
                let matches = regex.numberOfMatches(in: content, range: range)

                XCTAssertGreaterThan(matches, 0, "Content should contain timestamp")

                // Clean up
                try FileManager.default.removeItem(at: url)
            } catch {
                XCTFail("Failed to verify file format: \(error)")
            }
        }
    }

    // MARK: - Clear Tests

    func testClear() {
        logger.log("Message 1", level: .info)
        logger.log("Message 2", level: .debug)

        XCTAssertEqual(logger.entryCount(), 2)
        XCTAssertGreaterThan(logger.bufferSize(), 0)

        logger.clear()

        XCTAssertEqual(logger.entryCount(), 0, "Entry count should be 0 after clear")
        XCTAssertEqual(logger.bufferSize(), 0, "Buffer size should be 0 after clear")
    }

    func testClearEmptyLogger() {
        logger.clear()

        XCTAssertEqual(logger.entryCount(), 0)
        XCTAssertEqual(logger.bufferSize(), 0)
    }

    // MARK: - Thread Safety Tests

    func testConcurrentLogging() {
        let expectation = self.expectation(description: "Concurrent logging")
        expectation.expectedFulfillmentCount = 100

        DispatchQueue.concurrentPerform(iterations: 100) { index in
            logger.log("Message from thread \(index)", level: .info)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)

        XCTAssertEqual(logger.entryCount(), 100, "Should have all 100 log entries")
    }

    func testConcurrentExport() {
        // Add some logs
        for i in 0..<10 {
            logger.log("Message \(i)", level: .info)
        }

        let expectation = self.expectation(description: "Concurrent export")
        expectation.expectedFulfillmentCount = 5

        DispatchQueue.concurrentPerform(iterations: 5) { _ in
            if let url = logger.exportToFile() {
                try? FileManager.default.removeItem(at: url)
            }
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)

        // Should not crash
        XCTAssertEqual(logger.entryCount(), 10, "Entry count should remain unchanged")
    }

    func testConcurrentClear() {
        // Add some logs
        for i in 0..<100 {
            logger.log("Message \(i)", level: .info)
        }

        let expectation = self.expectation(description: "Concurrent clear")
        expectation.expectedFulfillmentCount = 10

        DispatchQueue.concurrentPerform(iterations: 10) { _ in
            logger.clear()
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)

        // Should end up with 0 entries
        XCTAssertEqual(logger.entryCount(), 0, "Should have 0 entries after concurrent clears")
        XCTAssertEqual(logger.bufferSize(), 0, "Should have 0 buffer size after concurrent clears")
    }

    func testMixedConcurrentOperations() {
        let expectation = self.expectation(description: "Mixed concurrent operations")
        expectation.expectedFulfillmentCount = 30

        // Concurrent logging
        DispatchQueue.concurrentPerform(iterations: 10) { index in
            logger.log("Log \(index)", level: .info)
            expectation.fulfill()
        }

        // Concurrent exports
        DispatchQueue.concurrentPerform(iterations: 10) { _ in
            if let url = logger.exportToFile() {
                try? FileManager.default.removeItem(at: url)
            }
            expectation.fulfill()
        }

        // Concurrent queries
        DispatchQueue.concurrentPerform(iterations: 10) { _ in
            _ = logger.entryCount()
            _ = logger.bufferSize()
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)

        // Should not crash and should have reasonable state
        XCTAssertGreaterThanOrEqual(logger.entryCount(), 0)
    }

    // MARK: - Log Entry Format Tests

    #if DEBUG
    func testLogEntryFormat() {
        logger.log("Test message", level: .info)

        let entries = logger.allEntries()
        XCTAssertEqual(entries.count, 1)

        let entry = entries[0]
        let formatted = entry.formatted

        // Should contain timestamp
        XCTAssertTrue(formatted.contains("-"), "Should contain date separator")
        XCTAssertTrue(formatted.contains(":"), "Should contain time separator")

        // Should contain level
        XCTAssertTrue(formatted.contains("[INFO]"), "Should contain log level")

        // Should contain message
        XCTAssertTrue(formatted.contains("Test message"), "Should contain message")
    }

    func testLogEntryTimestamp() {
        let before = Date()
        logger.log("Test", level: .info)
        let after = Date()

        let entries = logger.allEntries()
        let entry = entries[0]

        XCTAssertGreaterThanOrEqual(entry.timestamp, before)
        XCTAssertLessThanOrEqual(entry.timestamp, after)
    }

    // MARK: - Console Mirroring Gate

    func testConsoleLoggingDisabledByDefault() {
        let defaultLogger = Logger()
        XCTAssertFalse(
            defaultLogger.consoleLoggingEnabled,
            "Console mirroring should be off when the flag is not provided"
        )
    }

    func testConsoleLoggingEnabledFlagRoundTrips() {
        let enabled = Logger(enableConsoleLogging: true)
        let disabled = Logger(enableConsoleLogging: false)

        XCTAssertTrue(enabled.consoleLoggingEnabled)
        XCTAssertFalse(disabled.consoleLoggingEnabled)
    }
    #endif
}
