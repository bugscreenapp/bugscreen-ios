//
//  ScreenshotObserver.swift
//  BugScreenSDK
//
//  Created by BugScreen on 2025-01-15.
//

import UIKit
import OSLog

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
@available(iOS 15.0, *)
internal final class ScreenshotObserver {

    // MARK: - Properties

    /// Shared singleton instance.
    static let shared = ScreenshotObserver()

    /// Whether the observer is currently active.
    private var isObserving = false

    /// Logger for debugging.
    private let logger = OSLog(subsystem: "com.bugscreen.sdk", category: "ScreenshotObserver")

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
    @objc private func handleScreenshotNotification(_ notification: Notification) {
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
              config.enableScreenshotDetection else {
            SDKLog.internalLog("Screenshot detection disabled, skipping", log: logger, type: .debug)
            return
        }

        // 3. Check if app is in foreground
        guard UIApplication.shared.applicationState == .active else {
            SDKLog.internalLog("App not in foreground, skipping screenshot detection", log: logger, type: .debug)
            return
        }

        // 4. Find the key window and top-most view controller
        guard let keyWindow = getKeyWindow() else {
            SDKLog.internalLog("No key window available", log: logger)
            return
        }
        guard let rootViewController = keyWindow.rootViewController else {
            SDKLog.internalLog("No root view controller available", log: logger)
            return
        }
        let topViewController = getTopViewController(from: rootViewController)

        // 5. Check if a bug report screen is already presented
        if isBugReportAlreadyPresented(from: topViewController) {
            SDKLog.internalLog("Bug report UI already presented, skipping", log: logger, type: .debug)
            return
        }

        // 6. Capture a key-window snapshot as the initial attachment. The Photos library may
        //    contain the real OS screenshot, but it's gated behind a permission prompt and may
        //    not be written yet — so we always have this fallback ready before presenting.
        let fallbackImage = captureWindowSnapshot(keyWindow)
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

    /// Renders the key window into a UIImage. Used as the immediate fallback attachment when
    /// the Photos-library OS screenshot isn't accessible.
    ///
    /// SwiftUI-hosted windows often render blank when captured via `drawHierarchy(afterScreenUpdates: false)`
    /// because SwiftUI defers commits to the layer tree. `CALayer.render(in:)` reads the current
    /// presentation tree synchronously and is reliable across UIKit and SwiftUI windows.
    @MainActor
    private func captureWindowSnapshot(_ window: UIWindow) -> UIImage? {
        guard window.bounds.width > 0, window.bounds.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { ctx in
            window.layer.render(in: ctx.cgContext)
        }
    }

    /// Returns the active key window, or nil if no foreground scene has one.
    @MainActor
    private func getKeyWindow() -> UIWindow? {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            return nil
        }
        return scene.windows.first(where: { $0.isKeyWindow })
    }

    /// Recursively finds the top-most presented view controller.
    @MainActor
    private func getTopViewController(from viewController: UIViewController) -> UIViewController {
        if let presented = viewController.presentedViewController {
            return getTopViewController(from: presented)
        }

        if let navigationController = viewController as? UINavigationController {
            if let topViewController = navigationController.topViewController {
                return getTopViewController(from: topViewController)
            }
        }

        if let tabBarController = viewController as? UITabBarController {
            if let selectedViewController = tabBarController.selectedViewController {
                return getTopViewController(from: selectedViewController)
            }
        }

        return viewController
    }

    /// Checks if a bug report UI is already presented.
    @MainActor
    private func isBugReportAlreadyPresented(from viewController: UIViewController) -> Bool {
        // Check if the current view controller is the bug report hosting controller
        if viewController is BugReportHostingController {
            return true
        }

        // Check if any presented view controller is the bug report
        if let presented = viewController.presentedViewController {
            return isBugReportAlreadyPresented(from: presented)
        }

        return false
    }

    // MARK: - Deinitialization

    deinit {
        stopObserving()
    }
}
