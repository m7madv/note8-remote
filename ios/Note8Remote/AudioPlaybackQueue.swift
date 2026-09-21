import AVFoundation

/// Counts source frames awaiting rendering, excluding speaker/Bluetooth latency.
struct AudioQueueState {
    private(set) var scheduledFrames: Int64 = 0
    private(set) var started = false
    private(set) var prerollFrames: Int64 = 2048
    static let maximumFrames: Int64 = 6144

    mutating func reset(adapting: Bool = false) {
        scheduledFrames = 0; started = false
        if adapting { prerollFrames = min(4096, prerollFrames + 1024) }
    }
    mutating func accept(frames: Int64, rendered: Int64) -> (reset: Bool, start: Bool) {
        precondition(frames > 0 && frames <= Self.maximumFrames)
        var resetPlayer = false
        if started && rendered >= scheduledFrames {
            reset(adapting: true); resetPlayer = true
        }
        let queued = max(0, scheduledFrames - (resetPlayer ? 0 : rendered))
        if queued + frames > Self.maximumFrames {
            reset(); resetPlayer = true
        }
        scheduledFrames += frames
        let start = !started && scheduledFrames >= prerollFrames
        if start { started = true }
        return (resetPlayer, start)
    }
}

/// Owned by LiveAudio's serial queue. Completion callbacks never stop playback.
final class AudioPlaybackQueue {
    let player = AVAudioPlayerNode()
    private var state = AudioQueueState()
    private(set) var resets = 0

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let rendered: Int64
        if player.isPlaying, let nodeTime = player.lastRenderTime,
           let time = player.playerTime(forNodeTime: nodeTime), time.sampleRate > 0 {
            rendered = max(0, Int64(Double(time.sampleTime) * buffer.format.sampleRate / time.sampleRate))
        } else { rendered = 0 }
        let decision = state.accept(frames: Int64(buffer.frameLength), rendered: rendered)
        if decision.reset { player.stop(); resets += 1 }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if decision.start { player.play() }
    }
    func reset(newConnection: Bool = false) {
        player.stop()
        if newConnection { state = AudioQueueState() } else { state.reset() }
    }
}
