import Foundation
import os.log

/// Thread-safe circular buffer logger for the BugScreen SDK.
///
/// The logger maintains a rolling buffer of log entries in memory, automatically
/// removing old entries when the 1MB limit is reached. Logs are included with bug
/// reports to provide debugging context.
///
/// All methods are thread-safe and can be called from any queue.
internal class Logger {

    // MARK: - Properties

    /// Maximum buffer size in bytes (1MB)
    private let maxSizeBytes: Int = 1_024_000

    /// Current total size of all log entries in bytes
    private var currentSizeBytes: Int = 0

    /// Array of log entries in chronological order
    private var entries: [LogEntry] = []

    /// Lock for thread-safe access to entries
    private let lock = NSLock()

    /// Whether to also output logs to OSLog (Xcode console)
    private let enableConsoleLogging: Bool

    // MARK: - Log Entry

    /// Represents a single log entry with timestamp and message.
    struct LogEntry {
        let timestamp: Date
        let level: LogLevel
        let message: String

        /// Returns the formatted log entry string.
        ///
        /// Format: "YYYY-MM-DD HH:mm:ss.SSS [LEVEL] message"
        var formatted: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            return "\(formatter.string(from: timestamp)) [\(level.displayName)] \(message)"
        }

        /// Returns the byte size of the formatted entry.
        var sizeBytes: Int {
            formatted.utf8.count
        }
    }

    // MARK: - Initialization

    init(enableConsoleLogging: Bool = false) {
        self.enableConsoleLogging = enableConsoleLogging
    }

    // MARK: - Public Methods

    /// Logs a message with the specified level.
    ///
    /// Messages are stored in a circular buffer with a maximum size of 1MB.
    /// When the buffer is full, the oldest entries are automatically removed.
    ///
    /// This method is thread-safe and can be called from any queue.
    ///
    /// - Parameters:
    ///   - message: The message to log
    ///   - level: The importance level of the message
    func log(_ message: String, level: LogLevel) {
        lock.lock()
        defer { lock.unlock() }

        // Create log entry
        let entry = LogEntry(timestamp: Date(), level: level, message: message)

        // Add to buffer
        entries.append(entry)
        currentSizeBytes += entry.sizeBytes

        // Prune old entries if over limit
        while currentSizeBytes > maxSizeBytes && !entries.isEmpty {
            let removed = entries.removeFirst()
            currentSizeBytes -= removed.sizeBytes
        }

        // Also log to OSLog if enabled (for Xcode console debugging)
        if enableConsoleLogging {
            os_log(
                "%{public}@",
                log: SDKLog.log,
                type: level.osLogType,
                entry.formatted
            )
        }
    }

    /// Exports all log entries to a temporary file.
    ///
    /// Creates a text file containing all current log entries, one per line,
    /// in chronological order. The file is created in the system's temporary
    /// directory and should be deleted after use.
    ///
    /// This method is thread-safe and can be called from any queue.
    ///
    /// - Returns: URL of the exported log file, or nil if export failed
    func exportToFile() -> URL? {
        lock.lock()
        defer { lock.unlock() }

        // Join all formatted entries with newlines
        let content = entries.map { $0.formatted }.joined(separator: "\n")

        // Create temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "bugscreen_logs_\(timestamp).txt"
        let fileURL = tempDir.appendingPathComponent(filename)

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            SDKLog.internalLog("Failed to export logs: \(error.localizedDescription)", type: .error)
            return nil
        }
    }

    /// Clears all log entries from the buffer.
    ///
    /// Removes all stored log entries and resets the buffer size to zero.
    /// This method is thread-safe and can be called from any queue.
    func clear() {
        lock.lock()
        defer { lock.unlock() }

        entries.removeAll()
        currentSizeBytes = 0
    }

    /// Returns the current number of log entries in the buffer.
    ///
    /// This method is thread-safe and can be called from any queue.
    ///
    /// - Returns: Number of log entries currently stored
    func entryCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Returns the current buffer size in bytes.
    ///
    /// This method is thread-safe and can be called from any queue.
    ///
    /// - Returns: Total size of all log entries in bytes
    func bufferSize() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return currentSizeBytes
    }

}

// MARK: - Testing Support

#if DEBUG
extension Logger {
    /// Returns all log entries (for testing only).
    ///
    /// This method is only available in debug builds for unit testing.
    func allEntries() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// Returns whether console mirroring is enabled (for testing only).
    var consoleLoggingEnabled: Bool { enableConsoleLogging }
}
#endif
