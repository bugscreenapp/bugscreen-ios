import Foundation

/// Capture quality targets. Actual frame rate and bitrate depend on the device and screen content.
public enum ScreenRecordingQuality: String, CaseIterable, Sendable {
    case low, balanced, high
}

/// Local recent-video settings. These do not override the server's attachment limits.
public struct ScreenRecordingOptions: Equatable, Sendable {
    /// Effective history ceiling in seconds, clamped to 5...60. A clip can be shorter.
    public let durationSeconds: Int
    /// Encoding targets and compressed-memory budget; defaults to balanced.
    public let quality: ScreenRecordingQuality

    public init(durationSeconds: Int = 30, quality: ScreenRecordingQuality = .balanced) {
        self.durationSeconds = min(60, max(5, durationSeconds))
        self.quality = quality
    }
}

/// Why capture cannot currently run. Explicit enable retries after the condition changes.
public enum ScreenRecordingUnavailableReason: String, Sendable {
    case permissionDenied, stopped, interrupted, recorderBusy, captureUnavailable
    case hardwareEncoderUnavailable, unsupportedProfile, encodingFailed, memoryPressure, thermalPressure
}

/// Current capture state. Enabling recording does not bypass the system's consent prompt.
public enum ScreenRecordingState: Equatable, Sendable {
    case disabled, waitingForForeground, requestingConsent, recording, pausedForReporter
    case unavailable(ScreenRecordingUnavailableReason)
}
