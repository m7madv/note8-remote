import SwiftUI
import UIKit

struct TouchScreen: UIViewRepresentable {
    var image: UIImage?
    var enabled: Bool
    var calibrating: Bool
    var point: (CGPoint) -> Void
    var touch: (Int, CGPoint) -> Void
    func makeUIView(context: Context) -> TouchSurface { TouchSurface() }
    func updateUIView(_ uiView: TouchSurface, context: Context) {
        uiView.imageView.image = image; uiView.enabled = enabled; uiView.calibrating = calibrating; uiView.onPoint = point; uiView.onTouch = touch
    }
}
final class TouchSurface: UIView {
    let imageView = UIImageView()
    var enabled = true
    var calibrating = false
    var onPoint: ((CGPoint) -> Void)?
    var onTouch: ((Int, CGPoint) -> Void)?
    private var pressed = false
    private var last = CGPoint.zero
    private var lastMove = Date.distantPast
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .black
        imageView.contentMode = .scaleAspectFit; imageView.isUserInteractionEnabled = false
        addSubview(imageView); isMultipleTouchEnabled = false
        semanticContentAttribute = .forceLeftToRight
        accessibilityLabel = "شاشة النوت للتحكم باللمس"
        accessibilityHint = "تتوفر أزرار الرئيسية والرجوع والتسجيل أسفل الشاشة."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layoutSubviews() { super.layoutSubviews(); imageView.frame = bounds }
    func position(_ touch: UITouch, clamp: Bool = false) -> CGPoint? {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return nil }
        let ratio = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        let location = touch.location(in: self)
        let point = CGPoint(x: (location.x - origin.x) / size.width, y: (location.y - origin.y) / size.height)
        if !clamp && (point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1) { return nil }
        return CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard enabled, let touch = touches.first, let p = position(touch) else { return }
        if calibrating { onPoint?(p); return }
        pressed = true; last = p; onTouch?(0, p)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pressed, let touch = touches.first, let p = position(touch, clamp: true) else { return }
        last = p
        if Date().timeIntervalSince(lastMove) > 0.033 { lastMove = Date(); onTouch?(2, p) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pressed else { return }; pressed = false
        if let touch = touches.first, let p = position(touch, clamp: true) { last = p }
        onTouch?(1, last)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { if pressed { pressed = false; onTouch?(3, last) } }
}
