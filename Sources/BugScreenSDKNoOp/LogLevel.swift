import Foundation

/// No-op mirror of ``BugScreenSDK/LogLevel``. Value-only type, so it is a faithful
/// copy of the real enum's public surface — only the internal `osLogType` mapping
/// (which the real SDK uses for console output) is omitted, since the stub never logs.
public enum LogLevel: Int, Comparable, CaseIterable, Sendable {
    case verbose = 0
    case debug = 1
    case info = 2
    case warning = 3
    case error = 4

    public var displayName: String {
        switch self {
        case .verbose:
            "VERBOSE"
        case .debug:
            "DEBUG"
        case .info:
            "INFO"
        case .warning:
            "WARN"
        case .error:
            "ERROR"
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
