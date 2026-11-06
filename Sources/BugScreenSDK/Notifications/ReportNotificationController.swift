import UIKit
import UserNotifications

@MainActor
final class ReportNotificationController {
    static let category = "app.bugscreen.report"
    static let reportAction = "app.bugscreen.report.screenshot"
    static let recordAction = "app.bugscreen.report.record"
    private let center: ReportNotificationCenter
    private let adapter = ReportNotificationDelegate()
    private let windowProvider: () -> UIWindow?
    private let eligible: (UIWindow) -> Bool
    private let capture: (UIWindow) -> UIImage?
    private let isActive: (UIWindow) -> Bool
    private let handoffSleep: (UInt64) async throws -> Void
    private let startRecording: (UIWindow, @escaping () -> Void) -> Bool
    private let present: (UIWindow, UIImage?) -> Void
    private var observations: [NSObjectProtocol] = []
    private weak var source: UIWindow?
    private(set) var requestID: String?
    private(set) var hidden = false
    private var shouldRequestPermission = false
    private var permissionRequestEnabled = false
    private var permissionInFlight = false
    private var missingRequestID: String?
    private var stopped = false
    private var ready = false
    private var busy = false
    private var captureBusy = false
    private var recordingFlow = false
    private var pendingRecording = false
    private var recordingTimeout: Task<Void, Never>?
    private var foreground = false
    private var activating = false
    private var needsActivation = false
    private var postingID: String?
    private var revision = 0
    private var cleanup: Task<Void, Never>?

    init(center: ReportNotificationCenter? = nil,
         requestPermission: Bool = false,
         windowProvider: (() -> UIWindow?)? = nil,
         eligible: ((UIWindow) -> Bool)? = nil,
         capture: ((UIWindow) -> UIImage?)? = nil,
         isActive: @escaping (UIWindow) -> Bool = {
             UIApplication.shared.applicationState == .active && $0.windowScene?.activationState == .foregroundActive
         },
         handoffSleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
         startRecording: @escaping (UIWindow, @escaping () -> Void) -> Bool = { _, _ in false },
         present: @escaping (UIWindow, UIImage?) -> Void)
    {
        self.center = center ?? SystemReportNotificationCenter()
        shouldRequestPermission = requestPermission
        permissionRequestEnabled = requestPermission
        self.windowProvider = windowProvider ?? Self.hostWindow
        self.eligible = eligible ?? Self.isEligible
        self.capture = capture ?? Self.captureWindow
        self.isActive = isActive
        self.handoffSleep = handoffSleep
        self.startRecording = startRecording
        self.present = present
    }

    func start() async {
        guard !stopped else { return }
        adapter.previous = center.delegate
        adapter.presentation = { [weak self] identifier, done in
            Task { @MainActor in
                guard let self, self.canHandle(identifier) else { done([]); return }
                done([.list])
            }
        }
        adapter.response = { [weak self] identifier, action, done in
            Task { @MainActor in
                self?.handle(identifier: identifier, action: action)
                done()
            }
        }
        center.delegate = adapter
        let notifications = NotificationCenter.default
        for name in [UIScene.didActivateNotification, UIApplication.didBecomeActiveNotification] {
            observations.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.activate() }
            })
        }
        observations
            .append(notifications
                .addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] event in
                    let scene = event.object as? UIWindowScene
                    Task { @MainActor in
                        guard let self, self.source?.windowScene === scene else { return }
                        self.background()
                    }
                })
        observations
            .append(notifications
                .addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.background() }
                })
        let abandoned = await center.identifiers()
        guard !stopped else { return }
        abandoned.filter { $0.hasPrefix("app.bugscreen.report.") }.forEach(center.remove)
        await center.installCategory(UNNotificationCategory(identifier: Self.category,
                                                            actions: [UNNotificationAction(identifier: Self.reportAction,
                                                                                           title: SDKStrings.floatingReport,
                                                                                           options: [.foreground]),
                                                                      UNNotificationAction(identifier: Self.recordAction,
                                                                                           title: SDKStrings.floatingRecord,
                                                                                           options: [.foreground])],
                                                            intentIdentifiers: [], options: [.customDismissAction]))
        guard !stopped else { return }
        ready = true
        await activate()
    }

    func show(requestPermission: Bool = true) {
        guard !stopped else { return }
        permissionRequestEnabled = requestPermission
        shouldRequestPermission = requestPermission && !permissionInFlight
        revision += 1
        hidden = false
        missingRequestID = nil
        cancelRequest()
        Task { @MainActor in await activate() }
    }

    func hide() {
        guard !stopped else { return }
        shouldRequestPermission = false
        permissionRequestEnabled = false
        hidden = true
        cancelRecordingHandoff()
        missingRequestID = nil
        revision += 1
        cancelRequest()
    }

    func stop() {
        stopped = true
        permissionRequestEnabled = false
        cancelRecordingHandoff()
        revision += 1
        cancelRequest()
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        if center.delegate === adapter { center.delegate = adapter.previous }
        source = nil
    }

    func activate() async {
        guard !activating else { needsActivation = true; return }
        activating = true
        defer {
            activating = false
            if needsActivation {
                needsActivation = false
                Task { @MainActor in await activate() }
            }
        }
        await cleanup?.value
        guard !stopped, ready else { return }
        if center.delegate !== adapter {
            cancelRequest()
            SDKLog.internalLog("BugScreen notification delegate replaced; reporting notification disabled", type: .error)
            hidden = true
            return
        }
        guard let window = windowProvider() ?? source, eligible(window) else { background(); return }
        foreground = true
        if requestID != nil || missingRequestID != nil || recordingFlow {
            guard let source, eligible(source) else { background(); return }
        } else if !busy, !captureBusy {
            source = window
        }
        beginRecordingIfActive()
        guard !hidden, !busy, !captureBusy, !recordingFlow, await requestPermissionIfNeeded(in: window) else { return }
        revision += 1
        let expected = revision
        if let identifier = requestID {
            await reconcile(identifier: identifier, expectedRevision: expected)
        } else {
            await post(window: window, expectedRevision: expected)
        }
    }

    private func requestPermissionIfNeeded(in window: UIWindow) async -> Bool {
        guard shouldRequestPermission else { return true }
        let expected = revision
        let authorized = await center.authorized()
        guard canCompleteAuthorization(in: window, revision: expected) else { return false }
        if !authorized {
            guard isActive(window) else { return false }
            shouldRequestPermission = false
            permissionInFlight = true
            let result = await center.requestAuthorization {
                self.canRequestAuthorization(in: window)
            }
            permissionInFlight = false
            if case .deferred = result { shouldRequestPermission = permissionRequestEnabled }
        } else {
            shouldRequestPermission = false
        }
        return canCompleteAuthorization(in: window, revision: expected)
    }

    private func canRequestAuthorization(in window: UIWindow) -> Bool {
        permissionRequestEnabled && !stopped && !hidden && eligible(window) && source === window &&
            isActive(window) && !busy && !captureBusy && !recordingFlow
    }

    private func canCompleteAuthorization(in window: UIWindow, revision expected: Int) -> Bool {
        !stopped && !hidden && revision == expected && eligible(window) && source === window
    }

    private func reconcile(identifier: String, expectedRevision expected: Int) async {
        let authorized = await center.authorized()
        guard expected == revision, !stopped else { return }
        guard authorized else { cancelRequest(); return }
        let identifiers = await center.identifiers()
        guard expected == revision, !stopped else { return }
        if !identifiers.contains(identifier) {
            hidden = true
            missingRequestID = identifier
            cancelRequest()
        }
    }

    private func post(window: UIWindow, expectedRevision expected: Int) async {
        let authorized = await center.authorized()
        guard expected == revision, !stopped, foreground, !hidden, !busy, !captureBusy, !recordingFlow, eligible(window),
              authorized else { return }
        let identifier = "app.bugscreen.report.\(UUID().uuidString)"
        requestID = identifier
        postingID = identifier
        defer { if postingID == identifier { postingID = nil } }
        let content = UNMutableNotificationContent()
        content.title = NotificationCopy.title
        content.body = NotificationCopy.body
        content.categoryIdentifier = Self.category
        content.interruptionLevel = .passive
        content.threadIdentifier = Self.category
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            if expected != revision || stopped || !foreground { center.remove(identifier) }
        } catch {
            if requestID == identifier { requestID = nil; hidden = true }
            SDKLog.internalLog("BugScreen reporting notification unavailable", type: .error)
        }
    }

    func background() {
        foreground = false
        cancelRecordingHandoff()
        missingRequestID = nil
        revision += 1
        let expectedRevision = revision
        source = nil
        guard let identifier = requestID else { return }
        requestID = nil
        let wasPosting = postingID == identifier
        let previousCleanup = cleanup
        cleanup = Task { @MainActor in
            await previousCleanup?.value
            let identifiers = await center.identifiers()
            // Absence may be dismissal or OS suppression. Neither warrants repeated delivery.
            if expectedRevision == revision, !wasPosting, !identifiers.contains(identifier) { hidden = true }
            center.remove(identifier)
        }
    }

    func reporterStarted() {
        cancelRecordingHandoff()
        missingRequestID = nil
        busy = true
        revision += 1
        cancelRequest()
    }

    func reporterFinished() {
        busy = false
        Task { @MainActor in await activate() }
    }

    func captureBusy(_ value: Bool) {
        guard !stopped else { return }
        captureBusy = value
        if value {
            revision += 1
            cancelRequest()
        } else {
            Task { @MainActor in await activate() }
        }
    }

    private func requestRecording() {
        recordingFlow = true
        revision += 1
        cancelRequest()
        pendingRecording = true
        recordingTimeout = Task { @MainActor [weak self, handoffSleep] in
            do { try await handoffSleep(5_000_000_000) } catch { return }
            guard !Task.isCancelled, let self, pendingRecording else { return }
            recordingTimeout = nil
            pendingRecording = false
            recordingFinished()
        }
        beginRecordingIfActive()
    }

    private func beginRecordingIfActive() {
        guard pendingRecording, !stopped, !hidden, foreground, let source, eligible(source), isActive(source) else { return }
        pendingRecording = false
        recordingTimeout?.cancel(); recordingTimeout = nil
        if !startRecording(source, { [weak self] in self?.recordingFinished() }) { recordingFinished() }
    }

    private func recordingFinished() {
        recordingFlow = false
        Task { @MainActor in await activate() }
    }

    private func cancelRecordingHandoff() {
        recordingTimeout?.cancel(); recordingTimeout = nil
        if pendingRecording { recordingFlow = false }
        pendingRecording = false
    }

    func handle(identifier: String, action: String) {
        guard !stopped else { return }
        // Reactivation can precede the response callback after iOS removes a tapped notification.
        let report = action == UNNotificationDefaultActionIdentifier || action == Self.reportAction
        let record = action == Self.recordAction
        if report || record, missingRequestID == identifier, foreground {
            missingRequestID = nil
            hidden = false
            requestID = identifier
        }
        guard requestID == identifier else { return }
        if action == UNNotificationDismissActionIdentifier {
            hidden = true
            missingRequestID = nil
            cancelRequest()
            return
        }
        guard report || record, canHandle(identifier), let window = source else { return }
        if record { requestRecording(); return }
        reporterStarted()
        let image = capture(window)
        guard !stopped, foreground, eligible(window), source === window else { busy = false; return }
        present(window, image)
    }

    private func canHandle(_ identifier: String) -> Bool {
        guard !stopped, !hidden, !busy, !captureBusy, !recordingFlow, foreground, requestID == identifier, let source else { return false }
        return eligible(source)
    }

    private func cancelRequest() {
        if let requestID { center.remove(requestID) }
        requestID = nil
    }

    static func hostWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).first { $0.isKeyWindow && $0.windowLevel == .normal }
    }

    static func isEligible(_ window: UIWindow) -> Bool {
        guard UIApplication.shared.applicationState != .background,
              let scene = window.windowScene,
              scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
        else { return false }
        return !window.isHidden && window.rootViewController != nil
    }

    static func captureWindow(_ window: UIWindow) -> UIImage? {
        guard window.bounds.width > 0, window.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(window.screen.scale, 2000 / max(window.bounds.width, window.bounds.height))
        format.opaque = false
        var complete = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            complete = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return complete ? image : nil
    }
}

private enum NotificationCopy {
    static var title: String {
        NSLocalizedString(
            "notification.title",
            tableName: "ReportNotification",
            bundle: BugScreenResources.bundle,
            comment: ""
        )
    }

    static var body: String {
        NSLocalizedString(
            "notification.body",
            tableName: "ReportNotification",
            bundle: BugScreenResources.bundle,
            comment: ""
        )
    }
}
