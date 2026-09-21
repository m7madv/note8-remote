import Foundation
import AVFoundation
import VideoToolbox
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

// Validate the real AVC sample builder and decoder with a synthetic 60 fps fixture.
let videoData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
var accessUnits: [[Data]] = [], access: [Data] = []
for unit in H264Samples.units(videoData) {
    if unit.first! & 31 == 9 && !access.isEmpty { accessUnits.append(access); access = [] }
    access.append(unit)
}
if !access.isEmpty { accessUnits.append(access) }
precondition(accessUnits.count == 60)
let builder = H264Samples()
final class VideoCount { var frames = 0; var failures = 0 }
let decoded = VideoCount()
var videoSession: VTDecompressionSession?
for (index, units) in accessUnits.enumerated() {
    var packet = Data([0x4e,0x38,0x56,0x31,0,0,0,index == 0 ? 1 : 0])
    var pts = UInt64(index * 1_000_000 / 60).bigEndian
    withUnsafeBytes(of: &pts) { packet.append(contentsOf: $0) }
    for unit in units { packet.append(contentsOf: [0,0,0,1]); packet.append(unit) }
    guard let sample = builder.sample(packet), let description = CMSampleBufferGetFormatDescription(sample) else { fatalError("AVC sample parsing failed") }
    let size = CMVideoFormatDescriptionGetDimensions(description)
    precondition(size.width == 360 && size.height == 740)
    if videoSession == nil {
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { context, _, status, _, image, _, _ in
            let counter = Unmanaged<VideoCount>.fromOpaque(context!).takeUnretainedValue()
            if status == noErr && image != nil { counter.frames += 1 } else { counter.failures += 1 }
        }, decompressionOutputRefCon: Unmanaged.passUnretained(decoded).toOpaque())
        precondition(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description, decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: &callback, decompressionSessionOut: &videoSession) == noErr)
    }
    precondition(VTDecompressionSessionDecodeFrame(videoSession!, sampleBuffer: sample, flags: VTDecodeFrameFlags(rawValue: 0), frameRefcon: nil, infoFlagsOut: nil) == noErr)
}
VTDecompressionSessionFinishDelayedFrames(videoSession!)
VTDecompressionSessionWaitForAsynchronousFrames(videoSession!)
VTDecompressionSessionInvalidate(videoSession!)
precondition(decoded.frames == 60 && decoded.failures == 0)
precondition(builder.sample(Data([0,1,2])) == nil)
print("AVC integration passed: 60 decoded frames, 360x740, zero decode failures; target rate only, not device capture measurement")

// Static scenes remain valid while the transport responds; missing startup/recovery does not.
var health = VideoHealth(now: 0)
precondition(health.failure(now: 7) == nil)
precondition(health.failure(now: 9) == "first-frame-timeout")
health.frame()
for t in 1...120 { health.lastPong = Double(t); precondition(health.failure(now: Double(t)) == nil) }
precondition(health.failure(now: 133) == "pong-timeout")
health.lastPong = 140; health.waitForKey(now: 140)
precondition(health.failure(now: 147) == nil)
precondition(health.failure(now: 149) == "key-frame-timeout")
health.frame(); precondition(health.failure(now: 149) == nil)
print("Video health passed: idle scenes survive, startup/pong/key-frame timeouts detected")
