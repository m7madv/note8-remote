import AVFoundation
import Foundation

/// All transport, decoding and playback state stays off the UI thread.
final class LiveAudio: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Note8.LiveAudio", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let playback = AudioPlaybackQueue()
    private var player: AVAudioPlayerNode { playback.player }
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private var keepalive: DispatchSourceTimer?
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var decoder: AACDecoder?
    private var requested = false
    private var configured = false
    private var generation = UUID()
    private var lastMessage: String?
    private var clockOffset: Double?
        private var report: (@Sendable (String) -> Void)?

    func setReporter(_ reporter: @escaping @Sendable (String) -> Void) { queue.async { self.report = reporter } }
    func start(host: String, token: String, aac: Bool) {
        queue.async {
            guard !self.requested else { return }
            self.requested = true; self.generation = UUID(); self.playback.reset(newConnection: true)
            self.connect(host: host, token: token, aac: aac, id: self.generation)
        }
    }
    private func connect(host: String, token: String, aac: Bool, id: UUID) {
        guard requested, generation == id else { return }
        do {
            guard let url = URL(string: "ws://\(host):8765/\(aac ? "audio-aac" : "audio")") else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            let session = URLSession(configuration: configuration); self.session = session
            let socket = session.webSocketTask(with: request)
            socket.maximumMessageSize = 8192; self.socket = socket
            decoder = aac ? try AACDecoder() : nil
            try preparePlayback(); socket.resume()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 8, repeating: 8)
            timer.setEventHandler { [weak self, weak socket] in
                guard let self = self, let socket = socket, self.socket === socket else { return }
                socket.sendPing { [weak self] error in
                    guard error != nil, let self = self else { return }
                    self.queue.async {
                        guard self.socket === socket else { return }
                        self.reconnect(host: host, token: token, aac: aac, id: id)
                    }
                }
            }
            keepalive = timer; timer.resume()
            receive(socket, host: host, token: token, aac: aac, id: id)
        } catch { reconnect(host: host, token: token, aac: aac, id: id) }
    }
    private func receive(_ socket: URLSessionWebSocketTask, host: String, token: String, aac: Bool, id: UUID) {
        socket.receive { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                guard self.requested, self.generation == id, self.socket === socket else { return }
                do {
                    let message = try result.get()
                    if case .data(let data) = message { try self.play(data, id: id); self.reportStatus("") }
                    self.receive(socket, host: host, token: token, aac: aac, id: id)
                } catch { self.reconnect(host: host, token: token, aac: aac, id: id) }
            }
        }
    }
    private func reconnect(host: String, token: String, aac: Bool, id: UUID) {
        closePlayback()
        reportStatus("تعذّر استقبال صوت النوت. جارٍ إعادة الاتصال بالصوت.")
        queue.asyncAfter(deadline: .now() + 1) { self.connect(host: host, token: token, aac: aac, id: id) }
    }
    private func reportStatus(_ message: String) {
        guard lastMessage != message else { return }
        lastMessage = message; report?(message)
    }
    private func preparePlayback() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .default, options: [])
        try audio.setPreferredIOBufferDuration(0.01)
        try audio.setActive(true)
        if !configured {
            engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format); configured = true
        }
        try engine.start()
    }
    private func play(_ data: Data, id: UUID) throws {
        guard data.count > 8 else { return }
        if !engine.isRunning { resetQueue(); try preparePlayback() }
        let timestamp = data.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let offset = ProcessInfo.processInfo.systemUptime * 1000 - Double(timestamp)
        clockOffset = min(clockOffset ?? offset, offset)
        // Observed WAN jitter reaches ~230ms. Do not flush natural-speed playback for it.
        // Rebase only a genuinely stale stream; the bounded render queue handles ordinary bursts.
        if offset - (clockOffset ?? offset) > 650 { resetQueue(); clockOffset = offset }
        let buffer: AVAudioPCMBuffer?
        if let decoder = decoder { buffer = try decoder.decode(Data(data.dropFirst(8))) }
        else { buffer = pcm(data) }
        guard let buffer = buffer else { return }
        playback.enqueue(buffer)
    }

    private func pcm(_ data: Data) -> AVAudioPCMBuffer? {
        guard (data.count - 8) % 4 == 0 else { return nil }
        let count = (data.count - 8) / 4
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for frame in 0..<count { for channel in 0..<2 {
                let position = 8 + frame * 4 + channel * 2
                let value = UInt16(bytes[position]) | (UInt16(bytes[position + 1]) << 8)
                channels[channel][frame] = Float(Int16(bitPattern: value)) / 32768
            } }
        }
        return buffer
    }
    private func resetQueue() { playback.reset() }
    private func closePlayback() {
        keepalive?.cancel(); keepalive = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        resetQueue(); engine.stop(); decoder = nil; clockOffset = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func stop() {
        queue.async {
            guard self.requested else { return }
            self.requested = false; self.generation = UUID(); self.closePlayback()
        }
    }
}
