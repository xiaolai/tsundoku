import CoreGraphics

/// The geometry of the drawer-style panel animation.
///
/// The panel grows out of the edge of the reader it sits against: on a side
/// placement its full height stays put while the width opens away from the
/// reader; above or below the reader, its full width stays put while the
/// height opens. The direction is derived from the panel's position, never
/// configured separately.
public enum CompanionDrawer {
    public enum Anchor: String, Sendable, Equatable {
        /// The left edge stays put and the panel grows to the right.
        case leading
        /// The right edge stays put and the panel grows to the left.
        case trailing
        /// The top edge (AppKit's maxY) stays put and the panel grows down.
        case top
        /// The bottom edge (AppKit's minY) stays put and the panel grows up.
        case bottom
    }

    /// The panel edge nearest the reader — the edge it opens from.
    public static func anchor(panel: CGRect, reader: CGRect) -> Anchor {
        // Outside the reader: the edge that faces it.
        if panel.minX >= reader.maxX - 0.5 { return .leading }
        if panel.maxX <= reader.minX + 0.5 { return .trailing }
        if panel.maxY <= reader.minY + 0.5 { return .top }
        if panel.minY >= reader.maxY - 0.5 { return .bottom }
        // An overlay covers the reader and is aligned to its right edge,
        // where the trigger sits; it opens across the page.
        return .trailing
    }

    /// The collapsed start rect: the growing dimension shrinks to `minimum`
    /// while the anchored edge and the full perpendicular size stay put.
    public static func start(
        of panel: CGRect, anchor: Anchor, minimum: CGFloat = 1
    ) -> CGRect {
        switch anchor {
        case .leading:
            CGRect(
                x: panel.minX, y: panel.minY, width: minimum,
                height: panel.height)
        case .trailing:
            CGRect(
                x: panel.maxX - minimum, y: panel.minY, width: minimum,
                height: panel.height)
        case .top:
            CGRect(
                x: panel.minX, y: panel.maxY - minimum, width: panel.width,
                height: minimum)
        case .bottom:
            CGRect(
                x: panel.minX, y: panel.minY, width: panel.width,
                height: minimum)
        }
    }
}
