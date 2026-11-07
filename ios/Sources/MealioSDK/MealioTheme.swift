// The drop-in's look, set once with MealioCart.configure(theme:). Partners
// match their brand with a handful of values; everything else follows from
// them. Same fields and defaults as packages/react-native/src/theme.ts, plus
// the sheet's and the done screen's options from MealioProvider.tsx.

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

/// The colors for dark mode. Used when `MealioCart.colorScheme` is `.dark`, or
/// `.auto` on a phone set to dark. Colors you leave out are Mealio's dark ones.
/// `radius` and `fontName` carry over from `MealioCart.theme` while they are nil.
public struct MealioDarkTheme {
    public var accent: Color
    public var onAccent: Color
    public var background: Color
    public var surface: Color
    public var text: Color
    public var muted: Color
    public var border: Color
    public var radius: CGFloat?
    public var fontName: String?
    public var warnBackground: Color
    public var warnText: Color

    public init(accent: Color = Color(mealioHex: 0x5FBF8F),
                onAccent: Color = Color(mealioHex: 0x0E1A14),
                background: Color = Color(mealioHex: 0x1B1B1A),
                surface: Color = Color(mealioHex: 0x2A2A28),
                text: Color = Color(mealioHex: 0xF2F1EE),
                muted: Color = Color(mealioHex: 0xB4B2AC),
                border: Color = Color(mealioHex: 0x3A3A37),
                radius: CGFloat? = nil,
                fontName: String? = nil,
                warnBackground: Color = Color(mealioHex: 0x3B2A10),
                warnText: Color = Color(mealioHex: 0xF5C27A)) {
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

    /// The defaults, as DEFAULT_DARK_THEME in theme.ts.
    public static let `default` = MealioDarkTheme()
}

/// `.auto` follows the phone. The default is `.light`.
public enum MealioColorScheme: String, CaseIterable {
    case light, dark, auto
}

/// The colors in force. `system` is the SwiftUI colorScheme environment, read
/// only for `.auto`. A dark sheet takes radius and font from `light` unless
/// `dark` sets them.
func mealioResolveTheme(light: MealioTheme, dark: MealioDarkTheme,
                        scheme: MealioColorScheme, system: ColorScheme) -> MealioTheme {
    let isDark = scheme == .dark || (scheme == .auto && system == .dark)
    guard isDark else { return light }
    return MealioTheme(accent: dark.accent,
                       onAccent: dark.onAccent,
                       background: dark.background,
                       surface: dark.surface,
                       text: dark.text,
                       muted: dark.muted,
                       border: dark.border,
                       radius: dark.radius ?? light.radius,
                       fontName: dark.fontName ?? light.fontName,
                       warnBackground: dark.warnBackground,
                       warnText: dark.warnText)
}

/// How the cart sheet and store settings look and behave.
public struct MealioSheetOptions {
    /// Show the list total and the done screen's prices. Defaults to true.
    /// Options keep their own prices.
    public var showTotal: Bool
    /// `.auto` is the ordinary tall sheet. `.full` fills the screen.
    /// `.fraction` is a share of the screen from 0.5 to 1 (iOS 16 and later;
    /// on iOS 15 it is the ordinary tall sheet).
    public var height: MealioSheetHeight
    /// Your logo, shown at the top of the sheet.
    public var logo: Image?

    public init(showTotal: Bool = true, height: MealioSheetHeight = .auto, logo: Image? = nil) {
        self.showTotal = showTotal
        self.height = height
        self.logo = logo
    }
}

/// A button of your own on the done screen, like "Back to meal plan". It becomes
/// the main button and Done turns quiet. Tapping it closes the sheet, then
/// calls `handler`.
public struct MealioDoneAction {
    public let label: String
    public let handler: (AddResult) -> Void

    public init(label: String, handler: @escaping (AddResult) -> Void) {
        self.label = label
        self.handler = handler
    }
}

#if canImport(WebKit)
extension MealioCart {
    /// The theme in force. Pass the `colorScheme` from the SwiftUI environment.
    public static func resolvedTheme(for system: ColorScheme) -> MealioTheme {
        mealioResolveTheme(light: theme, dark: darkTheme, scheme: colorScheme, system: system)
    }
}

extension View {
    /// `.sheet`, or a full screen cover when the partner asked for `.full`.
    @MainActor
    @ViewBuilder
    func mealioPresent<Sheet: View>(isPresented: Binding<Bool>,
                                    @ViewBuilder content: @escaping () -> Sheet) -> some View {
        if MealioCart.sheet.height == .full {
            fullScreenCover(isPresented: isPresented, content: content)
        } else {
            sheet(isPresented: isPresented, content: content)
        }
    }

    /// Size the sheet this content is in. Here, not where the sheet is
    /// presented, so it also works in a partner's own `.sheet`. The minimum
    /// target is iOS 15 and presentationDetents is iOS 16.
    @MainActor
    @ViewBuilder
    func mealioSheetSize() -> some View {
        if #available(iOS 16, *) {
            let height = MealioCart.sheet.height
            if height == .full {
                presentationDetents([.large])
            } else if let share = height.share {
                presentationDetents([.fraction(CGFloat(share))])
            } else {
                self
            }
        } else {
            self
        }
    }
}
#endif
#endif
