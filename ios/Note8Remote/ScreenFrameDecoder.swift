import UIKit

/// Decode only the most recent waiting image on a worker, never on the touch/UI queue.
final class ScreenFrameDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "Note8.ScreenDecode", qos: .userInitiated)
    private var latest: (Data, @Sendable (UIImage, Int64?) -> Void)?
    private var running = false
    func submit(_ data: Data, completion: @escaping @Sendable (UIImage, Int64?) -> Void) {
        lock.lock(); latest = (data, completion)
        let start = !running; running = true; lock.unlock()
        if start { worker.async { self.drain() } }
    }
    private func drain() {
        while true {
            lock.lock()
            guard let next = latest else { running = false; lock.unlock(); return }
            latest = nil; lock.unlock()
            autoreleasepool {
                var bytes = next.0
                var sequence: Int64?
                if bytes.count > 12 && bytes.prefix(4).elementsEqual([0x4e, 0x38, 0x46, 0x31]) {
                    sequence = Int64(bitPattern: bytes.dropFirst(4).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
                    bytes = Data(bytes.dropFirst(12))
                }
                guard let source = UIImage(data: bytes), let image = source.preparingForDisplay() else { return }
                next.1(image, sequence)
            }
        }
    }
}
