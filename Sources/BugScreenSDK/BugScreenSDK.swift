import Foundation
import UIKit

/// Main entry point for the BugScreen SDK.
///
/// BugScreenSDK is a singleton that manages screenshot detection, bug report submission,
/// and logging for your iOS application. Configure it once during app launch and use
/// its methods throughout your app.
///
/// Example usage:
/// ```swift
/// // In your App.swift or AppDelegate
/// BugScreenSDK.configure(
///     apiKey: "fb_your_api_key_here",
///     enableScreenshotDetection: true,
///     debug: false
/// )
///
/// // Anywhere in your app
/// BugScreenSDK.log("User tapped login button", level: .info)
/// BugScreenSDK.presentBugReport()
/// ```
@MainActor
public enum BugScreenSDK {

    /// The version of the BugScreen SDK. Updated by the release process.
    internal static let version: String = "1.0.0"

    // MARK: - Configuration

    /// Returns the current SDK configuration, if configured.
    internal private(set) static var configuration: BugScreenConfiguration?

    /// Returns the internal logger instance (used by other SDK components)
    internal private(set) static var logger: Logger?

    /// Returns the internal API client (used by the bug report UI submit adapter).
    internal private(set) static var apiClient: APIClient?

    /// Returns whether the SDK has been configured.
    ///
    /// You must call `configure()` before using other SDK methods.
    public static var isConfigured: Bool {
        configuration != nil
    }

    // MARK: - Public API

    /// Configures the BugScreen SDK with your API key and options.
    ///
    /// Call this method once during app launch, typically in your `App` initializer
    /// or `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.
    ///
    /// - Parameters:
    ///   - apiKey: Your API key from the BugScreen console (must start with "fb_")
    ///   - enableScreenshotDetection: Whether to auto-detect screenshots (default: true)
    ///   - debug: Whether to enable debug behavior (default: false)
    ///
    /// - Note: If the SDK is already configured, the existing configuration is torn down
    ///   and replaced — matching Android's `start()` semantics. Useful for tests and key rotation.
    ///
    /// Example:
    /// ```swift
    /// BugScreenSDK.configure(
    ///     apiKey: "fb_your_api_key_here",
    ///     enableScreenshotDetection: true,
    ///     debug: false
    /// )
    /// ```
    public static func configure(
        apiKey: String,
        enableScreenshotDetection: Bool = true,
        debug: Bool = false
    ) {
        if configuration != nil {
            SDKLog.internalLog("♻️ BugScreenSDK: Reconfiguring (previous configuration torn down)", type: .info)
            tearDown()
        }

        SDKLog.setEnabled(debug)

        validateAPIKey(apiKey)

        configuration = BugScreenConfiguration(
            apiKey: apiKey,
            enableScreenshotDetection: enableScreenshotDetection,
            debug: debug
        )

        logger = Logger(enableConsoleLogging: debug)

        apiClient = APIClient(apiKey: apiKey)

        if enableScreenshotDetection {
            ScreenshotObserver.shared.startObserving()
        }

        SDKLog.internalLog(
            "✅ BugScreenSDK: Configured successfully (screenshot detection: \(enableScreenshotDetection ? "enabled" : "disabled"))",
            type: .info
        )
    }

    /// Logs a message to the SDK's circular buffer.
    ///
    /// Logged messages are stored in memory and included with bug reports to provide
    /// debugging context. The buffer has a maximum size of 1MB and will automatically
    /// remove old entries when full.
    ///
    /// - Parameters:
    ///   - message: The message to log
    ///   - level: The importance level of the message (default: .info)
    ///
    /// Example:
    /// ```swift
    /// BugScreenSDK.log("User logged in successfully", level: .info)
    /// BugScreenSDK.log("Network request failed: timeout", level: .error)
    /// BugScreenSDK.log("Cache size: 1024 bytes", level: .debug)
    /// ```
    public static func log(_ message: String, level: LogLevel = .info) {
        guard let logger else {
            SDKLog.internalLog("⚠️ BugScreenSDK: Cannot log - SDK not configured", type: .error)
            return
        }

        // Hop off the main actor so chatty callers (SwiftUI bodies, gesture
        // streams) don't pay for the buffer write on the main thread. Logger
        // has internal locking, so ordering across concurrent log() calls is
        // best-effort by timestamp — fine for a debug buffer.
        Task.detached(priority: .utility) {
            logger.log(message, level: level)
        }
    }

    /// Presents the bug report UI.
    ///
    /// Shows a modal screen where users can describe the bug, attach a screenshot,
    /// and view device information. The bug report is submitted to your configured
    /// integrations (GitHub, Jira, etc.).
    ///
    /// - Parameters:
    ///   - from: The view controller to present from (optional, will find top VC if nil)
    ///   - screenshot: Pre-attached screenshot image (optional)
    ///
    /// Fire-and-forget: never throws. If the SDK is not configured or no presenting view
    /// controller can be found, the call is a no-op and the failure is recorded via the
    /// SDK's internal logger.
    ///
    /// Example:
    /// ```swift
    /// BugScreenSDK.presentBugReport()
    /// ```
    public static func presentBugReport(
        from viewController: UIViewController? = nil,
        screenshot: UIImage? = nil
    ) {
        presentBugReport(from: viewController, screenshot: screenshot, autoAttach: false)
    }

    internal static func presentBugReport(
        from viewController: UIViewController?,
        screenshot: UIImage?,
        autoAttach: Bool
    ) {
        guard isConfigured else {
            SDKLog.internalLog("⚠️ BugScreenSDK: Cannot present bug report - SDK not configured", type: .error)
            return
        }

        let presenter = viewController ?? topViewController()

        guard let presenter = presenter else {
            SDKLog.internalLog("⚠️ BugScreenSDK: Cannot present bug report - no view controller available", type: .error)
            return
        }

        let hostingController = BugReportHostingController(
            screenshot: screenshot,
            autoAttach: autoAttach
        )
        presenter.present(hostingController, animated: true)

        SDKLog.internalLog("✅ BugScreenSDK: Presented bug report UI", type: .info)
    }

    /// Shuts down the SDK and releases resources.
    ///
    /// This method is rarely needed in normal operation. It stops screenshot detection,
    /// clears the log buffer, and resets the configuration.
    ///
    /// - Note: You must call `configure()` again before using the SDK after shutdown.
    public static func shutdown() {
        tearDown()
        SDKLog.internalLog("🛑 BugScreenSDK: Shutdown complete", type: .info)
        SDKLog.setEnabled(false)
    }

    private static func tearDown() {
        ScreenshotObserver.shared.stopObserving()
        logger?.clear()
        logger = nil
        apiClient = nil
        configuration = nil
    }

    #if DEBUG
    /// Test-only seam that installs an `APIClient` wired to a caller-supplied
    /// `URLSession` and `baseURL` (typically backed by a `URLProtocol` stub).
    /// Compiled out of release builds.
    ///
    /// Bypasses the once-only guard in `configure()` so individual tests can
    /// rebind the SDK without leaking state. Pair with `shutdown()` in tearDown.
    internal static func configureForTesting(
        apiKey: String,
        baseURL: URL,
        session: URLSession
    ) {
        SDKLog.setEnabled(false)
        configuration = BugScreenConfiguration(
            apiKey: apiKey,
            enableScreenshotDetection: false,
            debug: false
        )
        logger = Logger(enableConsoleLogging: false)
        apiClient = APIClient(apiKey: apiKey, baseURL: baseURL, session: session)
    }
    #endif

    // MARK: - Private Helpers

    /// Validates API key format. In DEBUG builds, an invalid `fb_` prefix
    /// traps via `precondition` to flag the programmer error early (mirrors
    /// Android's `require(apiKey.startsWith("fb_"))`). In release builds, a
    /// warning is logged instead so a misconfigured remote-config rollout
    /// can't crash the host app. Empty keys are allowed for demo/testing
    /// parity with Android's Builder.
    private static func validateAPIKey(_ apiKey: String) {
        if !apiKey.isEmpty, !apiKey.hasPrefix("fb_") {
            #if DEBUG
            preconditionFailure("BugScreenSDK: API key must start with 'fb_'")
            #else
            SDKLog.internalLog("⚠️ BugScreenSDK: API key should start with 'fb_'.", type: .error)
            #endif
        }
        if apiKey.isEmpty {
            SDKLog.internalLog("⚠️ BugScreenSDK: API key is empty. Bug report submissions will fail.", type: .error)
        } else if apiKey.count < 10 {
            SDKLog.internalLog("⚠️ BugScreenSDK: API key is too short (\(apiKey.count) characters). Expected at least 10.", type: .error)
        } else {
            SDKLog.internalLog("✅ BugScreenSDK: API key format looks valid", type: .debug)
        }
    }

    /// Finds the topmost view controller in the view hierarchy.
    private static func topViewController() -> UIViewController? {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }

        var topController = keyWindow?.rootViewController

        while let presentedViewController = topController?.presentedViewController {
            topController = presentedViewController
        }

        return topController
    }
}
