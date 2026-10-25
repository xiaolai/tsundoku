import AppKit
import Foundation

/// What a reading surface looks like, as far as it can be read or measured.
///
/// Books publishes its font through Accessibility; Kindle publishes nothing,
/// so its values are measured from a screen capture. The panel never claims
/// more precision than its source: `family` is nil when only pixels were read.
public struct ReaderStyle: Equatable, Sendable {
    public enum Origin: String, Sendable {
        /// The reader published its font through `AXFont`.
        case accessibilityFont
        /// The size and rhythm were measured from a screen capture.
        case measuredPixels
    }

    public let family: String?
    public let pointSize: CGFloat
    /// Baseline to baseline, in points.
    public let linePitch: CGFloat
    public let origin: Origin

    public init(
        family: String?, pointSize: CGFloat, linePitch: CGFloat,
        origin: Origin
    ) {
        self.family = family
        self.pointSize = pointSize
        self.linePitch = linePitch
        self.origin = origin
    }
}

/// One sampling of the reading surface: its type, its colours, or both.
///
/// The two come from different evidence and can be absent separately — a
/// title page yields a theme but no pitch, and a missing permission yields
/// neither.
public struct ReaderSample: Equatable, Sendable {
    public let style: ReaderStyle?
    public let theme: ReaderTheme?

    public init(style: ReaderStyle?, theme: ReaderTheme?) {
        self.style = style
        self.theme = theme
    }
}

/// The answer text's style in the companion panel.
public struct CompanionTextStyle: Equatable, Sendable {
    public let family: String?
    public let size: CGFloat
    public let lineSpacing: CGFloat

    public init(family: String?, size: CGFloat, lineSpacing: CGFloat) {
        self.family = family
        self.size = size
        self.lineSpacing = lineSpacing
    }
}

/// Turns a reader's measured style into the panel's, smaller and bounded.
public enum CompanionTypography {
    /// The panel's text is a note beside the page, not the page: 80 % of the
    /// reader's size keeps the relationship visible without shouting.
    public static let scale: CGFloat = 0.8
    public static let sizeRange: ClosedRange<CGFloat> = 13...20
    public static let spacingRange: ClosedRange<CGFloat> = 0...12

    public static func style(
        from reader: ReaderStyle, scale: CGFloat = scale
    ) -> CompanionTextStyle {
        let size = clamp((reader.pointSize * scale).rounded(), sizeRange)
        let natural = naturalLineHeight(family: reader.family, size: size)
        let spacing = clamp(
            (reader.linePitch * scale - natural).rounded(), spacingRange)
        return CompanionTextStyle(
            family: reader.family, size: size, lineSpacing: spacing)
    }

    /// The line height the chosen face draws at a size, before any extra
    /// spacing; SwiftUI's `lineSpacing` is added on top of this.
    static func naturalLineHeight(family: String?, size: CGFloat) -> CGFloat {
        let font =
            family.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.systemFont(ofSize: size)
        return font.ascender - font.descender + font.leading
    }

    static func clamp(
        _ value: CGFloat, _ range: ClosedRange<CGFloat>
    ) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// A point size for a surface that publishes none.
public enum MeasuredType {
    /// A book's leading is about 1.5× its type. Measured on Books: a 23.12 pt
    /// body on a 36 pt pitch (1.56). Kindle publishes no size at all, so its
    /// pitch is divided by this and clamped.
    public static let assumedLineHeight: CGFloat = 1.5
    public static let sizeRange: ClosedRange<CGFloat> = 12...28

    public static func pointSize(forPitch pitch: CGFloat) -> CGFloat {
        min(max(pitch / assumedLineHeight, sizeRange.lowerBound),
            sizeRange.upperBound)
    }
}
