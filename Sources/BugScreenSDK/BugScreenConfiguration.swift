import Foundation

/// Configuration settings for the BugScreen SDK.
///
/// This struct is created by calling `BugScreenSDK.configure()` and cannot be modified after initialization.
/// All settings are immutable to ensure thread-safety and predictable behavior.
public struct BugScreenConfiguration {
    /// API key for authenticating with the BugScreen backend.
    ///
    /// The API key should start with "fb_" and be at least 10 characters long.
    /// You can obtain an API key from the BugScreen console after creating an app.
    public let apiKey: String

    /// Whether to automatically detect screenshots and prompt for bug reports.
    ///
    /// When enabled, the SDK will observe `UIApplication.userDidTakeScreenshotNotification`
    /// and automatically present the bug report UI when a screenshot is detected.
    ///
    /// Default: `true`
    public let enableScreenshotDetection: Bool

    /// Whether to output log messages to the Xcode console for debugging.
    ///
    /// When enabled, log messages sent via `BugScreenSDK.log()` will also be printed
    /// to the Xcode console using OSLog. This is useful during development but should
    /// typically be disabled in production builds.
    ///
    /// Default: `false`
    public let enableLogging: Bool

    /// Creates a new SDK configuration.
    ///
    /// - Parameters:
    ///   - apiKey: The API key from your BugScreen console
    ///   - enableScreenshotDetection: Whether to auto-detect screenshots (default: true)
    ///   - enableLogging: Whether to output logs to Xcode console (default: false)
    init(
        apiKey: String,
        enableScreenshotDetection: Bool = true,
        enableLogging: Bool = false
    ) {
        self.apiKey = apiKey
        self.enableScreenshotDetection = enableScreenshotDetection
        self.enableLogging = enableLogging
    }
}
