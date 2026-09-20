#if targetEnvironment(simulator)
import UIKit

// Synthetic screen for CI screenshots; no personal media or pairing information.
enum SimulatorScreen {
    static func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1080, height: 2220)).image { context in
            UIColor(white: 0.09, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1080, height: 2220))
            for row in 0..<6 {
                for column in 0..<3 {
                    UIColor(hue: CGFloat(row * 3 + column) / 22, saturation: 0.25, brightness: 0.45, alpha: 1).setFill()
                    context.fill(CGRect(x: column * 360 + 12, y: row * 320 + 150, width: 336, height: 296))
                }
            }
            let style: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.white]
            ("Note8 · 1080 × 2220" as NSString).draw(at: CGPoint(x: 36, y: 36), withAttributes: style)
            ("1" as NSString).draw(at: CGPoint(x: 30, y: 160), withAttributes: style)
            ("18" as NSString).draw(at: CGPoint(x: 950, y: 2010), withAttributes: style)
            ("III                         ○                         ‹" as NSString).draw(at: CGPoint(x: 70, y: 2110), withAttributes: style)
        }
    }
}
#endif
