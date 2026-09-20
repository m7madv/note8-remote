import AVFoundation

final class AACDecoder {
    let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    init() throws {
        var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 2, mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &description), let converter = AVAudioConverter(from: input, to: outputFormat) else { throw NSError(domain: "Note8Audio", code: 1) }
        inputFormat = input; self.converter = converter
        converter.magicCookie = Data([0x11, 0x90])
    }
    func decode(_ packet: Data) throws -> AVAudioPCMBuffer? {
        guard !packet.isEmpty, packet.count <= 4096 else { return nil }
        let input = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: packet.count)
        input.packetCount = 1; input.byteLength = UInt32(packet.count)
        packet.copyBytes(to: input.data.assumingMemoryBound(to: UInt8.self), count: packet.count)
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 1024, mDataByteSize: UInt32(packet.count))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 2048) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if status == .error { throw error ?? NSError(domain: "Note8Audio", code: 2) }
        return output.frameLength > 0 ? output : nil
    }
}
