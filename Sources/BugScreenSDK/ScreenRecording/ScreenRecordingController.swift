import ReplayKit
import UIKit

@MainActor
final class ScreenRecordingController: NSObject, RPScreenRecorderDelegate {
    private(set) var lifecycle = RecordingLifecycle()
    var state: ScreenRecordingState {
        lifecycle.state
    }

    var onStateChanged: (() -> Void)?
    private(set) var explicitStartedAt: TimeInterval?
    private var explicitCompletion: ((AutomaticVideoSource?, ScreenRecordingUnavailableReason?) -> Void)?
    private var explicitDeadline: Task<Void, Never>?
    private var explicitLimit: TimeInterval = 60
    private(set) var explicitReachedLimit = false
    var explicitActive: Bool {
        explicitCompletion != nil
    }

    @discardableResult
    func beginExplicit(maximumSeconds: Double,
                       finished: @escaping (AutomaticVideoSource?, ScreenRecordingUnavailableReason?) -> Void) -> Bool
    {
        guard !explicitActive, !lifecycle.reporter, !starting, !stopping,
              maximumSeconds.isFinite, maximumSeconds > 0 else { return false }
        explicitReachedLimit = false
        explicitCompletion = finished
        explicitLimit = min(60, maximumSeconds)
        if ownsSession, lifecycle.approved {
            encoder?.beginExplicit()
            explicitStarted()
        } else { setEnabled(true) }
        onStateChanged?()
        return true
    }

    private func explicitStarted() {
        guard explicitActive, explicitStartedAt == nil else { return }
        explicitStartedAt = ProcessInfo.processInfo.systemUptime
        explicitDeadline = Task { [weak self, explicitLimit, deadlineSleep] in
            do { try await deadlineSleep(UInt64(explicitLimit * 1_000_000_000)) } catch { return }
            self?.explicitReachedLimit = true
            self?.finishExplicit()
        }
        onStateChanged?()
    }

    func finishExplicit(reason: ScreenRecordingUnavailableReason? = nil, platformStopped: Bool = false) {
        guard let completed = explicitCompletion else { return }
        let evidence = explicitStartedAt == nil ? nil : reportWillOpen()
        explicitCompletion = nil
        explicitStartedAt = nil
        explicitDeadline?.cancel()
        explicitDeadline = nil
        frozen = nil // The reporter owns the frozen source after this transfer.
        if platformStopped { ownsSession = false }
        lifecycle.enable(false)
        stopSession()
        onStateChanged?()
        completed(evidence, reason)
    }

    private let deadlineSleep: (UInt64) async throws -> Void
    private let options: ScreenRecordingOptions
    private let recorder: RecordingCaptureSource
    private let foregroundEligibility: @MainActor () -> Bool
    private let hardwareAvailable: () -> Bool
    private let thermalState: () -> ProcessInfo.ThermalState
    private var encoder: ScreenRecordingEncoder?
    private var epoch = 0
    private var ownsSession = false
    private var starting = false
    private var stopping = false
    private weak var previousDelegate: RPScreenRecorderDelegate?
    private var frozen: FrozenRecording?
    private weak static var sessionOwner: ScreenRecordingController?
    private weak static var waitingOwner: ScreenRecordingController?

    init(options: ScreenRecordingOptions,
         recorder: RecordingCaptureSource? = nil,
         foregroundEligibility: @escaping @MainActor () -> Bool = {
             UIApplication.shared.applicationState == .active && UIApplication.shared.connectedScenes
                 .contains { $0.activationState == .foregroundActive }
         },
         hardwareAvailable: @escaping () -> Bool = { HardwareRecordingEncoder.current() != nil },
         thermalState: @escaping () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
         observesNotifications: Bool = true,
         deadlineSleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) })
    {
        self.deadlineSleep = deadlineSleep
        self.options = options
        self.recorder = recorder ?? ReplayKitCapture()
        self.foregroundEligibility = foregroundEligibility
        self.hardwareAvailable = hardwareAvailable
        self.thermalState = thermalState
        super.init()
        let center = NotificationCenter.default
        for (name, action) in [
            (UIApplication.didBecomeActiveNotification, #selector(active)),
            (UIApplication.didEnterBackgroundNotification, #selector(background)),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, #selector(background)),
            (UIApplication.didReceiveMemoryWarningNotification, #selector(memoryPressure)),
            (ProcessInfo.thermalStateDidChangeNotification, #selector(thermalChanged)),
        ] where observesNotifications {
            center.addObserver(self, selector: action, name: name, object: nil)
        }
        lifecycle.foreground(eligible())
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled, explicitActive { finishExplicit(); return }
        lifecycle.enable(enabled)
        if !enabled {
            if Self.waitingOwner === self { Self.waitingOwner = nil }
            frozen?.cancel()
            frozen = nil
            stopSession()
        } else { attemptStart() }
        onStateChanged?()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func shutdown() {
        onStateChanged = nil
        explicitCompletion = nil
        explicitStartedAt = nil
        explicitDeadline?.cancel()
        explicitDeadline = nil
        setEnabled(false)
    }

    func reportWillOpen() -> AutomaticVideoSource? {
        guard !lifecycle.reporter else { return nil }
        let wasRecording = ownsSession && lifecycle.approved
        let priorState = state
        lifecycle.report(true)
        guard lifecycle.enabled else { return nil }
        if wasRecording, let encoder {
            let recording = encoder.freeze()
            frozen = recording
            return AutomaticVideoSource(load: { limits in try await recording.prepare(limits: limits) }, cancel: { recording.cancel() })
        }
        encoder?.stop()
        let reason: String = if case let .unavailable(value) = priorState {
            value.rawValue
        } else {
            "empty"
        }
        return AutomaticVideoSource(load: { _ in throw VideoPreparationError.recording(reason) })
    }

    func reportDidClose() {
        frozen?.cancel()
        frozen = nil
        lifecycle.report(false)
        if ownsSession, lifecycle.approved, lifecycle.foreground {
            encoder?.resume()
        } else { attemptStart() }
    }

    @objc private func active() {
        lifecycle.foreground(eligible())
        attemptStart()
    }

    @objc private func background() {
        if explicitActive { finishExplicit(reason: .interrupted) }
        lifecycle.foreground(false)
        if starting { lifecycle.fail(.interrupted) }
        if ownsSession || starting { stopSession() }
    }

    @objc private func memoryPressure() {
        fail(.memoryPressure)
    }

    @objc private func thermalChanged() {
        if thermalState().rawValue >= ProcessInfo.ThermalState.serious.rawValue { fail(.thermalPressure) }
    }

    private func eligible() -> Bool {
        foregroundEligibility()
    }

    private func attemptStart() {
        guard !starting, !stopping, lifecycle.canRequest else { return }
        if waitForRetiredSession() { return }
        guard lifecycle.requestIfEligible() else { return }
        if let reason = startUnavailableReason() { fail(reason); return }
        epoch += 1
        let generation = epoch
        starting = true
        Self.sessionOwner = self
        previousDelegate = recorder.delegate
        recorder.delegate = self
        let captureOptions = explicitActive ? ScreenRecordingOptions(durationSeconds: 60, quality: options.quality) : options
        let encoder = ScreenRecordingEncoder(options: captureOptions) { [weak self] reason in
            Task { @MainActor in
                guard let self, generation == self.epoch else { return }
                self.fail(reason)
            }
        }
        self.encoder = encoder
        recorder.start(handler: { [weak self, weak encoder] sample, type, error in
            if error != nil {
                Task { @MainActor in
                    guard let self, generation == self.epoch else { return }
                    self.fail(.interrupted)
                }
            } else if type == .video { encoder?.accept(sample) }
        }, completion: { [self] error in
            Task { @MainActor in self.completeStart(error: error, generation: generation, encoder: encoder) }
        })
    }

    private func startUnavailableReason() -> ScreenRecordingUnavailableReason? {
        guard thermalState().rawValue < ProcessInfo.ThermalState.serious.rawValue else { return .thermalPressure }
        guard Self.sessionOwner == nil, !recorder.isRecording else { return .recorderBusy }
        guard recorder.isAvailable else { return .captureUnavailable }
        guard hardwareAvailable() else { return .hardwareEncoderUnavailable }
        return nil
    }

    private func waitForRetiredSession() -> Bool {
        guard let owner = Self.sessionOwner, owner !== self, !owner.lifecycle.enabled else { return false }
        // Reconfiguration waits only for our own retired session, never a host-owned recorder.
        Self.waitingOwner = self
        return true
    }

    private func completeStart(error: Error?, generation: Int, encoder: ScreenRecordingEncoder) {
        starting = false
        guard generation == epoch else {
            // Consent may complete after shutdown; the request owner must stop its late successful session.
            if error == nil {
                ownsSession = true
                stopSession()
            } else {
                cancelWaitingStart(.permissionDenied)
                restoreDelegate()
            }
            return
        }
        guard error == nil else { fail(.permissionDenied); return }
        ownsSession = true
        guard lifecycle.started() else { stopSession(); return }
        if !lifecycle.reporter { encoder.resume() }
        explicitStarted()
        onStateChanged?()
    }

    private func fail(_ reason: ScreenRecordingUnavailableReason) {
        if explicitActive { finishExplicit(reason: reason); return }
        lifecycle.fail(reason)
        stopSession()
        onStateChanged?()
    }

    private func stopSession() {
        epoch += 1
        encoder?.stop()
        encoder = nil
        guard ownsSession else {
            if !starting, !stopping { restoreDelegate() }
            return
        }
        ownsSession = false
        stopping = true
        recorder.stop { [self] error in
            Task { @MainActor in
                if error != nil {
                    self.lifecycle.fail(.interrupted)
                    self.cancelWaitingStart(.interrupted)
                }
                self.stopping = false
                self.restoreDelegate()
                self.attemptStart()
            }
        }
    }

    private func restoreDelegate() {
        if recorder.delegate === self { recorder.delegate = previousDelegate }
        previousDelegate = nil
        if Self.sessionOwner === self {
            Self.sessionOwner = nil
            let waiting = Self.waitingOwner
            Self.waitingOwner = nil
            waiting?.attemptStart()
        }
    }

    private func cancelWaitingStart(_ reason: ScreenRecordingUnavailableReason) {
        guard Self.sessionOwner === self else { return }
        Self.waitingOwner?.lifecycle.fail(reason)
        Self.waitingOwner = nil
    }

    nonisolated func screenRecorder(_: RPScreenRecorder, didStopRecordingWith _: RPPreviewViewController?, error _: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // An unsolicited platform stop always wins over an armed background restart.
            cancelWaitingStart(.stopped)
            if explicitActive { finishExplicit(reason: .stopped, platformStopped: true); return }
            lifecycle.fail(.stopped)
            ownsSession = false
            stopSession()
        }
    }

    nonisolated func screenRecorderDidChangeAvailability(_: RPScreenRecorder) {
        Task { @MainActor [weak self] in
            guard let self, ownsSession, !self.recorder.isAvailable else { return }
            fail(.captureUnavailable)
        }
    }
}
