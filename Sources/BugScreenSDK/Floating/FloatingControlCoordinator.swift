import UIKit

@MainActor
final class FloatingReport {
    let present: (UIViewController, UIImage?, AutomaticVideoSource?, String?, @escaping () -> Void) -> Void
    let discard: () -> Void
    init(present: @escaping (UIViewController, UIImage?, AutomaticVideoSource?, String?, @escaping () -> Void) -> Void,
         discard: @escaping () -> Void)
    {
        self.present = present
        self.discard = discard
    }
}

@MainActor
final class FloatingControlCoordinator: NSObject {
    private let windowProvider: () -> UIWindow?
    private let isActive: (UIWindow) -> Bool
    private let motion = FloatingMotion()
    private let prepareReport: (Bool) -> FloatingReport
    private let maximumDuration: () async -> Double?
    private let recording: () -> ScreenRecordingController
    private var desired: Bool
    private var temporaryVisible = false
    private var notificationFinished: (() -> Void)?
    private var visible: Bool {
        desired || temporaryVisible
    }

    private var suppressed = false
    private var destroyed = false
    private var generation = 0
    private var capturing = false
    private var pending = false
    private var report: FloatingReport?
    private var screenshot: UIImage?
    private var video: AutomaticVideoSource?
    private var notice: String?
    private var task: Task<Void, Never>?
    private var presentationRetry: Task<Void, Never>?
    private var controller: ScreenRecordingController?
    private var overlay: FloatingWindow?
    private var control: FloatingControlView?
    private let hostTouches = FloatingHostTouches(target: nil, action: nil)
    private weak var origin: UIWindow?
    var busy: Bool {
        capturing || pending || report != nil
    }

    init(initiallyVisible: Bool, prepareReport: @escaping (Bool) -> FloatingReport,
         maximumDuration: @escaping () async -> Double?, recording: @escaping () -> ScreenRecordingController,
         windowProvider: (() -> UIWindow?)? = nil,
         isActive: @escaping (UIWindow) -> Bool = { $0.windowScene?.activationState == .foregroundActive })
    {
        self.windowProvider = windowProvider ?? { Self.activeHostWindow() }
        self.isActive = isActive
        desired = initiallyVisible
        self.prepareReport = prepareReport
        self.maximumDuration = maximumDuration
        self.recording = recording
        super.init()
        let center = NotificationCenter.default
        for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification, UIWindow.didBecomeKeyNotification] {
            center.addObserver(self, selector: #selector(active), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(background(_:)), name: UIScene.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(disconnected(_:)), name: UIScene.didDisconnectNotification, object: nil)
        refresh()
    }

    private static func activeHostWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
            .first { $0.isKeyWindow && !($0 is FloatingWindow) }
    }

    func show() {
        desired = true; refresh()
    }

    func hide() {
        desired = false
        temporaryVisible = false
        if controller?.explicitActive == true { controller?.finishExplicit() } else if capturing {
            generation += 1
            task?.cancel(); task = nil
            capturing = false
            clearEvidence()
        }
        refresh()
    }

    func reporterVisible(_ visible: Bool) {
        suppressed = visible; refresh()
    }

    func startRecordingFromNotification(in window: UIWindow, finished: @escaping () -> Void) -> Bool {
        guard !destroyed, !busy, !suppressed, hostWindow() === window, isActive(window) else { return false }
        temporaryVisible = true
        notificationFinished = finished
        refresh()
        startRecording()
        return true
    }

    private func finishNotificationRecording() {
        temporaryVisible = false
        let finished = notificationFinished
        notificationFinished = nil
        finished?()
    }

    private func hostWindow() -> UIWindow? {
        if busy {
            guard let origin, isActive(origin) else { return nil }
            return origin
        }
        return windowProvider()
    }

    private func refresh() {
        guard !destroyed else { return }
        guard !suppressed, !pending, let host = hostWindow(), let scene = host.windowScene else { detach(); return }
        if !visible {
            hostTouches.view?.removeGestureRecognizer(hostTouches)
            if let control, overlay?.isHidden == false, overlay?.windowScene === scene {
                control.exit { [weak self, weak control] in
                    guard let self, self.control === control, !visible else { return }
                    detach()
                }
            } else {
                detach()
            }
            return
        }
        let previous = control
        if overlay?.windowScene !== scene { detach() }
        if overlay == nil {
            let view = FloatingControlView(motion: motion)
            view.report = { [weak self] in self?.makeReport() }
            view.record = { [weak self] in self?.startRecording() }
            view.stop = { [weak self] in self?.controller?.finishExplicit() }
            view.hide = { [weak self] in self?.hide() }
            let root = FloatingViewController()
            root.host = host.rootViewController
            root.view = view
            let window = FloatingWindow(windowScene: scene)
            window.rootViewController = root
            window.backgroundColor = .clear
            window.windowLevel = .normal + 1
            window.isHidden = false
            overlay = window
            control = view
        }
        if hostTouches.view !== host {
            hostTouches.view?.removeGestureRecognizer(hostTouches)
            hostTouches.cancelsTouchesInView = false
            hostTouches.delaysTouchesBegan = false
            hostTouches.delaysTouchesEnded = false
            host.addGestureRecognizer(hostTouches)
        }
        hostTouches.onTouch = { [weak control] in control?.hostInteraction() }
        control?.update(preparing: capturing && controller?.explicitStartedAt == nil, startedAt: controller?.explicitStartedAt)
        if previous !== control || control?.isExiting == true { control?.enter() }
    }

    func makeReport() {
        guard visible, !busy, !suppressed, let host = hostWindow() else { return }
        origin = host
        capturing = true
        report = prepareReport(false)
        generation += 1
        let attempt = generation
        overlay?.isHidden = true
        hostTouches.view?.removeGestureRecognizer(hostTouches)
        task = Task { [weak self, weak host] in
            await Task.yield()
            guard let self, let host, !destroyed, attempt == generation, !Task.isCancelled else { return }
            screenshot = WindowSnapshot.capture(host)
            if screenshot == nil { notice = SDKStrings.floatingScreenshotFailed }
            capturing = false
            pending = true
            presentPending()
        }
    }

    func startRecording() {
        guard visible, !busy, !suppressed, let host = hostWindow() else { return }
        origin = host
        capturing = true
        report = prepareReport(true)
        generation += 1
        let attempt = generation
        refresh()
        task = Task { [weak self] in
            guard let self else { return }
            let maximum = await maximumDuration()
            guard !destroyed, attempt == generation, !Task.isCancelled else { return }
            guard let origin, isActive(origin) else { cancelPreparation(); return }
            guard let maximum, maximum.isFinite, maximum > 0 else {
                fail(SDKStrings.floatingPolicyFailed); return
            }
            let engine = recording()
            controller = engine
            engine.onStateChanged = { [weak self] in self?.refresh() }
            let accepted = engine.beginExplicit(maximumSeconds: maximum) { [weak self] source, reason in
                guard let self, !destroyed, attempt == generation else { source?.cancel(); return }
                capturing = false
                guard let source else {
                    fail(SDKStrings.floatingRecordingFailed); return
                }
                video = source
                if engine.explicitReachedLimit {
                    notice = SDKStrings.floatingLimitReached
                } else if reason != nil {
                    notice = SDKStrings.floatingInterrupted
                }
                pending = true
                presentPending()
            }
            if !accepted { fail(SDKStrings.floatingBusy) }
            refresh()
        }
    }

    private func cancelPreparation() {
        generation += 1
        task?.cancel(); task = nil
        capturing = false
        clearEvidence()
        refresh()
    }

    private func fail(_ message: String) {
        let noticeView = temporaryVisible ? origin?.rootViewController?.view : control
        capturing = false
        clearEvidence()
        refresh()
        if let view = noticeView ?? control { FloatingNotice.show(message, in: view) }
    }

    private func presentPending() {
        refresh()
        guard pending, !suppressed, let host = hostWindow(), let root = host.rootViewController, let report else { return }
        let presenter = Self.top(root)
        guard presenter.viewIfLoaded?.window != nil, !presenter.isBeingDismissed, !presenter.isBeingPresented else {
            schedulePresentationRetry()
            return
        }
        presentationRetry?.cancel(); presentationRetry = nil
        pending = false
        suppressed = true
        report.present(presenter, screenshot, video, notice) { [weak self] in
            guard let self, !destroyed else { return }
            clearEvidence()
            suppressed = false
            refresh()
        }
    }

    private func schedulePresentationRetry() {
        guard presentationRetry == nil else { return }
        presentationRetry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            guard let self, !destroyed else { return }
            presentationRetry = nil
            presentPending()
        }
    }

    private static func top(_ root: UIViewController) -> UIViewController {
        if let presented = root.presentedViewController { return top(presented) }
        if let navigation = root as? UINavigationController, let visible = navigation.visibleViewController { return top(visible) }
        if let tabs = root as? UITabBarController, let selected = tabs.selectedViewController { return top(selected) }
        return root
    }

    @objc private func active() {
        refresh(); presentPending()
    }

    @objc private func background(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        if origin?.windowScene === scene {
            if controller?.explicitActive == true {
                controller?.finishExplicit(reason: .interrupted)
            } else if capturing {
                cancelPreparation()
            }
        }
        if overlay?.windowScene === scene { detach() }
    }

    @objc private func disconnected(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        if origin?.windowScene === scene {
            generation += 1
            task?.cancel()
            controller?.finishExplicit(reason: .interrupted)
            capturing = false; pending = false
            clearEvidence()
            controller?.reportDidClose()
        }
        if overlay?.windowScene === scene { detach() }
    }

    private func clearEvidence() {
        presentationRetry?.cancel(); presentationRetry = nil
        screenshot = nil
        video?.cancel(); video = nil
        report?.discard(); report = nil
        notice = nil
        origin = nil
        finishNotificationRecording()
    }

    private func detach() {
        hostTouches.view?.removeGestureRecognizer(hostTouches)
        hostTouches.onTouch = nil
        if control != nil { motion.dockForDetach() }
        control?.dispose()
        control = nil
        overlay?.isHidden = true
        overlay?.rootViewController = nil
        overlay = nil
    }

    func shutdown() {
        destroyed = true
        generation += 1
        capturing = false
        pending = false
        task?.cancel(); task = nil
        controller?.onStateChanged = nil
        detach()
        clearEvidence()
        // swiftlint:disable:next notification_center_detachment
        NotificationCenter.default.removeObserver(self) // Reconfiguration ends this observer before deallocation.
    }
}

private final class FloatingHostTouches: UIGestureRecognizer {
    var onTouch: (() -> Void)?

    override func touchesBegan(_: Set<UITouch>, with _: UIEvent) {
        state = .failed
        onTouch?()
    }
}

private final class FloatingWindow: UIWindow {
    override var canBecomeKey: Bool {
        false
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

private final class FloatingViewController: UIViewController {
    weak var host: UIViewController?
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        host?.supportedInterfaceOrientations ?? .all
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        host?.preferredStatusBarStyle ?? .default
    }

    override var prefersStatusBarHidden: Bool {
        host?.prefersStatusBarHidden ?? false
    }
}

@MainActor
enum FloatingNotice {
    static func show(_ message: String, in view: UIView) {
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .callout)
        label.textAlignment = .center
        label.textColor = .label
        label.backgroundColor = .secondarySystemBackground
        label.layer.cornerRadius = 12
        label.clipsToBounds = true
        let width = max(0, view.bounds.width - 40)
        let height = label.sizeThatFits(CGSize(width: width - 24, height: .greatestFiniteMagnitude)).height + 24
        label.frame = CGRect(x: 20, y: view.safeAreaInsets.top + 16, width: width, height: height)
        view.addSubview(label)
        UIAccessibility.post(notification: .announcement, argument: message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { label.removeFromSuperview() }
    }
}
