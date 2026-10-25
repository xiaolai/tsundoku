import SwiftUI
import TsundokuCore

/// The reading page's colours as the panel uses them.
///
/// Follows the page's background and its light/dark direction, so the panel's
/// semantic colours (text, secondary text, controls) adapt as they would in a
/// system window of that appearance.
public struct CompanionTheme: Equatable {
    public let background: Color
    public let isDark: Bool

    public init(background: Color, isDark: Bool) {
        self.background = background
        self.isDark = isDark
    }

    public init(_ theme: ReaderTheme) {
        self.init(
            background: Color(
                .sRGB, red: theme.red, green: theme.green, blue: theme.blue,
                opacity: 1),
            isDark: theme.isDark)
    }
}
