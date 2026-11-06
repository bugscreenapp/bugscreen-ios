import Foundation

struct ShakeRecognizer {
    private var peaks = 0
    private var firstPeak: TimeInterval = 0
    private var lastPeak = -Double.infinity
    private var lastMotion: TimeInterval = 0
    private var blockedUntil: TimeInterval = 0
    private var armed = false
    private var aboveThreshold = false

    mutating func reset(at now: TimeInterval) {
        peaks = 0
        lastMotion = now
        blockedUntil = now + 1
        armed = false
        aboveThreshold = false
    }

    mutating func accept(gForce: Double, at now: TimeInterval) -> Bool {
        guard gForce.isFinite else { return false }
        if !armed, now >= blockedUntil, now - lastMotion >= 0.5 { armed = true }
        if gForce > 1.3 { lastMotion = now }
        let high = gForce >= 2.5
        let rising = high && !aboveThreshold
        aboveThreshold = high
        guard armed, rising else { return false }
        if peaks == 0 || now - firstPeak > 0.8 {
            peaks = 0
            firstPeak = now
        }
        guard peaks == 0 || now - lastPeak >= 0.08 else { return false }
        lastPeak = now
        peaks += 1
        guard peaks >= 3 else { return false }
        reset(at: now)
        blockedUntil = now + 2
        return true
    }
}
