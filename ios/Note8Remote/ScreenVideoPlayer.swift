import AVFoundation
import Foundation

final class ScreenVideoPlayer: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    private let queue = DispatchQueue(label: "Note8.HardwareVideo", qos: .userInteractive)
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var timer: DispatchSourceTimer?
    private var samples = H264Samples()
    private var requested = false, waitingForKey = true
    private var lastPacket: TimeInterval = 0
    private var health = VideoHealth(now: 0)
    private var currentSize: CGSize?
    private var count = 0
    private var reportTime: TimeInterval = 0
    private var update: (@Sendable (CGSize, Double) -> Void)?
    private var error: (@Sendable () -> Void)?
    init() { layer.videoGravity = .resizeAspect }
    func start(host: String, token: String, update: @escaping @Sendable (CGSize, Double) -> Void, error: @escaping @Sendable () -> Void) {
        queue.async {
            guard !self.requested, let url = URL(string: "ws://\(host):8765/video") else { return }
            self.requested = true; self.update = update; self.error = error; self.samples = H264Samples(); self.waitingForKey = true; self.count = 0; self.reportTime = 0
            var request = URLRequest(url: url); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue("1", forHTTPHeaderField: "X-Note8-Video-Ack")
            let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 20
            let session = URLSession(configuration: config); self.session = session
            let socket = session.webSocketTask(with: request); socket.maximumMessageSize = 4 * 1024 * 1024; self.socket = socket; socket.resume()
            self.lastPacket = ProcessInfo.processInfo.systemUptime; self.health = VideoHealth(now: self.lastPacket); self.currentSize = nil
            let timer = DispatchSource.makeTimerSource(queue: self.queue); timer.schedule(deadline: .now()+2,repeating: 2)
            timer.setEventHandler { [weak self, weak socket] in
                guard let self = self, let socket = socket, self.socket === socket else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if let reason = self.health.failure(now: now) { self.fail(reason); return }
                socket.sendPing { [weak self] e in
                    self?.queue.async {
                        guard let self = self, self.socket === socket else { return }
                        if e != nil { self.fail("ping-error"); return }
                        self.health.lastPong = ProcessInfo.processInfo.systemUptime
                        if self.health.lastPong-self.lastPacket > 1, let size = self.currentSize {
                            self.update?(size, 0)
                        }
                    }
                }
            }
            self.timer = timer; timer.resume(); self.receive(socket)
        }
    }
    private func receive(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                guard self.socket === socket, self.requested else { return }
                do {
                    if case .data(let data) = try result.get() { self.display(data) }
                    self.receive(socket)
                } catch { self.fail("receive-error") }
            }
        }
    }
    private func display(_ data: Data) {
        guard data.count > 16, data.prefix(4).elementsEqual([0x4e,0x38,0x56,0x31]) else { return }
        let pts = data.dropFirst(8).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        socket?.send(.string("ack:\(pts)")) { _ in }
        let key = (data[data.startIndex+7] & 1) != 0
        if waitingForKey && !key { return }
        if layer.status == .failed || !layer.isReadyForMoreMediaData {
            layer.flush(); waitingForKey = true; health.waitForKey(now: ProcessInfo.processInfo.systemUptime)
            if !key { socket?.send(.string("key")) { _ in }; return }
        }
        guard let sample = samples.sample(data), let format = CMSampleBufferGetFormatDescription(sample) else { return }
        waitingForKey = false; health.frame(); layer.enqueue(sample); count += 1; lastPacket = ProcessInfo.processInfo.systemUptime
        let now = ProcessInfo.processInfo.systemUptime
        if reportTime == 0 || now - reportTime >= 1 {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            let fps = reportTime == 0 ? 0 : Double(count)/(now-reportTime)
            let size = CGSize(width: Int(dimensions.width),height: Int(dimensions.height)); currentSize = size
            update?(size,fps)
            count = 0; reportTime = now
        }
    }
    private func fail(_ reason: String) { let notify = error; close(reason); notify?() }
    private func close(_ reason: String = "stopped") {
        requested = false; timer?.cancel(); timer = nil
        socket?.cancel(with: .goingAway, reason: Data(reason.utf8)); socket = nil
        session?.invalidateAndCancel(); session = nil; layer.flushAndRemoveImage()
    }
    func stop() { queue.async { self.close() } }
    #if targetEnvironment(simulator)
    func playFixture(_ url: URL, update: @escaping @Sendable (CGSize, Double) -> Void) {
        queue.async {
            guard let data = try? Data(contentsOf: url) else { return }
            self.close(); self.requested = true; self.update = update; self.waitingForKey = true; self.samples = H264Samples(); self.reportTime = 0; self.count = 0
            var units: [[Data]] = [], current: [Data] = []
            for unit in H264Samples.units(data) {
                if unit.first! & 31 == 9 && !current.isEmpty { units.append(current); current = [] }
                current.append(unit)
            }
            if !current.isEmpty { units.append(current) }
            var packets: [Data] = []
            for (i, access) in units.enumerated() {
                var packet = Data([0x4e,0x38,0x56,0x31,0,0,0,i == 0 ? 1 : 0])
                var pts = UInt64(i*1_000_000/60).bigEndian
                withUnsafeBytes(of: &pts) { packet.append(contentsOf: $0) }
                for unit in access { packet.append(contentsOf: [0,0,0,1]); packet.append(unit) }
                packets.append(packet)
            }
            guard !packets.isEmpty else { return }
            var index = 0
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now()+0.3,repeating: .nanoseconds(16_666_667))
            timer.setEventHandler { self.display(packets[index]); index = (index+1) % packets.count }
            self.timer = timer; timer.resume()
        }
    }
    #endif

}
