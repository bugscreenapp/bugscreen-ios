import Foundation

/// Internal snapshot of the active SDK configuration, captured by `BugScreenSDK.configure()`.
///
/// Stored as a value owned by the main-actor SDK. Not exposed publicly —
/// consumers configure the SDK via the parameters on `BugScreenSDK.configure(...)`.
struct BugScreenConfiguration {
    let apiKey: String
    let enableScreenshotDetection: Bool
    var enableShakeDetection: Bool = false
    let debug: Bool
    let captureSystemLogs: Bool
    let systemLogLifetime: SystemLogLifetime
    var screenRecordingOptions: ScreenRecordingOptions = .init()
    var showReportNotification: Bool = false
    var requestNotificationPermission: Bool = true
}
