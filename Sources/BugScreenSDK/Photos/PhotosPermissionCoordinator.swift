import UIKit
import Photos
import OSLog

@MainActor
internal enum PhotosPermissionCoordinator {

    private static let logger = OSLog(subsystem: "app.bugscreen.sdk", category: "PhotosPermission")

    /// Result of the permission flow.
    enum Outcome {
        case authorized
        case denied
        case cancelled
    }

    /// Ensures we have read access to the photo library, presenting a rationale alert if needed.
    /// - Parameter presenter: View controller used to host the rationale alert.
    static func ensureAccess(
        presenter: UIViewController,
        completion: @escaping (Outcome) -> Void
    ) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            completion(.authorized)
        case .denied, .restricted:
            SDKLog.internalLog("Photo library access denied/restricted", log: logger, type: .debug)
            completion(.denied)
        case .notDetermined:
            showRationale(on: presenter, completion: completion)
        @unknown default:
            completion(.denied)
        }
    }

    private static func showRationale(
        on presenter: UIViewController,
        completion: @escaping (Outcome) -> Void
    ) {
        let alert = UIAlertController(
            title: "Attach the full screenshot?",
            message: "Allow photo library access so BugScreen can attach the exact screenshot you just took — including the status bar and other system chrome. Without access, only the app's content is captured. On the next screen, please tap \"Allow Access to All Photos\".",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Not now", style: .cancel) { _ in
            completion(.cancelled)
        })
        alert.addAction(UIAlertAction(title: "Continue", style: .default) { _ in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                DispatchQueue.main.async {
                    switch status {
                    case .authorized, .limited:
                        completion(.authorized)
                    default:
                        completion(.denied)
                    }
                }
            }
        })
        presenter.present(alert, animated: true)
    }
}
