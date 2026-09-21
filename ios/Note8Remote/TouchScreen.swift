import SwiftUI
import UIKit

struct TouchScreen: UIViewRepresentable {
    var image: UIImage?
    var videoPlayer: ScreenVideoPlayer? = nil
    var videoSize: CGSize? = nil
    var enabled: Bool
    var calibrating: Bool
    var point: (CGPoint) -> Void
    var touch: (Int, CGPoint) -> Void
    func makeUIView(context: Context) -> TouchSurface { TouchSurface() }
    static func dismantleUIView(_ uiView: TouchSurface, coordinator: ()) { uiView.cancelActiveTouch() }
    func updateUIView(_ uiView: TouchSurface, context: Context) {
        if !enabled || uiView.calibrating != calibrating { uiView.cancelActiveTouch() }
        uiView.setVideo(videoPlayer, size: videoSize); uiView.imageView.image = image; uiView.enabled = enabled; uiView.calibrating = calibrating; uiView.onPoint = point; uiView.onTouch = touch
    }
}
final class TouchSurface: UIView {
    let imageView = UIImageView()
    private var videoPlayer: ScreenVideoPlayer?
    private var videoSize: CGSize?
    func setVideo(_ player: ScreenVideoPlayer?, size: CGSize?) {
        if videoPlayer !== player { videoPlayer?.layer.removeFromSuperlayer(); videoPlayer = player; if let player = player { layer.addSublayer(player.layer) } }
        videoSize = size; imageView.isHidden = size != nil; player?.layer.isHidden = size == nil; player?.layer.frame = bounds
    }
    var enabled = true
    var calibrating = false
    var onPoint: ((CGPoint) -> Void)?
    var onTouch: ((Int, CGPoint) -> Void)?
    private var pressed = false
    private var last = CGPoint.zero
    private var lastMove: TimeInterval = 0
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .black
        imageView.contentMode = .scaleAspectFit; imageView.isUserInteractionEnabled = false
        addSubview(imageView); isMultipleTouchEnabled = false
        semanticContentAttribute = .forceLeftToRight
        accessibilityLabel = "شاشة النوت للتحكم باللمس"
        accessibilityHint = "في العرض الكامل، استخدم زر الرجوع الصغير لإظهار أدوات التحكم."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func cancelActiveTouch() {
        guard pressed else { return }
        pressed = false; onTouch?(3, last)
    }
    override func layoutSubviews() {
        if imageView.frame.size != bounds.size { cancelActiveTouch() }
        super.layoutSubviews(); imageView.frame = bounds; videoPlayer?.layer.frame = bounds
    }
    func position(_ touch: UITouch, clamp: Bool = false) -> CGPoint? {
        guard let imageSize = videoSize ?? imageView.image?.size, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let ratio = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
        let origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        let location = touch.location(in: self)
        let point = CGPoint(x: (location.x - origin.x) / size.width, y: (location.y - origin.y) / size.height)
        if !clamp && (point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1) { return nil }
        return CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard enabled, let touch = touches.first, let p = position(touch) else { return }
        if calibrating { onPoint?(p); return }
        pressed = true; last = p; lastMove = ProcessInfo.processInfo.systemUptime; onTouch?(0, p)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pressed, let touch = touches.first, let p = position(touch, clamp: true) else { return }
        last = p
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMove >= 1.0 / 60.0 { lastMove = now; onTouch?(2, p) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pressed else { return }; pressed = false
        if let touch = touches.first, let p = position(touch, clamp: true) { last = p }
        onTouch?(1, last)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelActiveTouch() }
}
