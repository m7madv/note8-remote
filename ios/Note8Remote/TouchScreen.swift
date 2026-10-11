import SwiftUI
import UIKit

struct TouchScreen: UIViewRepresentable {
    var image: UIImage?
    var videoPlayer: ScreenVideoPlayer? = nil
    var videoSize: CGSize? = nil
    var enabled: Bool
    var calibrating: Bool
    var point: (CGPoint) -> Void
    var touch: (Int, [[String: Any]]) -> Void

    func makeUIView(context: Context) -> TouchSurface { TouchSurface() }
    static func dismantleUIView(_ uiView: TouchSurface, coordinator: ()) { uiView.cancelActiveTouches() }

    func updateUIView(_ uiView: TouchSurface, context: Context) {
        if !enabled || uiView.calibrating != calibrating { uiView.cancelActiveTouches() }
        uiView.setVideo(videoPlayer, size: videoSize)
        uiView.imageView.image = image
        uiView.enabled = enabled
        uiView.calibrating = calibrating
        uiView.onPoint = point
        uiView.onTouch = touch
    }
}

final class TouchSurface: UIView {
    let imageView = UIImageView()
    private var videoPlayer: ScreenVideoPlayer?
    private var videoSize: CGSize?
    private var activeTouches: [Int: UITouch] = [:]
    private var activeOrder: [Int] = []
    private var pointerIDs: [ObjectIdentifier: Int] = [:]
    private var nextPointerID = 0
    private var lastMove: TimeInterval = 0

    var enabled = true
    var calibrating = false
    var onPoint: ((CGPoint) -> Void)?
    var onTouch: ((Int, [[String: Any]]) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
        isMultipleTouchEnabled = true
        semanticContentAttribute = .forceLeftToRight
        accessibilityLabel = "شاشة النوت للتحكم باللمس"
        accessibilityHint = "استخدم إصبعاً للتحكم، وإصبعين لتكبير الكاميرا داخل الهاتف."
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func setVideo(_ player: ScreenVideoPlayer?, size: CGSize?) {
        if videoPlayer !== player {
            videoPlayer?.layer.removeFromSuperlayer()
            videoPlayer = player
            if let player = player { layer.insertSublayer(player.layer, at: 0) }
        }
        videoSize = size
        imageView.isHidden = size != nil
        player?.layer.isHidden = size == nil
        player?.layer.frame = bounds
    }

    func cancelActiveTouches() {
        guard !activeTouches.isEmpty else { return }
        let points = remotePoints()
        if !points.isEmpty { onTouch?(3, points) }
        activeTouches.removeAll()
        activeOrder.removeAll()
        pointerIDs.removeAll()
        nextPointerID = 0
    }

    override func layoutSubviews() {
        let sizeChanged = imageView.bounds.size != bounds.size
        if sizeChanged { cancelActiveTouches() }
        super.layoutSubviews()
        imageView.frame = bounds
        videoPlayer?.layer.frame = bounds
    }

    private func position(_ touch: UITouch, clamp: Bool = false) -> CGPoint? {
        guard let imageSize = videoSize ?? imageView.image?.size,
              imageSize.width > 0, imageSize.height > 0 else { return nil }
        let ratio = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
        let origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        let location = touch.location(in: self)
        let point = CGPoint(x: (location.x - origin.x) / size.width, y: (location.y - origin.y) / size.height)
        if !clamp && (point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1) { return nil }
        return CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
    }

    private func remotePoints() -> [[String: Any]] {
        activeOrder.compactMap { id in
            guard let touch = activeTouches[id], let point = position(touch, clamp: true) else { return nil }
            return ["id": id, "x": point.x, "y": point.y]
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard enabled else { return }
        if calibrating {
            if let touch = touches.first, let point = position(touch) { onPoint?(point) }
            return
        }
        for touch in touches {
            guard position(touch) != nil, activeTouches.count < 2, nextPointerID < 10 else { continue }
            let id = nextPointerID
            nextPointerID += 1
            activeTouches[id] = touch
            activeOrder.append(id)
            pointerIDs[ObjectIdentifier(touch)] = id
            let points = remotePoints()
            guard !points.isEmpty else { continue }
            if points.count == 1 {
                onTouch?(0, points)
            } else {
                let index = points.firstIndex { ($0["id"] as? Int) == id } ?? points.count - 1
                onTouch?(5 | (index << 8), points)
            }
            lastMove = ProcessInfo.processInfo.systemUptime
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard enabled, !activeTouches.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMove >= 1.0 / 60.0 else { return }
        let points = remotePoints()
        guard !points.isEmpty else { return }
        lastMove = now
        onTouch?(2, points)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let ended = touches.compactMap { touch -> (Int, UITouch, Int)? in
            guard let id = pointerIDs[ObjectIdentifier(touch)] else { return nil }
            return (id, touch, activeOrder.firstIndex(of: id) ?? 0)
        }.sorted { $0.2 > $1.2 }
        for (id, touch, _) in ended {
            guard activeTouches[id] != nil else { continue }
            activeTouches[id] = touch
            let points = remotePoints()
            let index = points.firstIndex { ($0["id"] as? Int) == id } ?? 0
            onTouch?(points.count == 1 ? 1 : (6 | (index << 8)), points)
            activeTouches.removeValue(forKey: id)
            activeOrder.removeAll { $0 == id }
            pointerIDs.removeValue(forKey: ObjectIdentifier(touch))
        }
        if activeTouches.isEmpty { nextPointerID = 0 }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelActiveTouches()
    }
}
