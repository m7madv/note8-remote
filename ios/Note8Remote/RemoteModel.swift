import SwiftUI
import Foundation
import CryptoKit
import UIKit

@MainActor final class RemoteModel: ObservableObject {
    @Published var host = UserDefaults.standard.string(forKey: "host") ?? ""
    @Published var token = PairingStore.load()
    @Published var connected = false
    @Published var audioEnabled = UserDefaults.standard.object(forKey: "liveAudio") as? Bool ?? true
    @Published var audioMessage = ""
    private var audioSupported = false
    private var aacSupported = false
    private let liveAudio = LiveAudio()
    func updateAudio() {
        UserDefaults.standard.set(audioEnabled, forKey: "liveAudio")
        liveAudio.setReporter { [weak self] message in Task { @MainActor in self?.audioMessage = message } }
        if connected && viewingScreen && audioEnabled && audioSupported { liveAudio.start(host: (try? Self.normalizedHost(host)) ?? host, token: token, aac: aacSupported) }
        else { liveAudio.stop() }
    }
    @Published var image: UIImage?
    @Published var error = ""
    @Published var mediaKind = ""
    @Published var durationMs: Int64 = 0
    @Published var recording = false
    @Published var recordingLabel = ""
    @Published var uploading = false
    @Published var progress: Double = 0
    @Published var transferLabel = ""
    @Published var selectedFile: URL?
    @Published var selectedKind = "video"
    @Published var previewURL: URL?
    @Published var downloadingPreview = false
    @Published var lastFrame = Date.distantPast
    @Published var speed = UserDefaults.standard.integer(forKey: "uploadRate") == 0 ? 1_048_576 : UserDefaults.standard.integer(forKey: "uploadRate")
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var wantsConnection = false
    private var viewingScreen = true
    private var generation = UUID()
    private var outgoing = [Data]()
    private var draining = false
    private var uploadTask: Task<Void, Never>?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 25
        c.timeoutIntervalForResource = 150
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c)
    }()
    var stale: Bool { !connected || Date().timeIntervalSince(lastFrame) > 4 }
    var canRecord: Bool { connected && !stale && !uploading && !recording && mediaKind == "video" && durationMs >= 500 && durationMs <= 60_000 }
    static func normalizedHost(_ input: String) throws -> String {
        let host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, host.split(separator: ".").count == 4,
              parts.allSatisfy({ (0...255).contains($0) }), parts[0] == 100, (64...127).contains(parts[1]) else {
            throw RemoteError.message("أدخل عنوان النوت من Tailscale، مثل 100.80.20.10.")
        }
        return parts.map(String.init).joined(separator: ".")
    }
    func savePairing() throws {
        host = try Self.normalizedHost(host)
        token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count == 48, token.allSatisfy({ $0.isHexDigit }) else { throw RemoteError.message("ألصق رمز الاقتران الكامل من تطبيق النوت.") }
        try PairingStore.save(token)
        UserDefaults.standard.set(host, forKey: "host")
    }
    func importPairing(_ url: URL) {
        guard url.scheme == "note8remote", url.host == "pair", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        uploadTask?.cancel(); disconnect()
        let items = components.queryItems ?? []
        host = items.first(where: { $0.name == "host" })?.value ?? ""
        token = items.first(where: { $0.name == "token" })?.value ?? ""
        // Imported credentials are shown for review; connection requires the user's button.
    }
    func request(_ path: String, method: String = "GET", data: Data? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        let address = try Self.normalizedHost(host)
        guard let url = URL(string: "http://\(address):8765\(path)") else { throw RemoteError.message("عنوان غير صالح.") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue(data == nil ? "application/json" : "application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.httpBody = data
        let (bytes, response) = try await session.data(for: r)
        let object: [String: Any] = ((try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]) ?? Dictionary<String, Any>()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RemoteError.message(object["error"] as? String ?? "تعذّر تنفيذ الطلب. أعد الاتصال وحاول مجدداً.")
        }
        return object
    }
    func post(_ path: String, _ object: [String: Any]) async throws -> [String: Any] { try await request(path, method: "POST", data: JSONSerialization.data(withJSONObject: object)) }
    func applyStatus(_ value: [String: Any]) {
        audioSupported = value["systemAudio"] as? Bool ?? false
        aacSupported = value["aacAudio"] as? Bool ?? false
        updateAudio()
        if let media = value["media"] as? [String: Any] { mediaKind = media["kind"] as? String ?? ""; durationMs = (media["durationMs"] as? NSNumber)?.int64Value ?? 0 }
        if let isRecording = value["recording"] as? Bool { recording = isRecording }
        if let state = value["record"] as? [String: Any] { applyEvent(state) }
    }
    func connect() {
        disconnect()
        do { try savePairing() } catch { self.error = error.localizedDescription; return }
        wantsConnection = true
        let id = generation
        connectTask = Task { await establish(id) }
    }
    private func establish(_ id: UUID) async {
        var retry = 1
        while wantsConnection && id == generation && !Task.isCancelled {
            do {
                let status = try await request("/status")
                guard status["ready"] as? Bool == true else { throw RemoteError.message("افتح تطبيق النوت وشغّل الخدمة واسمح بإذن الروت.") }
                guard id == generation else { return }
                applyStatus(status)
                var r = URLRequest(url: URL(string: "ws://\(host):8765/stream")!)
                r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let socket = session.webSocketTask(with: r)
                socket.maximumMessageSize = 2 * 1024 * 1024
                task = socket; socket.resume(); connected = true; error = ""; outgoing.removeAll()
                enqueue(["type": "view", "enabled": viewingScreen])
                heartbeat?.cancel()
                heartbeat = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                        guard let self = self, self.generation == id, !Task.isCancelled else { return }
                        self.enqueue(["type": "ping"])
                        do { let value = try await self.request("/status"); self.applyStatus(value) } catch { /* The socket reconnect loop owns connection errors. */ }
                    }
                }
                while !Task.isCancelled && id == generation {
                    let message = try await socket.receive()
                    guard id == generation else { return }
                    switch message {
                    case .data(let bytes): if let frame = UIImage(data: bytes) { image = frame; lastFrame = Date() }
                    case .string(let text): if let event = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { applyEvent(event) }
                    @unknown default: break
                    }
                }
                return
            } catch {
                guard id == generation, wantsConnection, !Task.isCancelled else { return }
                liveAudio.stop(); connected = false; image = nil; self.error = "انقطع الاتصال. جارٍ إعادة المحاولة… " + error.localizedDescription
                task?.cancel(with: .goingAway, reason: nil); heartbeat?.cancel()
                try? await Task.sleep(nanoseconds: UInt64(retry) * 1_000_000_000)
                retry = min(15, retry * 2)
            }
        }
    }
    func disconnect() {
        liveAudio.stop()
        wantsConnection = false; generation = UUID(); connectTask?.cancel(); receiveTask?.cancel(); heartbeat?.cancel()
        task?.cancel(with: .goingAway, reason: nil); task = nil; connected = false; image = nil; outgoing.removeAll()
    }
    func background() { uploadTask?.cancel(); disconnect() }
    func resumeSavedConnection() { if !host.isEmpty && host == UserDefaults.standard.string(forKey: "host") && token == PairingStore.load() && !connected { connect() } }
    func setViewingScreen(_ enabled: Bool) { viewingScreen = enabled; if connected { enqueue(["type": "view", "enabled": enabled]) }; updateAudio() }
    func applyEvent(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "status": applyStatus(event)
        case "error": error = event["message"] as? String ?? "تعذّر إكمال العملية."; recording = false
        case "audioStatus": audioMessage = event["available"] as? Bool == true ? "" : (event["message"] as? String ?? "تعذّر بث صوت النظام.")
        case "record":
            let state = (event["state"] as? String) ?? ""
            recording = state != "finished"
            recordingLabel = state == "starting" ? "انتظار بداية التسجيل…" : state == "finished" ? "انتهى التسجيل. راجع النتيجة على شاشة النوت." : "جارٍ التسجيل؛ سيتوقف على النوت عند نهاية المقطع."
        default: break
        }
    }
    func enqueue(_ command: [String: Any]) {
        guard connected, let bytes = try? JSONSerialization.data(withJSONObject: command) else { return }
        // Keep down/up ordered; coalesce only consecutive move events when the network is slow.
        if command["type"] as? String == "touch", command["action"] as? Int == 2, let last = outgoing.last,
           let previous = (try? JSONSerialization.jsonObject(with: last)) as? [String: Any], previous["action"] as? Int == 2 { outgoing.removeLast() }
        outgoing.append(bytes)
        guard !draining else { return }
        draining = true
        Task {
            defer { draining = false }
            while !outgoing.isEmpty, let socket = task {
                let data = outgoing.removeFirst()
                do { try await socket.send(.string(String(decoding: data, as: UTF8.self))) }
                catch { self.error = "تعذّر إرسال اللمس. أعد الاتصال."; outgoing.removeAll(); break }
            }
        }
    }
    func command(_ value: [String: Any]) {
        Task { do { _ = try await post("/command", value) } catch { self.error = error.localizedDescription } }
    }
    func choose(_ file: URL, kind: String) { if let old = selectedFile, old != file { try? FileManager.default.removeItem(at: old) }; selectedFile = file; selectedKind = kind; progress = 0; transferLabel = "جاهز للنقل دون ضغط إضافي" }
    func cancelUpload() { uploadTask?.cancel();Task { _ = try? await post("/upload/pause", [:]) } }
    func usePreviousMedia() { Task { do { _ = try await post("/upload/pause", [:]); transferLabel = "النقل متوقف؛ المقطع السابق ما زال فعالاً." } catch { self.error = error.localizedDescription } } }
    func fetchPreview() {
        guard connected, !downloadingPreview else { return }; downloadingPreview = true
        Task {
            defer { downloadingPreview = false }
            do {
                let address = try Self.normalizedHost(host)
                var r = URLRequest(url: URL(string: "http://\(address):8765/output")!)
                r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (temp, response) = try await session.download(for: r)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    let value = (try? JSONSerialization.jsonObject(with: Data(contentsOf: temp))) as? [String: Any]
                    throw RemoteError.message(value?["error"] as? String ?? "تعذّر جلب المعاينة.")
                }
                let saved = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
                try FileManager.default.moveItem(at: temp, to: saved)
                if let old = previewURL { try? FileManager.default.removeItem(at: old) }
                previewURL = saved
            } catch { self.error = error.localizedDescription }
        }
    }
    func uploadSelected() {
        guard !uploading, let file = selectedFile, connected else { return }
        uploading = true; error = ""; transferLabel = "حساب بصمة الملف…"
        uploadTask = Task {
            defer { uploading = false }
            do {
                let (hash, size) = try await Task.detached(priority: .utility) { () throws -> (String, Int64) in
                    let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
                    var hasher = SHA256(); var bytes: Int64 = 0
                    while let data = try input.read(upToCount: 256 * 1024), !data.isEmpty { try Task.checkCancellation(); hasher.update(data: data); bytes += Int64(data.count) }
                    return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
                }.value
                try Task.checkCancellation()
                guard size > 0, size <= 1_073_741_824 else { throw RemoteError.message("اختر ملفاً لا يتجاوز حجمه 1 غيغابايت.") }
                let info = try await post("/upload/begin", ["bytes": size, "sha256": hash, "kind": selectedKind])
                guard let id = info["id"] as? String else { throw RemoteError.message("تعذّر بدء النقل.") }
                var offset = (info["offset"] as? NSNumber)?.int64Value ?? 0
                let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
                while offset < size {
                    try Task.checkCancellation()
                    try input.seek(toOffset: UInt64(offset))
                    guard let chunk = try input.read(upToCount: 512 * 1024), !chunk.isEmpty else { throw RemoteError.message("تعذّر قراءة الملف.") }
                    let start = Date()
                    let reply = try await request("/upload/chunk?id=\(id)&offset=\(offset)", method: "POST", data: chunk)
                    let next = (reply["offset"] as? NSNumber)?.int64Value ?? offset
                    guard next == offset + Int64(chunk.count) else { throw RemoteError.message("توقف النقل. اضغط متابعة لاستئنافه.") }
                    offset = next; progress = Double(offset) / Double(size)
                    transferLabel = "نقل الأصل: \(Int(progress * 100))٪"
                    let delay = Double(chunk.count) / Double(max(262_144, speed)) - Date().timeIntervalSince(start)
                    if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                }
                transferLabel = "التحقق من البصمة وتجهيز المقطع…"
                let result = try await post("/upload/finish", ["id": id])
                guard result["sha256"] as? String == hash else { throw RemoteError.message("لم تتأكد سلامة الملف.") }
                applyStatus(result); progress = 1; transferLabel = "تم نقل الأصل والتحقق من مطابقته"
            } catch is CancellationError { transferLabel = "النقل متوقف؛ يمكنك متابعته من الجزء المكتمل." }
            catch { self.error = error.localizedDescription; transferLabel = "توقف النقل؛ أعد الاتصال واضغط متابعة." }
        }
    }
}
