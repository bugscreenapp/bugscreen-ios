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
    /// The version of the BugScreen SDK. Updated by the release process. `nonisolated` so the
    /// non-isolated `APIClient` can read it for the `X-BugScreen-SDK` header (OPS-011).
    nonisolated static let version: String = "1.7.0"

    // MARK: - Configuration

    /// Returns the current SDK configuration, if configured.
    private(set) static var configuration: BugScreenConfiguration?

    /// Returns the internal logger instance (used by other SDK components)
    private(set) static var logger: Logger?

    /// Returns the internal API client (used by the bug report UI submit adapter).
    private(set) static var apiClient: APIClient?

    private static var runtimeConfigTask: Task<Result<ResolvedSdkConfig, Error>, Never>?
    private static var runtimeConfigLoader: (APIClient) async throws -> ResolvedSdkConfig = {
        try await $0.fetchRuntimeConfig()
    }

    /// Custom key/value pairs attached to every subsequent bug report.
    /// Defaults to empty; mutated only via ``setCustomData(_:)`` / ``clearCustomData()``.
    private(set) static var customData: [String: String] = [:]

    /// The report account. A capture-time provider (evaluated when the report
    /// screen opens) takes precedence over an eagerly-set static user, so a tester
    /// switching logins never attaches a stale account. Kept separate from
    /// `customData` so `clearCustomData()` doesn't wipe the user and vice versa.
    private(set) static var user: BugScreenUser?
    private(set) static var userProvider: (() -> BugScreenUser?)?

    /// The last successfully loaded branding value. A reporter presentation waits for its
    /// authoritative config attempt and never uses this value as a request-failure fallback.
    private(set) static var showBranding: Bool = false

    /// The last successfully loaded type choices. A successful legacy response that omits the
    /// field preserves the defaults; a failed request does not open a default-configured form.
    private(set) static var reportTypes: [String] = defaultReportTypes

    /// Whether the reporter should show and submit the fixed Severity choices.
    /// Missing legacy configuration resolves to enabled.
    private(set) static var severityEnabled = true

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
        configure(
            apiKey: apiKey,
            enableScreenshotDetection: enableScreenshotDetection,
            debug: debug,
            wrapperSdk: nil
        )
    }

    /// SPI entry point for BugScreen's own cross-platform wrappers (React Native). `wrapperSdk` is a
    /// `<wrapper>/<semver>` tag (e.g. `rn/0.5.0`) emitted on the informational
    /// `X-BugScreen-SDK-Wrapper` request header (OPS-011). Not part of the public API — app
    /// developers integrating the native iOS SDK directly use the overload above; version-gating
    /// keys off the native `X-BugScreen-SDK` transport header, not this value.
    @_spi(Wrapper)
    public static func configure(
        apiKey: String,
        enableScreenshotDetection: Bool = true,
        debug: Bool = false,
        wrapperSdk: String?
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

        apiClient = APIClient(apiKey: apiKey, wrapperSdk: wrapperSdk)

        if let client = apiClient { loadRuntimeConfig(for: client) }

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

    /// Attaches a global map of custom key/value pairs to every subsequent bug report.
    ///
    /// Replaces (not merges) any previously set custom data — pass the full map you want
    /// included. Swift dictionaries are value types, so the stored copy is independent of
    /// the caller's value.
    ///
    /// Must be called from the main actor (same as other SDK entry points). Reads happen
    /// when the bug report screen is opened.
    ///
    /// Example:
    /// ```swift
    /// BugScreenSDK.setCustomData([
    ///     "env": "staging",
    ///     "buildType": "debug",
    /// ])
    /// ```
    public static func setCustomData(_ data: [String: String]) {
        customData = data
    }

    /// Sets a single custom data key/value pair on the global map sent with every
    /// subsequent bug report. Overwrites the existing value for `key` if any; other
    /// keys are preserved.
    ///
    /// Must be called from the main actor.
    ///
    /// Example:
    /// ```swift
    /// BugScreenSDK.setCustomData(key: "userId", value: "abc-123")
    /// ```
    public static func setCustomData(key: String, value: String) {
        customData[key] = value
    }

    /// Removes a single custom data key from the global map. No-op if `key` is not
    /// present. Other keys are preserved.
    ///
    /// Must be called from the main actor.
    public static func removeCustomData(key: String) {
        customData.removeValue(forKey: key)
    }

    /// Merges `data` into the existing custom data map. Keys in `data` overwrite
    /// existing values; keys not in `data` are preserved.
    ///
    /// Must be called from the main actor.
    ///
    /// Example:
    /// ```swift
    /// BugScreenSDK.addCustomData(["plan": "pro", "region": "eu"])
    /// ```
    public static func addCustomData(_ data: [String: String]) {
        customData.merge(data) { _, new in new }
    }

    /// Clears any custom data previously set via ``setCustomData(_:)``.
    public static func clearCustomData() {
        customData = [:]
    }

    /// Identifies the account the report is filed under. The reporter's login is
    /// the first thing a triager needs to reproduce a bug, so the backend renders
    /// it as a dedicated Account section at the top of the created issue and
    /// promotes `role` to a filterable label.
    ///
    /// This sets a static value. If the current account can change during a session
    /// (e.g. QA switching logins), prefer ``setUserProvider(_:)`` so it is read
    /// fresh at capture time. Setting a user here clears any provider previously
    /// registered.
    ///
    /// Privacy: pass `email` only when your team wants a contactable address in the
    /// tracker — it is off by default. Nothing is auto-collected.
    ///
    /// Must be called from the main actor.
    ///
    /// Example:
    /// ```swift
    /// BugScreenSDK.setUser(id: "pro-user-8823", role: "admin")
    /// ```
    public static func setUser(id: String, role: String? = nil, email: String? = nil) {
        user = BugScreenUser(id: id, role: role, email: email)
        userProvider = nil
    }

    /// Supplies the account lazily. The `provider` is invoked at capture time (when
    /// the report screen opens), not when you register it — so the attached account
    /// always reflects the current session and never a stale value from a previous
    /// login. This is the primitive ``setUser(id:role:email:)`` is sugar over;
    /// registering a provider clears any static user previously set.
    ///
    /// Keep `provider` fast and non-blocking — it runs on the main actor as the
    /// report screen opens. Return already-known values; do not perform I/O. Return
    /// `nil` to attach no account for this report.
    ///
    /// Must be called from the main actor.
    ///
    /// Example:
    /// ```swift
    /// BugScreenSDK.setUserProvider {
    ///     session.currentUser.map { BugScreenUser(id: $0.id, role: $0.role) }
    /// }
    /// ```
    public static func setUserProvider(_ provider: (() -> BugScreenUser?)?) {
        userProvider = provider
        user = nil
    }

    /// Clears any account set via ``setUser(id:role:email:)`` or
    /// ``setUserProvider(_:)``. Subsequent reports carry no account until one is
    /// set again.
    public static func clearUser() {
        user = nil
        userProvider = nil
    }

    /// Merges the static `customData` with the resolved account (provider first,
    /// else the static user) as reserved keys. Called once per report when the
    /// report screen opens.
    static func resolveReportCustomData() -> [String: String] {
        let resolved = userProvider?() ?? user
        guard let accountKeys = resolved?.toReservedKeys(), !accountKeys.isEmpty else {
            return customData
        }
        return customData.merging(accountKeys) { _, new in new }
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

    static func presentBugReport(
        from viewController: UIViewController?,
        screenshot: UIImage?,
        autoAttach: Bool
    ) {
        guard isConfigured else {
            SDKLog.internalLog("⚠️ BugScreenSDK: Cannot present bug report - SDK not configured", type: .error)
            return
        }

        let presenter = viewController ?? topViewController()

        guard let presenter else {
            SDKLog.internalLog("⚠️ BugScreenSDK: Cannot present bug report - no view controller available", type: .error)
            return
        }

        // Everything the reporter needs from the SDK, in one value. The companion app
        // builds its own equivalent — same reporter, different host (RFC-003 §2).
        let hostingController = BugReportHostingController(
            host: ReporterHost(
                submitter: DefaultBugReportSubmitter(),
                showBranding: false,
                configurationLoader: { forceRefresh in
                    await loadReporterConfiguration(forceRefresh: forceRefresh)
                }
            ),
            screenshots: screenshot.map { [$0] } ?? [],
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
        runtimeConfigTask?.cancel()
        runtimeConfigTask = nil
        ScreenshotObserver.shared.stopObserving()
        logger?.clear()
        logger = nil
        apiClient = nil
        configuration = nil
        customData = [:]
        user = nil
        userProvider = nil
        showBranding = false
        reportTypes = defaultReportTypes
        severityEnabled = true
    }

    #if DEBUG
        /// Test-only seam that installs an `APIClient` wired to a caller-supplied
        /// `URLSession` and `baseURL` (typically backed by a `URLProtocol` stub).
        /// Compiled out of release builds.
        ///
        /// Bypasses the once-only guard in `configure()` so individual tests can
        /// rebind the SDK without leaking state. Pair with `shutdown()` in tearDown.
        static func configureForTesting(
            apiKey: String,
            baseURL: URL,
            session: URLSession,
            runtimeConfigLoader: ((APIClient) async -> ResolvedSdkConfig)? = nil
        ) {
            runtimeConfigTask?.cancel()
            runtimeConfigTask = nil
            SDKLog.setEnabled(false)
            configuration = BugScreenConfiguration(
                apiKey: apiKey,
                enableScreenshotDetection: false,
                debug: false
            )
            logger = Logger(enableConsoleLogging: false)
            let client = APIClient(apiKey: apiKey, baseURL: baseURL, session: session)
            apiClient = client
            showBranding = false
            reportTypes = defaultReportTypes
            severityEnabled = true
            if let runtimeConfigLoader {
                loadRuntimeConfig(for: client, using: runtimeConfigLoader)
            }
        }
    #endif

    // MARK: - Private Helpers

    private static func loadRuntimeConfig(
        for client: APIClient,
        using loader: @escaping (APIClient) async throws -> ResolvedSdkConfig = {
            try await $0.fetchRuntimeConfig()
        }
    ) {
        runtimeConfigTask?.cancel()
        runtimeConfigLoader = loader
        runtimeConfigTask = Task {
            do {
                let runtimeConfig = try await loader(client)
                guard !Task.isCancelled, apiClient === client else {
                    return .failure(CancellationError())
                }
                showBranding = runtimeConfig.showBranding
                reportTypes = runtimeConfig.reportTypes
                severityEnabled = runtimeConfig.severityEnabled
                return .success(runtimeConfig)
            } catch {
                guard !Task.isCancelled else { return .failure(CancellationError()) }
                SDKLog.internalLog("⚠️ BugScreenSDK: Config fetch failed: \(error)", type: .error)
                return .failure(error)
            }
        }
    }

    private static func loadReporterConfiguration(forceRefresh: Bool) async -> ReporterConfigurationResult {
        guard let client = apiClient else { return .unavailable }
        if forceRefresh || runtimeConfigTask == nil {
            loadRuntimeConfig(for: client, using: runtimeConfigLoader)
        }
        guard let attempt = runtimeConfigTask else { return .unavailable }
        let result = await attempt.value
        guard apiClient === client else { return .unavailable }
        switch result {
        case let .success(config):
            return .ready(ReporterConfiguration(
                showBranding: config.showBranding,
                reportTypes: config.reportTypes,
                severityEnabled: config.severityEnabled
            ))
        case .failure:
            return .unavailable
        }
    }

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
            .flatMap(\.windows)
            .first { $0.isKeyWindow }

        var topController = keyWindow?.rootViewController

        while let presentedViewController = topController?.presentedViewController {
            topController = presentedViewController
        }

        return topController
    }
}
