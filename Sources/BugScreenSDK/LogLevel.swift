import Foundation
import os.log

/// Logging levels for BugScreen SDK messages.
///
/// Use these levels to categorize log messages by importance. Logs are stored in a circular buffer
/// and included with bug reports to provide debugging context.
///
/// Example:
/// ```swift
/// BugScreenSDK.log("User logged in", level: .info)
/// BugScreenSDK.log("Network request started", level: .debug)
/// BugScreenSDK.log("Failed to load data", level: .error)
/// ```
public enum LogLevel: Int, Comparable, CaseIterable, Sendable {
    /// Verbose logging for very detailed debugging information
    case verbose = 0

    /// Debug logging for development and troubleshooting
    case debug = 1

    /// Informational logging for general application events
    case info = 2

    /// Warning logging for non-critical issues
    case warning = 3

    /// Error logging for failures and exceptions
    case error = 4

    /// Human-readable display name for the log level
    public var displayName: String {
        switch self {
        case .verbose:
            return "VERBOSE"
        case .debug:
            return "DEBUG"
        case .info:
            return "INFO"
        case .warning:
            return "WARN"
        case .error:
            return "ERROR"
        }
    }

    /// Maps log level to OSLogType for Xcode console output
    var osLogType: OSLogType {
        switch self {
        case .verbose:
            return .debug
        case .debug:
            return .debug
        case .info:
            return .info
        case .warning:
            return .default
        case .error:
            return .error
        }
    }

    /// Comparable conformance for filtering logs by level
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}
