import SwiftUI
import UIKit

/// UIKit bridge for presenting the SwiftUI bug report view as a native bottom
/// sheet via `UISheetPresentationController` — same role as Android's
/// `ModalBottomSheet`. UIKit owns the scrim, slide animation, drag-to-dismiss,
/// and grabber; the SwiftUI view renders only the form content.
/// A plain `UIViewController` that *embeds* the SwiftUI form as a child rather than
/// being a `UIHostingController<BugReportView>`.
///
/// The indirection is deliberate: it keeps `BugReportView` an implementation detail of
/// this controller. Both hosts — the SDK and the companion app — present a view
/// controller and hand it a `ReporterHost`; neither needs the SwiftUI type, and a
/// `UIHostingController<BugReportView>` would put it in the signature they bind to.
final class BugReportHostingController: UIViewController,
    UIAdaptivePresentationControllerDelegate
{
    /// Internal rather than private so a test can assert what the controller attached — the
    /// `screenshots:` fan-out below is the companion app's whole share-sheet payload (COMP-004),
    /// and silently dropping all but the first is exactly the regression worth pinning.
    private(set) var viewModel: BugReportViewModel

    /// Embedded in `viewDidLoad`, not `init`: adding it to `view` from the initialiser
    /// would trigger `loadView` at construction and build the whole SwiftUI hierarchy
    /// before anyone has decided to present it. `UIHostingController` did not do that.
    private let content: UIHostingController<BugReportView>

    /// Invoked exactly once when the reporter is finally dismissed — filed, discarded, or swiped
    /// away. The SDK does not care about the outcome and passes `nil`; the companion app uses it to
    /// decide whether a credential rejection seen at submit drops the device to unpaired (RFC-003
    /// §2.5). It carries no result: whether a report was filed or the credential was rejected is the
    /// host's own to track (the companion reads it off its submitter).
    private let onFinished: (() -> Void)?
    private let dismissReport: ((@escaping () -> Void) -> Void)?
    private let presentSuccess: @MainActor (UIWindowScene?, [ReportPartialFailure], ReporterCopy) -> Void
    private var hasFinished = false

    /// - Parameters:
    ///   - host: what the reporter needs from whoever is presenting it — the transport, the
    ///     permission and locator adapters, and whether to brand. The SDK passes one built from its
    ///     API client; the companion app passes its own.
    ///   - screenshots: images to attach up front, in order. The SDK passes at most one — its
    ///     window-snapshot fallback, which auto-attach may later upgrade. The companion app passes
    ///     everything the tester shared, so the array rather than a single image; anything beyond
    ///     `BugReportViewModel.maxScreenshots` is dropped there.
    ///   - onFinished: called once on final dismissal. `nil` for the SDK.
    init(
        host: ReporterHost,
        screenshots: [UIImage] = [],
        autoAttach: Bool = false,
        initialDescription: String = "",
        onFinished: (() -> Void)? = nil,
        dismissReport: ((@escaping () -> Void) -> Void)? = nil,
        presentSuccess: @escaping @MainActor (UIWindowScene?, [ReportPartialFailure], ReporterCopy) -> Void = { scene, partials, copy in
            guard let scene else { return }
            SuccessToastPresenter.show(on: scene, partialFailures: partials, copy: copy)
        }
    ) {
        self.onFinished = onFinished
        self.dismissReport = dismissReport
        self.presentSuccess = presentSuccess
        // Build the VM up front (without callbacks that capture `self`) so the
        // hosting controller owns it and can read `isDirty` from the UIKit
        // dismiss-delegate callbacks. Real callbacks are wired via `bind`
        // below, once `self` is available.
        //
        // The first image goes through `screenshot:` so the SDK's auto-attach placeholder
        // semantics are unchanged; the rest are appended, which is also where the attachment
        // ceiling is applied.
        let vm = BugReportViewModel(
            screenshot: screenshots.first,
            autoAttach: autoAttach,
            onDismiss: {},
            onSuccess: { _ in },
            submitter: host.submitter,
            photosPermission: host.photosPermission,
            screenshotLocator: host.screenshotLocator,
            configurationLoader: host.configurationLoader
        )
        vm.addScreenshots(Array(screenshots.dropFirst()))
        vm.description = initialDescription
        viewModel = vm
        content = UIHostingController(rootView: BugReportView(viewModel: vm))
        super.init(nibName: nil, bundle: nil)

        vm.bind(
            onDismiss: { [weak self] in
                self?.performDismissal { self?.finishOnce() }
            },
            onSuccess: { [weak self] (partials: [ReportPartialFailure]) in
                guard let self else { return }
                let hostScene = view.window?.windowScene
                let reportCopy = viewModel.copy
                performDismissal {
                    self.presentSuccess(hostScene, partials, reportCopy)
                    self.finishOnce()
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

    @available(*, unavailable)
    @MainActor dynamic required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The SwiftUI hierarchy is built here rather than in `init` — embedding from the
    /// initialiser builds the whole view tree before the controller has a view to put it in.
    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(content)
        view.addSubview(content.view)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.view.topAnchor.constraint(equalTo: view.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        content.didMove(toParent: self)
    }

    private func performDismissal(_ completion: @escaping () -> Void) {
        if let dismissReport {
            dismissReport(completion)
            return
        }
        dismiss(animated: true, completion: completion)
    }

    /// Fires the host's completion exactly once, whichever way the reporter was dismissed.
    private func finishOnce() {
        guard !hasFinished else { return }
        viewModel.cleanupVideos()
        hasFinished = true
        onFinished?()
    }

    func dismissFromHost() {
        guard let owner = presentingViewController else {
            finishOnce()
            return
        }
        // The reporter may itself present the picker or annotation UI; dismiss the whole stack.
        owner.dismiss(animated: true) { self.finishOnce() }
    }

    // MARK: - UIAdaptivePresentationControllerDelegate

    func presentationControllerShouldDismiss(_: UIPresentationController) -> Bool {
        viewModel.canDismissWithoutConfirmation
    }

    /// The interactive swipe-to-dismiss path (only reachable when the form is clean, per
    /// `presentationControllerShouldDismiss`). The self-dismiss paths complete via their own
    /// dismissal closures; this covers the one the system drives.
    func presentationControllerDidDismiss(_: UIPresentationController) {
        finishOnce()
    }

    func presentationControllerDidAttemptToDismiss(_: UIPresentationController) {
        guard viewModel.submissionState != .submitting, !viewModel.isPreparingMedia else { return }
        guard viewModel.configurationState == .ready else { return }
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
                self?.dismiss(animated: true) { self?.finishOnce() }
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
        partialFailures: [ReportPartialFailure] = [],
        duration: TimeInterval? = nil,
        copy: ReporterCopy
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

        let host = UIHostingController(rootView: SuccessToastOverlay(copy: copy, partialFailures: partialFailures))
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
    let copy: ReporterCopy
    let partialFailures: [ReportPartialFailure]
    @State private var visible = false

    var body: some View {
        SuccessToast(partialFailures: partialFailures, copy: copy)
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
