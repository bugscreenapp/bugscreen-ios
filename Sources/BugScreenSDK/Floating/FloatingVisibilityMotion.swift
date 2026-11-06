import Foundation

/// Keeps floating visibility transitions continuous when an interaction reverses them.
final class FloatingVisibilityMotion {
    private(set) var visible = false
    private(set) var progress: CGFloat = 0
    private(set) var settling = false
    private var velocity: CGFloat = 0

    func setVisible(_ visible: Bool, animate: Bool) {
        self.visible = visible
        let target: CGFloat = visible ? 1 : 0
        if !animate {
            progress = target
            velocity = 0
            settling = false
        } else {
            settling = abs(progress - target) > 0.001 || abs(velocity) > 0.01
        }
    }

    func freeze() {
        velocity = 0
        settling = false
    }

    func advance(_ seconds: TimeInterval) {
        let target: CGFloat = visible ? 1 : 0
        var remaining = min(0.05, max(0, seconds))
        while settling, remaining > 0 {
            let dt = min(remaining, 1.0 / 120)
            velocity += (420 * (target - progress) - 30 * velocity) * dt
            let proposed = progress + velocity * dt
            progress = min(1.04, max(-0.04, proposed))
            if progress != proposed { velocity = 0 }
            if abs(target - progress) < 0.001, abs(velocity) < 0.01 {
                progress = target
                velocity = 0
                settling = false
            }
            remaining -= dt
        }
    }
}
