//
//  ScreenshotObserver.swift
//  BugScreenSDK
//
//  Created by BugScreen on 2025-01-15.
//

import OSLog
import UIKit

/// Observes screenshot events and automatically presents the bug report UI.
///
/// This class subscribes to `UIApplication.userDidTakeScreenshotNotification` and presents
/// the bug report screen when a screenshot is detected, if screenshot detection is enabled
/// in the SDK configuration.
///
/// ## Edge Cases Handled:
/// - App in background: No action taken
/// - No key window: Logs warning and skips presentation
/// - SDK not configured: No action taken
/// - Screenshot detection disabled: No action taken
///
/// ## Thread Safety:
/// All UI operations are dispatched to the main thread.
final class ScreenshotObserver {
    // MARK: - Properties

    /// Shared singleton instance.
    static let shared = ScreenshotObserver()

    /// Whether the observer is currently active.
    private var isObserving = false

    /// Logger for debugging.
    private let logger = OSLog(subsystem: "app.bugscreen.sdk", category: "ScreenshotObserver")

    // MARK: - Initialization

    private init() {
        // Private initializer to enforce singleton pattern
    }

    // MARK: - Public Methods

    /// Starts observing screenshot notifications.
    ///
    /// This method is idempotent - calling it multiple times will only register once.
    func startObserving() {
        guard !isObserving else {
            SDKLog.internalLog("ScreenshotObserver already observing", log: logger, type: .debug)
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenshotNotification),
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil
        )

        isObserving = true
        SDKLog.internalLog("ScreenshotObserver started observing", log: logger, type: .info)
    }

    /// Stops observing screenshot notifications.
    func stopObserving() {
        guard isObserving else {
            SDKLog.internalLog("ScreenshotObserver not currently observing", log: logger, type: .debug)
            return
        }

        NotificationCenter.default.removeObserver(
            self,
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil
        )

        isObserving = false
        SDKLog.internalLog("ScreenshotObserver stopped observing", log: logger, type: .info)
    }

    // MARK: - Private Methods

    /// Handles the screenshot notification.
    @objc private func handleScreenshotNotification(_: Notification) {
        SDKLog.internalLog("Screenshot detected", log: logger, type: .debug)

        // Ensure we're on the main thread for UI checks
        DispatchQueue.main.async { [weak self] in
            self?.presentBugReportIfNeeded()
        }
    }

    /// Presents the bug report UI if all conditions are met.
    @MainActor
    private func presentBugReportIfNeeded() {
        // 1. Check if SDK is configured
        guard BugScreenSDK.isConfigured else {
            SDKLog.internalLog("SDK not configured, skipping screenshot detection", log: logger, type: .debug)
            return
        }

        // 2. Check if screenshot detection is enabled
        guard let config = BugScreenSDK.configuration,
              config.enableScreenshotDetection
        else {
            SDKLog.internalLog("Screenshot detection disabled, skipping", log: logger, type: .debug)
            return
        }

        // 3. Check if app is in foreground
        guard UIApplication.shared.applicationState == .active else {
            SDKLog.internalLog("App not in foreground, skipping screenshot detection", log: logger, type: .debug)
            return
        }

        // 4. Find the key window and top-most view controller
        guard let keyWindow = ReporterWindow.getKeyWindow() else {
            SDKLog.internalLog("No key window available", log: logger)
            return
        }
        guard let rootViewController = keyWindow.rootViewController else {
            SDKLog.internalLog("No root view controller available", log: logger)
            return
        }
        let topViewController = ReporterWindow.getTopViewController(from: rootViewController)

        // 5. Check if a bug report screen is already presented
        if ReporterWindow.isBugReportAlreadyPresented(from: topViewController) {
            SDKLog.internalLog("Bug report UI already presented, skipping", log: logger, type: .debug)
            return
        }

        // 6. Capture a key-window snapshot as the initial attachment. The Photos library may
        //    contain the real OS screenshot, but it's gated behind a permission prompt and may
        //    not be written yet — so we always have this fallback ready before presenting.
        let fallbackImage = WindowSnapshot.capture(keyWindow)
        let snapshotSize = fallbackImage.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil"
        SDKLog.internalLog("Captured window snapshot: \(snapshotSize)", log: logger, type: .info)

        // 7. Present the bug report UI with autoAttach=true so the view model upgrades the
        //    attachment to the OS screenshot from Photos when access is available.
        SDKLog.internalLog("Presenting bug report UI after screenshot detection", log: logger, type: .info)
        BugScreenSDK.presentBugReport(
            from: topViewController,
            screenshot: fallbackImage,
            autoAttach: true
        )
    }
}
