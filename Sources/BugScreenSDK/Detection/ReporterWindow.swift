import UIKit

@MainActor
enum ReporterWindow {
    static func captureWindowSnapshot(_ window: UIWindow, maxDimension: CGFloat? = nil) -> UIImage? {
        WindowSnapshot.capture(window, maxDimension: maxDimension ?? 1920)
    }

    /// Returns the active key window, or nil if no foreground scene has one.
    @MainActor
    static func getKeyWindow() -> UIWindow? {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else {
            return nil
        }
        return scene.windows.first(where: { $0.isKeyWindow })
    }

    /// Recursively finds the top-most presented view controller.
    @MainActor
    static func getTopViewController(from viewController: UIViewController) -> UIViewController {
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
    static func isBugReportAlreadyPresented(from viewController: UIViewController) -> Bool {
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
}
