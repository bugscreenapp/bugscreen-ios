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
///     enableLogging: false
/// )
///
/// // Anywhere in your app
/// BugScreenSDK.log("User tapped login button", level: .info)
/// BugScreenSDK.presentBugReport()
/// ```
public class BugScreenSDK {

    /// The version of the BugScreen SDK. Updated by the release process.
    public static let version: String = "0.1.0"

    // MARK: - Singleton

    private init() {}

    // MARK: - Thread Safety

    private static let queue = DispatchQueue(
        label: "com.bugscreen.sdk",
        attributes: .concurrent
    )

    // MARK: - Configuration

    private static var _configuration: BugScreenConfiguration?
    private static var _logger: Logger?
    private static var _apiClient: APIClient?

    /// Returns the current SDK configuration, if configured.
    internal static var configuration: BugScreenConfiguration? {
        queue.sync { _configuration }
    }

    /// Returns whether the SDK has been configured.
    ///
    /// You must call `configure()` before using other SDK methods.
    public static var isConfigured: Bool {
        queue.sync { _configuration != nil }
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
    ///   - enableLogging: Whether to output logs to Xcode console (default: false)
    ///
    /// - Note: If the SDK is already configured, the existing configuration is torn down
    ///   and replaced — matching Android's `start()` semantics. Useful for tests and key rotation.
    ///
    /// Example:
    /// ```swift
    /// BugScreenSDK.configure(
    ///     apiKey: "fb_your_api_key_here",
    ///     enableScreenshotDetection: true,
    ///     enableLogging: false
    /// )
    /// ```
    public static func configure(
        apiKey: String,
        enableScreenshotDetection: Bool = true,
        enableLogging: Bool = false
    ) {
        queue.async(flags: .barrier) {
            // Tear down any existing configuration so a second configure() acts as
            // a reinit (matches Android's start() semantics).
            if _configuration != nil {
                SDKLog.internalLog("♻️ BugScreenSDK: Reconfiguring (previous configuration torn down)", type: .info)
                tearDownLocked()
            }

            SDKLog.setEnabled(enableLogging)

            // Validate API key format (warnings only, not enforced)
            validateAPIKey(apiKey)

            // Store configuration
            _configuration = BugScreenConfiguration(
                apiKey: apiKey,
                enableScreenshotDetection: enableScreenshotDetection,
                enableLogging: enableLogging
            )

            // Initialize logger
            _logger = Logger(enableConsoleLogging: enableLogging)

            // Initialize API client
            _apiClient = APIClient(apiKey: apiKey)

            // Initialize screenshot observer (Phase 4)
            if enableScreenshotDetection {
                if #available(iOS 15.0, *) {
                    ScreenshotObserver.shared.startObserving()
                } else {
                    SDKLog.internalLog("⚠️ BugScreenSDK: Screenshot detection requires iOS 15+")
                }
            }

            SDKLog.internalLog(
                "✅ BugScreenSDK: Configured successfully (screenshot detection: \(enableScreenshotDetection ? "enabled" : "disabled"))",
                type: .info
            )
        }
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
        guard isConfigured else {
            SDKLog.internalLog("⚠️ BugScreenSDK: Cannot log - SDK not configured", type: .error)
            return
        }

        queue.async {
            _logger?.log(message, level: level)
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
    /// - Note: This method must be called from the main thread.
    ///
    /// Example:
    /// ```swift
    /// BugScreenSDK.presentBugReport()
    /// ```
    @MainActor
    public static func presentBugReport(
        from viewController: UIViewController? = nil,
        screenshot: UIImage? = nil,
        autoAttach: Bool = false
    ) {
        guard isConfigured else {
            SDKLog.internalLog("⚠️ BugScreenSDK: Cannot present bug report - SDK not configured", type: .error)
            return
        }

        // Find presenting view controller
        let presenter = viewController ?? topViewController()

        guard let presenter = presenter else {
            SDKLog.internalLog("⚠️ BugScreenSDK: Cannot present bug report - no view controller available", type: .error)
            return
        }

        // Create and present bug report UI
        if #available(iOS 15.0, *) {
            let hostingController = BugReportHostingController(
                screenshot: screenshot,
                autoAttach: autoAttach
            )
            presenter.present(hostingController, animated: true)

            SDKLog.internalLog("✅ BugScreenSDK: Presented bug report UI", type: .info)
        } else {
            SDKLog.internalLog("⚠️ BugScreenSDK: Bug report UI requires iOS 15+", type: .error)
        }
    }

    /// Shuts down the SDK and releases resources.
    ///
    /// This method is rarely needed in normal operation. It stops screenshot detection,
    /// clears the log buffer, and resets the configuration.
    ///
    /// - Note: You must call `configure()` again before using the SDK after shutdown.
    public static func shutdown() {
        queue.async(flags: .barrier) {
            tearDownLocked()
            SDKLog.internalLog("🛑 BugScreenSDK: Shutdown complete", type: .info)
            SDKLog.setEnabled(false)
        }
    }

    /// Stops the observer and clears all SDK state. Must be called from inside
    /// the barrier block on `queue` — does not lock itself.
    private static func tearDownLocked() {
        ScreenshotObserver.shared.stopObserving()
        _logger?.clear()
        _logger = nil
        _apiClient = nil
        _configuration = nil
    }

    // MARK: - Internal API (for future phases)

    /// Returns the internal logger instance (used by other SDK components)
    internal static var logger: Logger? {
        queue.sync { _logger }
    }

    /// Returns the internal API client (used by the bug report UI submit adapter).
    internal static var apiClient: APIClient? {
        queue.sync { _apiClient }
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
        queue.sync(flags: .barrier) {
            SDKLog.setEnabled(false)
            _configuration = BugScreenConfiguration(
                apiKey: apiKey,
                enableScreenshotDetection: false,
                enableLogging: false
            )
            _logger = Logger(enableConsoleLogging: false)
            _apiClient = APIClient(apiKey: apiKey, baseURL: baseURL, session: session)
        }
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
    @MainActor
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
