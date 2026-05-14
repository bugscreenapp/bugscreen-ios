import Foundation
import os.log

internal enum SDKLog {
    static let log = OSLog(subsystem: "com.bugscreen.sdk", category: "BugScreenSDK")

    private static let lock = NSLock()
    private static var _enabled: Bool = false

    static var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _enabled
    }

    /// Kept independent of `BugScreenSDK.configuration` to avoid re-entering the
    /// SDK queue when read from inside its barrier blocks.
    static func setEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _enabled = enabled
    }

    static func internalLog(_ message: String, type: OSLogType = .default) {
        guard isEnabled else { return }
        os_log("%{public}@", log: log, type: type, message)
    }

    /// Category-aware variant for subsystems that want their own `OSLog` category
    /// (e.g. ScreenshotObserver) while still respecting the SDK-wide enable flag.
    static func internalLog(_ message: String, log: OSLog, type: OSLogType = .default) {
        guard isEnabled else { return }
        os_log("%{public}@", log: log, type: type, message)
    }
}
