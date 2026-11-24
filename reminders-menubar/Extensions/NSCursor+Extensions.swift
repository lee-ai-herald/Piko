import AppKit

extension NSCursor {
    /// Programmatic crisp NW-SE diagonal double-arrow resize cursor (Retina-sharp, zero asset-catalog dependency).
    static let rmbDiagonalResize: NSCursor = {
        let baseSize: CGFloat = 22
        let image = NSImage(size: NSSize(width: baseSize, height: baseSize), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            ctx.translateBy(x: rect.midX, y: rect.midY)
            // Rotate so the arrow runs top-left <-> bottom-right (NW-SE)
            ctx.rotate(by: -.pi / 4)

            let arrow = CGMutablePath()
            let halfShaft: CGFloat = 1.0
            let neckX: CGFloat = 3.2
            let headBaseX: CGFloat = 3.2
            let headWingY: CGFloat = 3.6
            let tipX: CGFloat = 7.6

            arrow.move(to: CGPoint(x: -tipX, y: 0))
            arrow.addLine(to: CGPoint(x: -headBaseX, y: headWingY))
            arrow.addLine(to: CGPoint(x: -neckX, y: halfShaft))
            arrow.addLine(to: CGPoint(x: neckX, y: halfShaft))
            arrow.addLine(to: CGPoint(x: headBaseX, y: headWingY))
            arrow.addLine(to: CGPoint(x: tipX, y: 0))
            arrow.addLine(to: CGPoint(x: headBaseX, y: -headWingY))
            arrow.addLine(to: CGPoint(x: neckX, y: -halfShaft))
            arrow.addLine(to: CGPoint(x: -neckX, y: -halfShaft))
            arrow.addLine(to: CGPoint(x: -headBaseX, y: -headWingY))
            arrow.closeSubpath()

            ctx.setLineJoin(.round)
            ctx.setLineWidth(2.4)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.addPath(arrow)
            ctx.strokePath()

            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(arrow)
            ctx.fillPath()
            ctx.restoreGState()
            return true
        }

        return NSCursor(
            image: image,
            hotSpot: NSPoint(x: baseSize / 2, y: baseSize / 2)
        )
    }()
}
