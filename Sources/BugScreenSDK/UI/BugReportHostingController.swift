import UIKit
import SwiftUI

/// UIKit bridge for presenting the SwiftUI bug report view as a native bottom
/// sheet via `UISheetPresentationController` — same role as Android's
/// `ModalBottomSheet`. UIKit owns the scrim, slide animation, drag-to-dismiss,
/// and grabber; the SwiftUI view renders only the form content.
internal class BugReportHostingController: UIHostingController<BugReportView>,
                                            UIAdaptivePresentationControllerDelegate {

    private let viewModel: BugReportViewModel

    init(
        screenshot: UIImage? = nil,
        autoAttach: Bool = false
    ) {
        // Build the VM up front (without callbacks that capture `self`) so the
        // hosting controller owns it and can read `isDirty` from the UIKit
        // dismiss-delegate callbacks. Real callbacks are wired via `bind`
        // below, once `self` is available.
        let vm = BugReportViewModel(
            screenshot: screenshot,
            autoAttach: autoAttach,
            onDismiss: {},
            onSuccess: { _ in }
        )
        self.viewModel = vm
        super.init(rootView: BugReportView(viewModel: vm))

        vm.bind(
            onDismiss: { [weak self] in
                self?.dismiss(animated: true)
            },
            onSuccess: { [weak self] partials in
                guard let self = self else { return }
                let hostScene = self.view.window?.windowScene
                self.dismiss(animated: true) {
                    if let scene = hostScene {
                        SuccessToastPresenter.show(on: scene, partialFailures: partials)
                    }
                }
            }
        )

        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 26
            sheet.prefersEdgeAttachedInCompactHeight = true
            sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
        }
        presentationController?.delegate = self
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UIAdaptivePresentationControllerDelegate

    func presentationControllerShouldDismiss(_ pc: UIPresentationController) -> Bool {
        if viewModel.submissionState == .submitting { return false }
        return !viewModel.isDirty
    }

    func presentationControllerDidAttemptToDismiss(_ pc: UIPresentationController) {
        guard viewModel.submissionState != .submitting else { return }
        presentDiscardConfirmation()
    }

    private func presentDiscardConfirmation() {
        let alert = UIAlertController(
            title: SDKStrings.discardDialogTitle,
            message: SDKStrings.discardDialogMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: SDKStrings.discardDialogConfirm,
            style: .destructive,
            handler: { [weak self] _ in
                self?.dismiss(animated: true)
            }
        ))
        alert.addAction(UIAlertAction(
            title: SDKStrings.discardDialogKeep,
            style: .cancel,
            handler: nil
        ))
        present(alert, animated: true)
    }
}

// MARK: - Success toast over the host app

/// Shows the post-submit success toast in a transient UIWindow above the host
/// app, then tears it down. Matches Android's behavior of dismissing the sheet
/// first and floating the toast over the host (see `BugReportActivity.kt`).
///
/// The toast window is fully click-through outside the toast's own frame: it
/// uses a `PassthroughContainerView` whose `point(inside:)` only claims hits
/// that one of its subviews already claims. The hosting controller for the
/// SwiftUI toast is pinned to the top of the safe area and sized to fit the
/// toast's intrinsic content, so empty space below it falls through to the
/// host app's window underneath.
@MainActor
private enum SuccessToastPresenter {
    private static var activeWindow: UIWindow?

    private static let successToastSeconds: TimeInterval = 2.3
    private static let partialFailureToastSeconds: TimeInterval = 10.0

    static func show(
        on scene: UIWindowScene,
        partialFailures: [BugReportPartialFailure] = [],
        duration: TimeInterval? = nil
    ) {
        // Partial failures need time to read and expand the disclosure;
        // the clean success path stays at the short toast duration.
        let resolvedDuration =
            duration
            ?? (partialFailures.isEmpty ? successToastSeconds : partialFailureToastSeconds)
        // If a previous toast is still on screen, replace it.
        activeWindow?.isHidden = true
        activeWindow = nil

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear

        let rootVC = UIViewController()
        let container = PassthroughContainerView()
        container.backgroundColor = .clear
        rootVC.view = container

        let host = UIHostingController(rootView: SuccessToastOverlay(partialFailures: partialFailures))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        rootVC.addChild(host)
        container.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        host.didMove(toParent: rootVC)

        window.rootViewController = rootVC
        window.isHidden = false
        activeWindow = window

        DispatchQueue.main.asyncAfter(deadline: .now() + resolvedDuration) {
            UIView.animate(withDuration: 0.25, animations: {
                window.alpha = 0
            }, completion: { _ in
                window.isHidden = true
                if activeWindow === window {
                    activeWindow = nil
                }
            })
        }
    }
}

/// Container view that claims a touch only when one of its subviews already
/// claims it. Empty regions return `false` from `point(inside:)`, which makes
/// UIKit's hit-test return `nil` for the window and the touch falls through
/// to whatever window sits below.
private final class PassthroughContainerView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        for subview in subviews {
            let translated = convert(point, to: subview)
            if subview.point(inside: translated, with: event) {
                return true
            }
        }
        return false
    }
}

/// SwiftUI wrapper that renders the toast at its intrinsic size with a brief
/// spring-in. Sized by the parent hosting controller's auto-layout
/// constraints, so the UIView host follows the toast's content height.
private struct SuccessToastOverlay: View {
    let partialFailures: [BugReportPartialFailure]
    @State private var visible = false

    var body: some View {
        SuccessToast(partialFailures: partialFailures)
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : -16)
            .onAppear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    visible = true
                }
            }
    }
}
