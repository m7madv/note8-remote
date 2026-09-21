import Foundation
import CoreMedia

/// AVC transport is N8V1 + key flag (UInt32) + PTS (UInt64 microseconds) + Annex B.
final class H264Samples {
    private var sps = Data(), pps = Data()
    private var format: CMVideoFormatDescription?
    static func units(_ data: Data) -> [Data] {
        let b = [UInt8](data); var starts: [(Int, Int)] = []; var i = 0
        while i + 3 <= b.count {
            if i + 4 <= b.count && b[i] == 0 && b[i+1] == 0 && b[i+2] == 0 && b[i+3] == 1 { starts.append((i,i+4)); i += 4 }
            else if b[i] == 0 && b[i+1] == 0 && b[i+2] == 1 { starts.append((i,i+3)); i += 3 }
            else { i += 1 }
        }
        return starts.enumerated().compactMap { n, start in
            let end = n+1 < starts.count ? starts[n+1].0 : b.count
            return end > start.1 ? Data(b[start.1..<end]) : nil
        }
    }
    func sample(_ packet: Data, presentationTime: CMTime? = nil) -> CMSampleBuffer? {
        guard packet.count > 16, packet.prefix(4).elementsEqual([0x4e,0x38,0x56,0x31]) else { return nil }
        let pts = packet.dropFirst(8).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        var avcc = Data(); var hasPicture = false
        for unit in Self.units(Data(packet.dropFirst(16))) {
            let type = unit[unit.startIndex] & 31
            if type == 7 { if sps != unit { sps = unit; format = nil }; continue }
            if type == 8 { if pps != unit { pps = unit; format = nil }; continue }
            if type == 1 || type == 5 { hasPicture = true }
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }; avcc.append(unit)
        }
        guard hasPicture, !sps.isEmpty, !pps.isEmpty else { return nil }
        if format == nil {
            let status = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
                let pointers = [s.baseAddress!.assumingMemoryBound(to: UInt8.self),p.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                let sizes = [sps.count,pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            } }
            guard status == noErr else { return nil }
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr, let block = block else { return nil }
        let copied = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTime ?? CMTime(value: Int64(bitPattern: pts), timescale: 1_000_000), decodeTimeStamp: .invalid)
        var size = avcc.count; var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample = sample else { return nil }
        if presentationTime == nil, let a = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(a,0),to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
