import SwiftUI
import UIKit

struct TouchScreen: UIViewRepresentable {
    var image: UIImage?
    var videoPlayer: ScreenVideoPlayer? = nil
    var videoSize: CGSize? = nil
    var enabled: Bool
    var calibrating: Bool
    @Binding var zoomScale: CGFloat
    var reduceMotion: Bool
    var point: (CGPoint) -> Void
    var touch: (Int, CGPoint) -> Void

    func makeUIView(context: Context) -> TouchSurface { TouchSurface() }
    static func dismantleUIView(_ uiView: TouchSurface, coordinator: ()) { uiView.cancelActiveTouch() }

    func updateUIView(_ uiView: TouchSurface, context: Context) {
        if !enabled || uiView.calibrating != calibrating { uiView.cancelActiveTouch() }
        uiView.setVideo(videoPlayer, size: videoSize)
        uiView.imageView.image = image
        uiView.enabled = enabled
        uiView.calibrating = calibrating
        uiView.onPoint = point
        uiView.onTouch = touch
        uiView.onZoomChanged = { value in
            guard abs(zoomScale - value) > 0.005 else { return }
            DispatchQueue.main.async { zoomScale = value }
        }
        uiView.setZoom(zoomScale, animated: !reduceMotion)
    }
}

final class TouchSurface: UIView, UIGestureRecognizerDelegate {
    private let contentView = UIView()
    let imageView = UIImageView()
    private var videoPlayer: ScreenVideoPlayer?
    private var videoSize: CGSize?
    private(set) var currentZoom: CGFloat = 1
    private var panOffset = CGPoint.zero
    private var pinchStartScale: CGFloat = 1
    private var pinchAnchor = CGPoint.zero
    private var panStartOffset = CGPoint.zero
    private var manipulatingZoom = false

    var enabled = true
    var calibrating = false
    var onPoint: ((CGPoint) -> Void)?
    var onTouch: ((Int, CGPoint) -> Void)?
    var onZoomChanged: ((CGFloat) -> Void)?
    private var pressed = false
    private var last = CGPoint.zero
    private var lastMove: TimeInterval = 0

    private lazy var pinchGesture: UIPinchGestureRecognizer = {
        let gesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        gesture.delegate = self
        gesture.cancelsTouchesInView = true
        return gesture
    }()
    private lazy var panGesture: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        gesture.minimumNumberOfTouches = 2
        gesture.maximumNumberOfTouches = 2
        gesture.delegate = self
        gesture.cancelsTouchesInView = true
        return gesture
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        contentView.backgroundColor = .black
        contentView.isUserInteractionEnabled = false
        addSubview(contentView)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        contentView.addSubview(imageView)
        isMultipleTouchEnabled = true
        addGestureRecognizer(pinchGesture)
        addGestureRecognizer(panGesture)
        semanticContentAttribute = .forceLeftToRight
        accessibilityLabel = "شاشة النوت للتحكم باللمس"
        accessibilityHint = "استخدم إصبعاً للتحكم، وإصبعين للتكبير والتحريك."
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func setVideo(_ player: ScreenVideoPlayer?, size: CGSize?) {
        if videoPlayer !== player {
            videoPlayer?.layer.removeFromSuperlayer()
            videoPlayer = player
            if let player = player { contentView.layer.insertSublayer(player.layer, at: 0) }
        }
        videoSize = size
        imageView.isHidden = size != nil
        player?.layer.isHidden = size == nil
        player?.layer.frame = contentView.bounds
    }

    func cancelActiveTouch() {
        guard pressed else { return }
        pressed = false
        onTouch?(3, last)
    }

    override func layoutSubviews() {
        let sizeChanged = contentView.bounds.size != bounds.size
        if sizeChanged { cancelActiveTouch() }
        super.layoutSubviews()
        contentView.bounds = CGRect(origin: .zero, size: bounds.size)
        imageView.frame = contentView.bounds
        videoPlayer?.layer.frame = contentView.bounds
        panOffset = clamped(panOffset, scale: currentZoom)
        applyTransform(animated: false)
    }

    func setZoom(_ scale: CGFloat, animated: Bool) {
        guard !manipulatingZoom else { return }
        let target = min(4, max(1, scale))
        guard abs(target - currentZoom) > 0.005 else { return }
        currentZoom = target
        if target <= 1.005 { panOffset = .zero }
        else { panOffset = clamped(panOffset, scale: target) }
        applyTransform(animated: animated)
    }

    private func applyTransform(animated: Bool) {
        let changes = {
            self.contentView.transform = CGAffineTransform(scaleX: self.currentZoom, y: self.currentZoom)
            self.contentView.center = CGPoint(x: self.bounds.midX + self.panOffset.x, y: self.bounds.midY + self.panOffset.y)
        }
        guard animated, window != nil else { changes(); return }
        UIView.animate(withDuration: 0.24, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0.3, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
    }

    private func clamped(_ value: CGPoint, scale: CGFloat) -> CGPoint {
        guard scale > 1 else { return .zero }
        let x = bounds.width * (scale - 1) / 2
        let y = bounds.height * (scale - 1) / 2
        return CGPoint(x: min(x, max(-x, value.x)), y: min(y, max(-y, value.y)))
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            cancelActiveTouch()
            manipulatingZoom = true
            pinchStartScale = currentZoom
            pinchAnchor = contentView.convert(gesture.location(in: self), from: self)
        case .changed:
            let scale = min(4, max(1, pinchStartScale * gesture.scale))
            let location = gesture.location(in: self)
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            currentZoom = scale
            panOffset = CGPoint(
                x: location.x - center.x - scale * (pinchAnchor.x - contentView.bounds.midX),
                y: location.y - center.y - scale * (pinchAnchor.y - contentView.bounds.midY)
            )
            panOffset = clamped(panOffset, scale: scale)
            applyTransform(animated: false)
        case .ended, .cancelled, .failed:
            manipulatingZoom = false
            if currentZoom < 1.03 { currentZoom = 1; panOffset = .zero }
            else { panOffset = clamped(panOffset, scale: currentZoom) }
            applyTransform(animated: true)
            onZoomChanged?(currentZoom)
        default: break
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        if pinchGesture.state == .began || pinchGesture.state == .changed { return }
        switch gesture.state {
        case .began:
            cancelActiveTouch()
            manipulatingZoom = true
            panStartOffset = panOffset
        case .changed:
            let translation = gesture.translation(in: self)
            panOffset = clamped(CGPoint(x: panStartOffset.x + translation.x, y: panStartOffset.y + translation.y), scale: currentZoom)
            applyTransform(animated: false)
        case .ended, .cancelled, .failed:
            manipulatingZoom = false
            panOffset = clamped(panOffset, scale: currentZoom)
            applyTransform(animated: true)
            onZoomChanged?(currentZoom)
        default: break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard enabled, !calibrating else { return false }
        if gestureRecognizer === panGesture { return currentZoom > 1.005 }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        (gestureRecognizer === pinchGesture && otherGestureRecognizer === panGesture) ||
        (gestureRecognizer === panGesture && otherGestureRecognizer === pinchGesture)
    }

    private func position(_ touch: UITouch, clamp: Bool = false) -> CGPoint? {
        guard let imageSize = videoSize ?? imageView.image?.size, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let ratio = min(contentView.bounds.width / imageSize.width, contentView.bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
        let origin = CGPoint(x: (contentView.bounds.width - size.width) / 2, y: (contentView.bounds.height - size.height) / 2)
        let location = touch.location(in: contentView)
        let point = CGPoint(x: (location.x - origin.x) / size.width, y: (location.y - origin.y) / size.height)
        if !clamp && (point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1) { return nil }
        return CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if (event?.allTouches?.count ?? touches.count) > 1 { cancelActiveTouch(); return }
        guard enabled, let touch = touches.first, let p = position(touch) else { return }
        if calibrating { onPoint?(p); return }
        pressed = true
        last = p
        lastMove = ProcessInfo.processInfo.systemUptime
        onTouch?(0, p)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pressed, let touch = touches.first, let p = position(touch, clamp: true) else { return }
        last = p
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMove >= 1.0 / 60.0 { lastMove = now; onTouch?(2, p) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pressed else { return }
        pressed = false
        if let touch = touches.first, let p = position(touch, clamp: true) { last = p }
        onTouch?(1, last)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelActiveTouch() }
}
