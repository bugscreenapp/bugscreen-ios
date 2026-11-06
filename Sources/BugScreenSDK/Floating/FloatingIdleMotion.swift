import Foundation

/// Keeps idle presentation separate from the dock saved for the next interaction.
final class FloatingIdleMotion {
    private let motion = FloatingVisibilityMotion()
    private(set) var deadline: TimeInterval?
    var tucked: Bool {
        motion.visible
    }

    var progress: CGFloat {
        motion.progress
    }

    var settling: Bool {
        motion.settling
    }

    func tuck(animate: Bool = false) {
        deadline = nil
        motion.setVisible(true, animate: animate)
    }

    func hold() {
        deadline = nil
        motion.freeze()
    }

    func reveal(animate: Bool) {
        deadline = nil
        motion.setVisible(false, animate: animate)
    }

    func update(now: TimeInterval, eligible: Bool, animate: Bool) {
        if !eligible {
            reveal(animate: animate)
        } else if !motion.visible {
            if let deadline {
                if now >= deadline {
                    self.deadline = nil
                    motion.setVisible(true, animate: animate)
                }
            } else {
                deadline = now + 3
            }
        }
    }

    func advance(_ seconds: TimeInterval, animate: Bool) {
        if !animate { motion.setVisible(motion.visible, animate: false) }
        motion.advance(seconds)
    }

    func offset(anchor: CGFloat, buttonWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        let center = anchor < viewportWidth / 2 ? buttonWidth / 6 : viewportWidth - buttonWidth / 6
        return (center - anchor) * min(1, max(0, progress))
    }
}
