import Foundation

/// Idle screen content is not a network timeout. Pongs prove transport liveness.
struct VideoHealth {
    var started: TimeInterval
    var lastPong: TimeInterval
    var hasFrame = false
    var waitingSince: TimeInterval?
    init(now: TimeInterval) { started = now; lastPong = now }
    mutating func frame() { hasFrame = true; waitingSince = nil }
    mutating func waitForKey(now: TimeInterval) { if waitingSince == nil { waitingSince = now } }
    func failure(now: TimeInterval) -> String? {
        if now - lastPong > 12 { return "pong-timeout" }
        if !hasFrame && now - started > 8 { return "first-frame-timeout" }
        if let since = waitingSince, now - since > 8 { return "key-frame-timeout" }
        return nil
    }
}
