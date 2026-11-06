import CoreGraphics
import Foundation

struct RecordingProfile {
    let shortEdge: Int
    let longEdge: Int
    let framesPerSecond: Int
    let bitrate: Int
    let byteLimit: Int

    init(_ quality: ScreenRecordingQuality) {
        switch quality {
        case .low: (shortEdge, longEdge, framesPerSecond, bitrate, byteLimit) = (480, 1066, 10, 750_000, 8 * 1024 * 1024)
        case .balanced: (shortEdge, longEdge, framesPerSecond, bitrate, byteLimit) = (720, 1600, 15, 1_500_000, 16 * 1024 * 1024)
        case .high: (shortEdge, longEdge, framesPerSecond, bitrate, byteLimit) = (1080, 2400, 30, 4_000_000, 32 * 1024 * 1024)
        }
    }

    func dimensions(_ size: CGSize) -> (Int, Int) {
        let scale = min(1, CGFloat(shortEdge) / min(size.width, size.height), CGFloat(longEdge) / max(size.width, size.height))
        return (max(2, Int(size.width * scale) / 2 * 2), max(2, Int(size.height * scale) / 2 * 2))
    }
}

/// Lifecycle decisions are separate from platform callbacks so Stop/background races are testable.
struct RecordingLifecycle {
    private(set) var enabled = false
    private(set) var foreground = false
    private(set) var reporter = false
    private(set) var approved = false
    private(set) var armed = false
    private(set) var state: ScreenRecordingState = .disabled

    mutating func enable(_ value: Bool) {
        enabled = value
        if !value {
            approved = false
            armed = false
            state = .disabled
        } else if state != .requestingConsent, !approved {
            armed = true
            state = reporter ? .pausedForReporter : .waitingForForeground
        }
    }

    mutating func foreground(_ value: Bool) {
        foreground = value
        if !value, approved {
            approved = false
            armed = true
            state = reporter ? .pausedForReporter : .waitingForForeground
        }
    }

    mutating func report(_ value: Bool) {
        reporter = value
        if value, enabled, approved || armed || state == .requestingConsent { state = .pausedForReporter }
        if !value, approved {
            state = .recording
        } else if !value, enabled, armed { state = .waitingForForeground }
    }

    var canRequest: Bool {
        enabled && armed && foreground && !reporter && !approved && state != .requestingConsent
    }

    mutating func requestIfEligible() -> Bool {
        guard canRequest else { return false }
        armed = false
        state = .requestingConsent
        return true
    }

    mutating func started() -> Bool {
        guard enabled, foreground else {
            fail(.interrupted)
            return false
        }
        approved = true
        state = reporter ? .pausedForReporter : .recording
        return true
    }

    mutating func fail(_ reason: ScreenRecordingUnavailableReason) {
        approved = false
        armed = false
        state = enabled ? .unavailable(reason) : .disabled
    }
}
