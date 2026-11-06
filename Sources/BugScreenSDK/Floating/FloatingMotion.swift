import Foundation

final class FloatingMotion {
    private var priorBounds: CGRect?

    func dockForDetach() {
        guard let bounds = priorBounds else { return }
        if settling { place(target, bounds: bounds) } else { release(.zero, bounds: bounds, animate: false) }
    }

    func adaptBounds(_ bounds: CGRect, preserveDock: Bool = true) {
        if let old = priorBounds, old != bounds {
            let fraction = min(1, max(0, (position.y - old.minY) / max(1, old.height)))
            let edge = (settling ? target.x : position.x) < old.midX ? bounds.minX : bounds.maxX
            place(preserveDock ? CGPoint(x: edge, y: bounds.minY + fraction * bounds.height) : position, bounds: bounds)
        } else if priorBounds == nil {
            place(position == .zero ? CGPoint(x: bounds.maxX, y: bounds.midY) : position, bounds: bounds)
        }
        priorBounds = bounds
    }

    private(set) var position = CGPoint.zero
    private(set) var target = CGPoint.zero
    private var velocity = CGPoint.zero
    private(set) var settling = false

    func place(_ point: CGPoint, bounds: CGRect) {
        position = clamp(point, bounds)
        target = position
        velocity = .zero
        settling = false
    }

    func release(_ speed: CGPoint, bounds: CGRect, animate: Bool = true) {
        let projected = CGPoint(x: position.x + speed.x * 0.18, y: position.y + speed.y * 0.18)
        target = clamp(CGPoint(x: projected.x < bounds.midX ? bounds.minX : bounds.maxX, y: projected.y), bounds)
        velocity = CGPoint(x: min(4500, max(-4500, speed.x)), y: min(4500, max(-4500, speed.y)))
        settling = animate
        if !animate { position = target }
    }

    @discardableResult
    func advance(_ seconds: TimeInterval, bounds: CGRect) -> CGPoint {
        target = clamp(target, bounds)
        var remaining = min(0.05, max(0, seconds))
        while settling, remaining > 0 {
            let dt = min(remaining, 1.0 / 120)
            velocity.x += (420 * (target.x - position.x) - 32 * velocity.x) * dt
            velocity.y += (420 * (target.y - position.y) - 32 * velocity.y) * dt
            let proposed = CGPoint(x: position.x + velocity.x * dt, y: position.y + velocity.y * dt)
            // Leave room for a small rebound inside the screen's safe edge inset.
            position = clamp(proposed, bounds.insetBy(dx: -8, dy: 0))
            if position.x != proposed.x { velocity.x = 0 }
            if position.y != proposed.y { velocity.y = 0 }
            if abs(target.x - position.x) + abs(target.y - position.y) < 0.2, abs(velocity.x) + abs(velocity.y) < 2 {
                position = target
                settling = false
            }
            remaining -= dt
        }
        return position
    }

    private func clamp(_ point: CGPoint, _ bounds: CGRect) -> CGPoint {
        CGPoint(x: min(bounds.maxX, max(bounds.minX, point.x)), y: min(bounds.maxY, max(bounds.minY, point.y)))
    }
}
