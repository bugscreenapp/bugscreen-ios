import CoreMotion
import UIKit

@MainActor
protocol ShakeMotionSource: AnyObject {
    func start(_ receive: @escaping @MainActor (Double) -> Void)
    func stop()
}

@MainActor
final class AccelerometerSource: ShakeMotionSource {
    private let manager: CMMotionManager
    private let purpose: () -> String?
    private var generation = 0

    init(manager: CMMotionManager = CMMotionManager(),
         purpose: @escaping () -> String? = { Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") as? String })
    {
        self.manager = manager
        self.purpose = purpose
    }

    func start(_ receive: @escaping @MainActor (Double) -> Void) {
        stop()
        guard let purpose = purpose(),
              !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            SDKLog.internalLog("Shake detection requires NSMotionUsageDescription in the host Info.plist", type: .error)
            return
        }
        guard manager.isAccelerometerAvailable else { return }
        let attempt = generation
        manager.accelerometerUpdateInterval = 1.0 / 50
        manager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
            Task { @MainActor in
                guard let self, self.generation == attempt else { return }
                guard let data, error == nil else {
                    self.stop()
                    SDKLog.internalLog("Shake detection unavailable", type: .error)
                    return
                }
                let value = data.acceleration
                receive(sqrt(value.x * value.x + value.y * value.y + value.z * value.z))
            }
        }
    }

    func stop() {
        generation += 1
        manager.stopAccelerometerUpdates()
    }
}

@MainActor
final class ShakeDetector: NSObject {
    private let source: ShakeMotionSource
    private let clock: () -> TimeInterval
    private let onShake: () -> Void
    private var recognizer = ShakeRecognizer()
    private var started = false
    private var generation = 0
    private let notifications: NotificationCenter

    init(source: ShakeMotionSource, notifications: NotificationCenter = .default,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         onShake: @escaping () -> Void)
    {
        self.source = source
        self.notifications = notifications
        self.clock = clock
        self.onShake = onShake
    }

    func start(active: Bool) {
        guard !started else { return }
        started = true
        notifications.addObserver(self, selector: #selector(activate), name: UIApplication.didBecomeActiveNotification, object: nil)
        notifications.addObserver(self, selector: #selector(deactivate), name: UIApplication.willResignActiveNotification, object: nil)
        if active { activate() }
    }

    func stop() {
        started = false
        notifications.removeObserver(self)
        deactivate()
    }

    func reset() {
        recognizer.reset(at: clock())
    }

    @objc private func activate() {
        guard started else { return }
        generation += 1
        let attempt = generation
        reset()
        source.start { [weak self] force in
            guard let self, started, generation == attempt else { return }
            if recognizer.accept(gForce: force, at: clock()) { onShake() }
        }
    }

    @objc private func deactivate() {
        generation += 1
        source.stop()
        reset()
    }
}
