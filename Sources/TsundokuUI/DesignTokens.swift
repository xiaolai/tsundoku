import AppKit
import SwiftUI

// MARK: - The design system

/// Every number, colour and duration a view is allowed to use.
///
/// The rule this file exists for: a view may not contain a hand-written value.
/// `padding(.horizontal, 12)` is a design decision made accidentally, in a file
/// nobody looks at when the layout needs changing; `Space.p12` is the same
/// decision made once. `DesignTokenTests` fails the build on a literal.
///
/// Two layers, deliberately:
///
/// - A **scale** (`Space.p12`, `Radius.r10`, `Type.body`) holds every legal
///   value. This is what component code uses.
/// - **Roles** (`Space.page`, `Radius.card`, `Type.micro`) name the values
///   whose meaning is stable. Where a role is clear, it is preferable to the
///   scale, because "the gap between sections" survives a redesign and "18"
///   does not.
///
/// The numbers here are the ones the app shipped with, not a re-invention: a
/// tokenisation that also restyles the app silently is not a refactor. The
/// scale can be rationalised later, in one place, on purpose.
public enum Space {
    /// Every legal distance, on a 2-point base with the half-steps the system
    /// already had. A value not in this list does not exist.
    public static let p0: CGFloat = 0
    public static let p1: CGFloat = 1
    public static let p2: CGFloat = 2
    public static let p3: CGFloat = 3
    public static let p4: CGFloat = 4
    public static let p5: CGFloat = 5
    public static let p6: CGFloat = 6
    public static let p7: CGFloat = 7
    public static let p8: CGFloat = 8
    public static let p10: CGFloat = 10
    public static let p12: CGFloat = 12
    public static let p14: CGFloat = 14
    public static let p16: CGFloat = 16
    public static let p18: CGFloat = 18
    public static let p20: CGFloat = 20
    public static let p24: CGFloat = 24
    public static let p28: CGFloat = 28

    // Roles.
    /// The content margin of a page.
    public static let page = p16
    /// Between the rows of a list or the blocks of a column.
    public static let block = p18
    /// Between an icon and its label, or a control's edge and its content.
    public static let inline = p6
    /// Between a card's content and its border.
    public static let card = p14
}

public enum Radius {
    /// The smallest radius still readable as rounded: a cover tile, a badge.
    public static let r3: CGFloat = 3
    public static let r6: CGFloat = 6
    public static let r8: CGFloat = 8
    public static let r10: CGFloat = 10
    public static let r12: CGFloat = 12
    public static let r14: CGFloat = 14
    public static let r18: CGFloat = 18

    /// A card, a panel, a control group.
    public static let card = r10
    /// A cover tile or a badge, where a large radius would read as a button.
    public static let tile = r3
    /// A bubble or a pill.
    public static let bubble = r14
}

/// The type ramp. Sizes are the ones the app shipped with; the names are the
/// roles, so a call site says what the text is for.
public enum Type {
    private static func font(
        _ size: CGFloat, _ weight: Font.Weight
    ) -> Font {
        .system(size: size, weight: weight)
    }

    /// A badge or an uppercase label.
    public static let micro = font(8, .semibold)
    /// The quietest secondary line.
    public static let small = font(9, .regular)
    /// A metadata line under a name.
    public static let caption = font(10.5, .regular)
    /// A label beside a value.
    public static let footnote = font(11, .regular)
    /// The second line of a two-line row.
    public static let detail = font(11.5, .regular)
    /// Body text in a dense view.
    public static let callout = font(12, .regular)
    /// The body of the app.
    public static let body = font(13, .regular)
    /// A row's title, or a small heading.
    public static let headline = font(13, .medium)
    /// A section title.
    public static let section = font(13, .semibold)
    /// A panel title.
    public static let title = font(16, .semibold)
    /// A window-level statement: the inspector's book title.
    public static let large = font(22, .regular)
    /// An empty state's title.
    public static let display = font(32, .bold)
    /// The app's one largest statement.
    public static let hero = font(36, .bold)

    /// A number that should not shift as it changes.
    public static func digits(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular).monospacedDigit()
    }

    /// The reading size, which the reader sets, clamped to the ramp's range.
    public static func reading(_ size: CGFloat) -> Font {
        .system(size: size)
    }
}

/// Colour with a job. `Ink` is text and rules; `Surface` is paper; `State` is
/// meaning.
public enum Ink {
    public static let primary = Color.primary
    public static let secondary = Color.secondary
    public static let tertiary = Color.secondary.opacity(Opacity.o60)
    public static let quaternary = Color.secondary.opacity(Opacity.o40)
    /// A hairline: a card's sheet, a divider that is not a `Divider`.
    public static let hairline = Color.primary.opacity(Opacity.o14)
    public static let accent = Color.accentColor
    public static let warning = Theme.warning
    public static let onAccent = Color.white
}

public enum Surface {
    /// The page behind content.
    public static let page = Color(nsColor: .underPageBackgroundColor)
    /// A card's paper.
    public static let paper = Color(nsColor: .textBackgroundColor)
    /// A field, a list row, a control's background.
    public static let control = Color(nsColor: .controlBackgroundColor)
    /// The paper of a card in dark appearance, lifted above the page.
    public static let paperDark = Color(
        red: 0.145, green: 0.145, blue: 0.157)
}

public enum Opacity {
    public static let o5: Double = 0.05
    public static let o10: Double = 0.10
    public static let o14: Double = 0.14
    public static let o15: Double = 0.15
    public static let o20: Double = 0.20
    public static let o25: Double = 0.25
    public static let o30: Double = 0.30
    public static let o35: Double = 0.35
    public static let o40: Double = 0.40
    public static let o45: Double = 0.45
    public static let o50: Double = 0.50
    public static let o55: Double = 0.55
    public static let o60: Double = 0.60
    public static let o75: Double = 0.75
    public static let o85: Double = 0.85
    public static let o90: Double = 0.90
    /// A selected row's wash.
    public static let selection = o35
    /// A hover wash.
    public static let hover = o10
}

/// Depth. A card sits on the page, a popover above it, a sheet above that.
public enum Elevation {
    public struct Level {
        public let color: Color
        public let radius: CGFloat
        public let y: CGFloat
    }

    public static func card(_ dark: Bool) -> Level {
        Level(
            color: .black.opacity(dark ? 0.34 : 0.10),
            radius: 7, y: 4)
    }

    public static func contact(_ dark: Bool) -> Level {
        Level(
            color: .black.opacity(dark ? 0.18 : 0.05),
            radius: 1.5, y: 0.8)
    }

    public static func tile(_ dark: Bool) -> Level {
        Level(color: .black.opacity(dark ? 0 : 0.16), radius: 1.2, y: 0.8)
    }
}

public enum Motion {
    public static let quick: Double = 0.15
    public static let standard: Double = 0.22
    public static let slow: Double = 0.3
}

/// Sizes that belong to a component rather than to the layout scale: a cover,
/// an icon, a window minimum. Named so the component's shape is stated once.
public enum Size {
    // Windows and sheets.
    public static let windowMinWidth: CGFloat = 880
    public static let windowMinHeight: CGFloat = 560
    public static let sheetWidth: CGFloat = 540
    public static let sheetHeight: CGFloat = 430
    public static let sheetMinWidth: CGFloat = 460
    public static let sheetMinHeight: CGFloat = 320
    public static let sheetNarrowWidth: CGFloat = 360
    public static let cropMinHeight: CGFloat = 240
    public static let cropSheetWidth: CGFloat = 680
    public static let cropSheetHeight: CGFloat = 520
    public static let historyMinWidth: CGFloat = 480
    public static let historyIdealWidth: CGFloat = 560
    public static let historyMinHeight: CGFloat = 360
    public static let historyIdealHeight: CGFloat = 520
    public static let notesMinWidth: CGFloat = 520
    public static let notesIdealWidth: CGFloat = 680
    public static let notesMinHeight: CGFloat = 420
    public static let notesIdealHeight: CGFloat = 600
    public static let quickPageWidth: CGFloat = 520
    public static let quickPageHeight: CGFloat = 480

    // Split views.
    public static let sidebarMinWidth: CGFloat = 220
    public static let sidebarIdealWidth: CGFloat = 260
    public static let sidebarMaxWidth: CGFloat = 340
    public static let detailMinWidth: CGFloat = 320

    // Measures: the width beyond which a line of text stops being read.
    public static let textMeasure: CGFloat = 460
    public static let textWide: CGFloat = 760
    public static let noteMeasure: CGFloat = 480
    public static let importMeasure: CGFloat = 420
    public static let importWide: CGFloat = 520
    public static let messageMeasure: CGFloat = 320

    // Controls and images.
    public static let controlHeight: CGFloat = 28
    public static let controlSquare: CGFloat = 28
    public static let smallControl: CGFloat = 22
    public static let compactButtonWidth: CGFloat = 30
    public static let iconButtonWidth: CGFloat = 22
    public static let sliderWidth: CGFloat = 180
    public static let sliderWidthSmall: CGFloat = 120
    public static let valueColumn: CGFloat = 36
    public static let progressWidth: CGFloat = 170
    public static let appIcon: CGFloat = 36
    public static let cropPreviewWidth: CGFloat = 46
    public static let cropPreviewHeight: CGFloat = 62
    public static let handleSize: CGFloat = 14
    public static let actionWidth: CGFloat = 48
    public static let popoverWidth: CGFloat = 280
    public static let gutterMinWidth: CGFloat = 14
    public static let indicatorWidth: CGFloat = 2
    public static let ruleWidth: CGFloat = 0.5
    public static let ruleHeight: CGFloat = 14
    public static let groveWidth: CGFloat = 1.5
    public static let previewMaxHeight: CGFloat = 520
    public static let excerptMaxHeight: CGFloat = 220
    public static let textPreviewMaxHeight: CGFloat = 180
    public static let imageMaxWidth: CGFloat = 240
    // Grid columns.
    public static let cardMinWidth: CGFloat = 280
    public static let cardMaxWidth: CGFloat = 440
    public static let chipMinWidth: CGFloat = 135
    public static let chipMaxWidth: CGFloat = 210
    public static let imageMaxHeight: CGFloat = 180
    /// The crop sheet's smallest content area.
    public static let cropContentMinHeight: CGFloat = 180
}

public enum Metrics {
    /// A one-point divider, drawn rather than using `Divider` for alignment.
    public static let hairline: CGFloat = 1
    public static let coverWidth: CGFloat = 28
    public static let coverHeight: CGFloat = 40
    public static let coverHeroWidth: CGFloat = 64
    public static let coverHeroHeight: CGFloat = 88
    public static let rowIcon: CGFloat = 11
    public static let badgeLine: CGFloat = 0.6
    public static let borderLine: CGFloat = 1
    public static let selectedLine: CGFloat = 1.6
    public static let dividerInset: CGFloat = 54
    public static let metricColumn: CGFloat = 26
    public static let dateColumn: CGFloat = 64
    public static let rowVertical: CGFloat = 5
}
