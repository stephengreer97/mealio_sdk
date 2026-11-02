// The drop-in's look, set once with MealioCart.configure(theme:). Partners
// match their brand with a handful of values; everything else follows from
// them. Same fields and defaults as packages/react-native/src/theme.ts.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

public struct MealioTheme {
    /// Buttons, checkmarks, selected rings.
    public var accent: Color
    /// Text on the accent color.
    public var onAccent: Color
    /// Sheet background.
    public var background: Color
    /// Behind cards, the search box and thumbnails.
    public var surface: Color
    public var text: Color
    /// Secondary text. Keep 4.5:1 against background.
    public var muted: Color
    public var border: Color
    /// Corner radius of cards and buttons, in points.
    public var radius: CGFloat
    /// PostScript name of a font for every text, or nil for the system font.
    public var fontName: String?
    /// Out-of-stock warning colors.
    public var warnBackground: Color
    public var warnText: Color

    public init(accent: Color = Color(mealioHex: 0x1F6B47),
                onAccent: Color = Color(mealioHex: 0xFFFFFF),
                background: Color = Color(mealioHex: 0xFFFFFF),
                surface: Color = Color(mealioHex: 0xF2F1EE),
                text: Color = Color(mealioHex: 0x1B1B1A),
                muted: Color = Color(mealioHex: 0x5F5D58),
                border: Color = Color(mealioHex: 0xE4E2DD),
                radius: CGFloat = 14,
                fontName: String? = nil,
                warnBackground: Color = Color(mealioHex: 0xFFF4E5),
                warnText: Color = Color(mealioHex: 0x7A4A06)) {
        self.accent = accent
        self.onAccent = onAccent
        self.background = background
        self.surface = surface
        self.text = text
        self.muted = muted
        self.border = border
        self.radius = radius
        self.fontName = fontName
        self.warnBackground = warnBackground
        self.warnText = warnText
    }

    /// The defaults, as in theme.ts.
    public static let `default` = MealioTheme()

    /// The theme's font at a size and weight.
    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if let name = fontName, !name.isEmpty {
            return Font.custom(name, size: size).weight(weight)
        }
        return Font.system(size: size, weight: weight)
    }
}

public extension Color {
    /// A color from 0xRRGGBB.
    init(mealioHex hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// "$31.20": two decimals.
func mealioMoney(_ n: Double) -> String {
    String(format: "$%.2f", n)
}
#endif
