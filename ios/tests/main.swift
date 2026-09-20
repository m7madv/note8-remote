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
