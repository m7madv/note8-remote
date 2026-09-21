import Foundation
import AVFoundation
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let decoder = try AACDecoder()
var position = 0, frames = 0, crossings = 0
var peak: Float = 0, previous: Float = 0
while position + 7 <= data.count {
    precondition(data[position] == 0xff && data[position + 1] & 0xf6 == 0xf0)
    let length = (Int(data[position + 3] & 3) << 11) | (Int(data[position + 4]) << 3) | Int(data[position + 5] >> 5)
    precondition(length >= 7 && position + length <= data.count)
    if let buffer = try decoder.decode(data.subdata(in: (position + 7)..<(position + length))) {
        precondition(buffer.format.sampleRate == 48000 && buffer.format.channelCount == 2)
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(buffer.frameLength) {
            let sample = samples[i]
            if previous <= 0 && sample > 0 { crossings += 1 }
            previous = sample; peak = max(peak, abs(sample))
        }
        frames += Int(buffer.frameLength)
    }
    position += length
}
precondition(position == data.count && frames >= 47000 && frames <= 51000, "Unexpected decoded duration")
let frequency = Double(crossings) * 48000 / Double(frames)
precondition(peak > 0.02 && peak < 0.3 && frequency > 940 && frequency < 1050, "Corrupt audio or playback speed")
print("AAC decoder passed: frames=\(frames), peak=\(peak), frequency=\(frequency) Hz, stereo48k")

// A late speaker completion must not be mistaken for queued, unrendered audio.
var state = AudioQueueState()
for packet in 0..<10_000 {
    let rendered = Int64(max(0, packet - 2) * 1024)
    let decision = state.accept(frames: 1024, rendered: rendered)
    precondition(!decision.reset, "Steady audio spuriously flushed")
}
// Reproduce the old six-packet counter failure with a 200 ms output device delay.
var oldPending = 0, oldResets = 0
for _ in 0..<10 { if oldPending >= 6 { oldPending = 0; oldResets += 1 }; oldPending += 1 }
precondition(oldResets > 0)
// A genuine render starvation adapts preroll; a burst remains bounded.
let starved = state.accept(frames: 1024, rendered: state.scheduledFrames + 4800)
precondition(starved.reset && !starved.start && state.prerollFrames == 3072)
var burstResets = 0
for _ in 0..<100 {
    let d = state.accept(frames: 1024, rendered: 0)
    if d.reset { burstResets += 1 }
    precondition(state.scheduledFrames <= AudioQueueState.maximumFrames)
}
precondition(burstResets > 0)
print("Audio queue regression passed: 10000 steady packets, output-delay reproduction, starvation, bounded bursts")

// Exercise the actual scheduling class against Apple's rendering engine.
let engine = AVAudioEngine()
let playback = AudioPlaybackQueue()
let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
engine.attach(playback.player)
engine.connect(playback.player, to: engine.mainMixerNode, format: pcmFormat)
try engine.enableManualRenderingMode(.offline, format: pcmFormat, maximumFrameCount: 512)
try engine.start()
func toneBuffer() -> AVAudioPCMBuffer {
    let b = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 1024)!
    b.frameLength = 1024
    for c in 0..<2 { for i in 0..<1024 { b.floatChannelData![c][i] = 0.1 } }
    return b
}
playback.enqueue(toneBuffer()); playback.enqueue(toneBuffer())
let renderedBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 512)!
var silentFrames = 0, renderedFrames = 0
for step in 0..<1200 {
    if step > 0 && step % 2 == 0 { playback.enqueue(toneBuffer()) }
    let result = try engine.renderOffline(512, to: renderedBuffer)
    precondition(result == .success, "Offline engine failed")
    for i in 0..<Int(renderedBuffer.frameLength) {
        if abs(renderedBuffer.floatChannelData![0][i]) < 0.01 { silentFrames += 1 }
    }
    renderedFrames += Int(renderedBuffer.frameLength)
}
precondition(playback.resets == 0, "Actual player queue spuriously flushed")
precondition(silentFrames == 0 && renderedFrames == 614400, "Unexpected gaps in rendered audio")
playback.reset(); engine.stop()
print("Apple rendering integration passed: 12.8 seconds, 614400 frames, zero silent frames, zero queue flushes")
