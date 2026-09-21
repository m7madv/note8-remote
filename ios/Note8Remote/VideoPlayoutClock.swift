import Foundation

/// Map source PTS to a local playout clock, absorbing network bursts without changing speed.
struct VideoPlayoutClock {
    static let delay = 0.250
    private var offset: Double?
    private var previousSource: Double?
    mutating func presentation(source: Double, arrival: Double) -> Double {
        let candidate = source + (offset ?? (arrival + Self.delay - source))
        if offset == nil || source <= (previousSource ?? -.infinity) || candidate < arrival - 0.100 || candidate > arrival + 0.650 {
            offset = arrival + Self.delay - source
        }
        previousSource = source
        return source + offset!
    }
}
