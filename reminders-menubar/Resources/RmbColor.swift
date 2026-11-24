import AppKit
import SwiftUI

enum RmbColor {
    case backgroundTheme(isTransparent: Bool)

    private static let dynamicBackgroundNSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            return NSColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1.0)
        }
        return NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    }

    var color: Color {
        switch self {
        case .backgroundTheme(let isTransparent):
            let base = Color(nsColor: Self.dynamicBackgroundNSColor)
            return isTransparent ? base.opacity(0.3) : base
        }
    }

    var nsColor: NSColor {
        switch self {
        case .backgroundTheme(let isTransparent):
            return isTransparent ? Self.dynamicBackgroundNSColor.withAlphaComponent(0.3) : Self.dynamicBackgroundNSColor
        }
    }
}
