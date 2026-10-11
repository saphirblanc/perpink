import SwiftUI

/// The reading size picked in Settings, for the conversation.
///
/// On iOS the conversation already follows the system's Dynamic Type, so this
/// only overrides it, the way Control Center's per-app Text Size does. The Mac
/// has no Dynamic Type, and SwiftUI there ignores `dynamicTypeSize`, so its
/// text styles are rebuilt at a scaled point size instead — Messages' Text Size
/// slider and View ▸ Make Text Bigger, in effect.
enum TextSize {
    #if os(macOS)
    /// Body sizes in points; 13 is the Mac's own body size.
    static let steps: [CGFloat] = [11, 12, 13, 14, 15, 16, 18, 20, 22]
    /// The step for the system's size, where nothing is overridden.
    static let systemStep = 2

    /// How much bigger than the Mac's own sizes the given step reads.
    static func scale(_ step: Int) -> CGFloat {
        steps[step.clamped(to: steps.indices)] / steps[systemStep]
    }
    #else
    /// The same sizes Settings ▸ Display & Brightness ▸ Text Size offers.
    static let steps: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge]
    #endif
}

extension View {
    /// A text style in the reading size: on iOS the style itself, which
    /// Dynamic Type scales; on the Mac the style's point size times the scale
    /// picked in Settings.
    func readingFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(ReadingFont(style: style, weight: weight, design: design))
    }

    /// Applies the size picked in Settings to everything below.
    func readingSize(step: Int?) -> some View {
        modifier(ReadingSize(step: step))
    }
}

private struct ReadingFont: ViewModifier {
    let style: Font.TextStyle
    let weight: Font.Weight?
    let design: Font.Design?

    #if os(macOS)
    @Environment(\.readingScale) private var scale
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content.font(.system(
            size: Self.pointSize(style) * scale,
            weight: weight ?? (style == .headline ? .bold : .regular),
            design: design ?? .default
        ))
        #else
        content.font(.system(style, design: design, weight: weight))
        #endif
    }

    #if os(macOS)
    /// The Mac's text styles, from the Human Interface Guidelines' typography tables.
    private static func pointSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        default: 13 // body, headline
        }
    }
    #endif
}

private struct ReadingSize: ViewModifier {
    let step: Int?

    #if os(iOS)
    @Environment(\.dynamicTypeSize) private var systemSize
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content.environment(\.readingScale, TextSize.scale(step ?? TextSize.systemStep))
        #else
        content.dynamicTypeSize(step.map { TextSize.steps[$0.clamped(to: TextSize.steps.indices)] } ?? systemSize)
        #endif
    }
}

#if os(macOS)
extension EnvironmentValues {
    @Entry var readingScale: CGFloat = 1
}
#endif

private extension Int {
    func clamped(to range: Range<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound - 1)
    }
}
