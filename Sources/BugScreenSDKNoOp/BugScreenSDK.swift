import Foundation
import UIKit

/// No-op stub of ``BugScreenSDK`` for production builds.
///
/// This target reproduces the real SDK's public API surface with empty bodies so
/// an app can depend on the real SDK in Debug and this stub in Release (CocoaPods
/// `:configurations`) without touching call sites. See DX-009 and the Android
/// `:no-op` module it mirrors. Every method here is intentionally inert: no
/// networking, no UI, no screenshot detection, no resource bundle, and no privacy
/// manifest ship in the release binary.
///
/// The public surface below is kept byte-for-byte identical to the real
/// ``BugScreenSDK`` — enforced in CI by `sdks/ios/scripts/check-noop-parity.sh`.
@MainActor
public enum BugScreenSDK {
    /// Always `false` in the no-op — nothing is ever configured.
    public static var isConfigured: Bool {
        false
    }

    public static func setShakeDetectionEnabled(_: Bool) {}

    public static func showReportNotification(requestPermission _: Bool = true) {}
    public static func hideReportNotification() {}

    public static func showFloatingButton() {}
    public static func hideFloatingButton() {}

    public static func configure(
        apiKey _: String,
        enableScreenshotDetection _: Bool = true,
        showFloatingButton _: Bool,
        startScreenRecordingImmediately _: Bool = false,
        screenRecordingOptions _: ScreenRecordingOptions = .init(),
        debug _: Bool = false,
        captureSystemLogs _: Bool = false
    ) {}

    public static func configure(
        apiKey _: String,
        enableScreenshotDetection _: Bool = true,
        debug _: Bool = false
    ) {}

    public static func configure(
        apiKey _: String,
        enableScreenshotDetection _: Bool = true,
        debug _: Bool = false,
        captureSystemLogs _: Bool
    ) {}

    public static var screenRecordingState: ScreenRecordingState {
        .disabled
    }

    public static func startScreenRecording() {}

    public static func stopScreenRecording() {}

    public static func configure(
        apiKey _: String,
        enableScreenshotDetection _: Bool = true,
        enableShakeDetection _: Bool = false,
        debug _: Bool = false,
        captureSystemLogs _: Bool = false,
        showReportNotification _: Bool = false,
        requestNotificationPermission _: Bool = true,
        startScreenRecordingImmediately _: Bool = false,
        screenRecordingOptions _: ScreenRecordingOptions = .init(),
        showFloatingButton _: Bool = false
    ) {}

    public static func log(_: String, level _: LogLevel = .info) {}

    public static func setCustomData(_: [String: String]) {}

    public static func setCustomData(key _: String, value _: String) {}

    public static func removeCustomData(key _: String) {}

    public static func addCustomData(_: [String: String]) {}

    public static func clearCustomData() {}

    public static func setUser(id _: String, role _: String? = nil, email _: String? = nil) {}

    public static func setUserProvider(_: (() -> BugScreenUser?)?) {}

    public static func clearUser() {}

    public static func presentBugReport(
        from _: UIViewController? = nil,
        screenshot _: UIImage? = nil
    ) {}

    public static func shutdown() {}
}
