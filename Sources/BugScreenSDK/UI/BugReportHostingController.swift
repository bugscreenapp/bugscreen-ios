import UIKit
import SwiftUI

/// UIKit bridge for presenting the SwiftUI bug report view.
///
/// Wraps `BugReportView` in a `UIHostingController` so it can be presented
/// from UIKit-based apps. Automatically dismisses itself when the user completes
/// or cancels the bug report.
@available(iOS 15.0, *)
internal class BugReportHostingController: UIHostingController<BugReportView> {

    // MARK: - Initialization

    /// Creates a new bug report hosting controller.
    ///
    /// - Parameters:
    ///   - screenshot: Optional pre-attached screenshot
    init(
        screenshot: UIImage? = nil,
        autoAttach: Bool = false
    ) {
        // Temporary placeholder view (will be replaced after super.init)
        let placeholderView = BugReportView(
            screenshot: screenshot,
            autoAttach: autoAttach,
            onDismiss: {}
        )

        super.init(rootView: placeholderView)

        // Now replace with real view that has proper dismiss closure
        let view = BugReportView(
            screenshot: screenshot,
            autoAttach: autoAttach,
            onDismiss: { [weak self] in
                self?.dismiss(animated: true)
            }
        )
        self.rootView = view

        // Configure presentation style
        modalPresentationStyle = .formSheet
        modalTransitionStyle = .coverVertical
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        // Prevent dismissal by swipe when submitting
        isModalInPresentation = false
    }
}
