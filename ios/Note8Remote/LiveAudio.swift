import AVFoundation
import Foundation

@MainActor final class LiveAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var generation = UUID()
    private var playbackGeneration = UUID()
    private var pending = 0
    private var clockOffset: Double?
    private var configured = false
    private var session: URLSession?
    var report: ((String) -> Void)?

    func start(host: String, token: String) {
        guard receiver == nil else { return }
        let id = UUID(); generation = id
        receiver = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled && self.generation == id {
                do {
                    let address = try RemoteModel.normalizedHost(host)
                    var request = URLRequest(url: URL(string: "ws://\(address):8765/audio")!)
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = 15
                    let session = URLSession(configuration: configuration)
                    self.session = session
                    let socket = session.webSocketTask(with: request)
                    socket.maximumMessageSize = 4096
                    self.socket = socket; socket.resume()
                    try self.preparePlayback()
                    self.clockOffset = nil
                    while !Task.isCancelled && self.generation == id {
                        let message = try await socket.receive()
                        guard self.generation == id else { return }
                        if case .data(let bytes) = message {
                            self.play(bytes, id: id)
                            self.report?("")
                        }
                    }
                } catch {
                    guard self.generation == id, !Task.isCancelled else { return }
                    self.report?("تعذّر استقبال صوت النوت. جارٍ إعادة الاتصال بالصوت.")
                    self.closePlayback()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    private func preparePlayback() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .default, options: [])
        try audio.setPreferredIOBufferDuration(0.02)
        try audio.setActive(true)
        if !configured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            configured = true
        }
        try engine.start(); player.play()
    }

    private func play(_ data: Data, id: UUID) {
        guard data.count > 8, (data.count - 8) % 4 == 0 else { return }
        if !engine.isRunning { do { try preparePlayback() } catch { return } }
        let timestamp = data.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let offset = Date().timeIntervalSince1970 * 1000 - Double(timestamp)
        clockOffset = min(clockOffset ?? offset, offset)
        // Discard delayed packets and bound queued playback to 160 ms.
        guard offset - (clockOffset ?? offset) < 300, pending < 8 else { return }
        let count = (data.count - 8) / 4
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for frame in 0..<count {
                for channel in 0..<2 {
                    let position = 8 + frame * 4 + channel * 2
                    let value = UInt16(bytes[position]) | (UInt16(bytes[position + 1]) << 8)
                    channels[channel][frame] = Float(Int16(bitPattern: value)) / 32768
                }
            }
        }
        pending += 1
        let playbackID = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.generation == id, self.playbackGeneration == playbackID else { return }
                self.pending = max(0, self.pending - 1)
            }
        }
    }

    private func closePlayback() {
        playbackGeneration = UUID()
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        player.stop(); engine.stop(); pending = 0; clockOffset = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func stop() {
        guard receiver != nil else { return }
        generation = UUID(); receiver?.cancel(); receiver = nil
        closePlayback()
    }
}
