import Cocoa

enum RmbIcon: String, CaseIterable {
    case pikoCornerCheck = "icon-piko-check"

    static var defaultIcon: RmbIcon {
        return .pikoCornerCheck
    }

    private static let cachedCornerCheckImage: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            ctx.scaleBy(x: rect.width / 18.0, y: rect.height / 18.0)
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            // M7: Open-corner rounded frame with crisp diagonal checkmark at top-right
            let box = CGMutablePath()
            box.move(to: CGPoint(x: 9.8, y: 2.5))
            box.addLine(to: CGPoint(x: 5.5, y: 2.5))
            box.addArc(center: CGPoint(x: 5.5, y: 5.5), radius: 3.0, startAngle: -.pi / 2, endAngle: .pi, clockwise: true)
            box.addLine(to: CGPoint(x: 2.5, y: 12.5))
            box.addArc(center: CGPoint(x: 5.5, y: 12.5), radius: 3.0, startAngle: .pi, endAngle: .pi / 2, clockwise: true)
            box.addLine(to: CGPoint(x: 12.5, y: 15.5))
            box.addArc(center: CGPoint(x: 12.5, y: 12.5), radius: 3.0, startAngle: .pi / 2, endAngle: 0, clockwise: true)
            box.addLine(to: CGPoint(x: 15.5, y: 8.6))
            ctx.addPath(box)
            ctx.setLineWidth(1.55)
            ctx.strokePath()

            let tick = CGMutablePath()
            tick.move(to: CGPoint(x: 9.5, y: 7.0))
            tick.addLine(to: CGPoint(x: 11.4, y: 9.0))
            tick.addLine(to: CGPoint(x: 15.8, y: 3.4))
            ctx.addPath(tick)
            ctx.setLineWidth(1.65)
            ctx.strokePath()

            ctx.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }()

    var image: NSImage {
        switch self {
        case .pikoCornerCheck:
            return Self.cachedCornerCheckImage
        }
    }

    var name: String {
        switch self {
        case .pikoCornerCheck:
            return "Piko"
        }
    }
}
