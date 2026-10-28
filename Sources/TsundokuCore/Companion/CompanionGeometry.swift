import CoreGraphics
import Foundation

// MARK: - Metrics

/// The panel edge a drag can move: the one facing the reader.
public enum PanelResizeEdge: String, Sendable, Equatable {
    case leading
    case trailing
    case top
    case bottom
}

/// The panel measurements the spike settled on. They are constants, not
/// tunables: the automatic placement chooses among them, it does not resize
/// them.
public enum CompanionMetrics {
    public static let gap: CGFloat = 8
    public static let sideWidth: CGFloat = 400
    /// The bottom drawer's preferred height, tried in order. 300 left about
    /// 150 pt of transcript under a header, a context bar and a composer.
    public static let bottomHeights: [CGFloat] = [420, 360, 300]
    public static let bottomHeight: CGFloat = 420
    /// The sizes a reader can set, by dragging the panel's edge or in
    /// settings. One range per dimension: two bounds that disagree mean a
    /// dragged panel can land outside the slider that is meant to show it.
    public static let sideWidthRange: ClosedRange<CGFloat> = 300...760
    public static let bottomHeightRange: ClosedRange<CGFloat> = 240...760
    public static let cornerRadius: CGFloat = 28
    public static let triggerSize: CGFloat = 56
    public static let triggerInset: CGFloat = 12
    public static let closeSize: CGFloat = 28
    public static let minimumPanelWidth: CGFloat = 280
    public static let minimumPanelHeight: CGFloat = 200
    public static let screenMargin: CGFloat = 4
}

// MARK: - Layout

public struct CompanionLayout: Equatable, Sendable {
    public enum Mode: String, Equatable, Sendable {
        case side
        case bottom
        case sideOverlay
        case corner

        public var isOverlay: Bool {
            self == .sideOverlay || self == .corner
        }
    }

    public let mode: Mode
    public let readerFrame: CGRect
    public let triggerFrame: CGRect
    public let panelFrame: CGRect

    public init(
        mode: Mode, readerFrame: CGRect, triggerFrame: CGRect,
        panelFrame: CGRect
    ) {
        self.mode = mode
        self.readerFrame = readerFrame
        self.triggerFrame = triggerFrame
        self.panelFrame = panelFrame
    }
}

// MARK: - Geometry

/// Pure frame arithmetic for the companion. The window layer owns no
/// reader-specific logic; it asks this for frames and positions the window.
public enum CompanionGeometry {
    /// Which edge of `panel` a drag may move.
    ///
    /// It is decided by where the panel actually ended up, not by the
    /// placement that was asked for: a bottom drawer normally sits below the
    /// reader, but geometry moves it above when there is no room, and the edge
    /// facing the reader is then its bottom. A handle on the wrong edge
    /// resizes the side that is pinned.
    public static func resizeEdge(
        mode: CompanionLayout.Mode, panel: CGRect, reader: CGRect
    ) -> PanelResizeEdge? {
        switch mode {
        case .bottom:
            // Below the reader, the edge facing it is the panel's top; when
            // geometry had to put the drawer above the reader, it is the
            // bottom.
            return panel.minY >= reader.midY ? .bottom : .top
        case .side, .sideOverlay, .corner:
            return panel.minX >= reader.midX ? .leading : .trailing
        }
    }

    public static func layout(
        reader: CGRect,
        visible: CGRect,
        panelPlacement: CompanionSettings.PanelPlacement,
        triggerPlacement: CompanionSettings.TriggerPlacement,
        sideWidth: CGFloat = CompanionMetrics.sideWidth,
        bottomHeight: CGFloat = CompanionMetrics.bottomHeight
    ) -> CompanionLayout {
        let placement = resolvePanel(
            reader: reader, visible: visible, preference: panelPlacement,
            sideWidth: sideWidth, bottomHeight: bottomHeight)
        let mode: CompanionLayout.Mode
        let panel: CGRect
        switch placement {
        case .side(let rect):
            mode = .side
            panel = rect
        case .bottom(let rect):
            mode = .bottom
            panel = rect
        case .sideOverlay(let rect):
            mode = .sideOverlay
            panel = rect
        case .corner(let rect):
            mode = .corner
            panel = rect
        }
        return CompanionLayout(
            mode: mode, readerFrame: reader,
            triggerFrame: triggerFrame(
                reader: reader, visible: visible,
                placement: triggerPlacement),
            panelFrame: panel)
    }

    private enum ResolvedPlacement {
        case side(CGRect)
        case bottom(CGRect)
        case sideOverlay(CGRect)
        case corner(CGRect)
    }

    private static func resolvePanel(
        reader: CGRect, visible: CGRect,
        preference: CompanionSettings.PanelPlacement,
        sideWidth: CGFloat, bottomHeight: CGFloat
    ) -> ResolvedPlacement {
        // A manual choice is a preference, not a promise: a side drawer with
        // no room still has to fall back, or it would land off-screen.
        let preferSide: Bool
        switch preference {
        case .auto:
            preferSide = reader.height >= reader.width
        case .side:
            preferSide = true
        case .bottom:
            preferSide = false
        }
        let side = sideOutside(
            reader: reader, visible: visible, width: sideWidth)
        let bottom = bottomOutside(
            reader: reader, visible: visible, preferred: bottomHeight)

        switch (preferSide, side, bottom) {
        case (true, .some(let rect), _):
            return .side(rect)
        case (false, _, .some(let rect)):
            return .bottom(rect)
        case (true, nil, .some(let rect)):
            return .bottom(rect)
        case (false, .some(let rect), nil):
            return .side(rect)
        case (true, nil, nil), (false, nil, nil):
            if let rect = sideOverlay(
                reader: reader, visible: visible, width: sideWidth)
            {
                return .sideOverlay(rect)
            }
            return .corner(
                cornerOverlay(
                    reader: reader, visible: visible, width: sideWidth,
                    height: bottomHeight))
        }
    }

    private static func sideOutside(
        reader: CGRect, visible: CGRect, width preferred: CGFloat
    ) -> CGRect? {
        let width = min(
            max(preferred, CompanionMetrics.minimumPanelWidth),
            max(CompanionMetrics.minimumPanelWidth, visible.width))
        let height = min(reader.height, visible.height)
        guard height >= CompanionMetrics.minimumPanelHeight else {
            return nil
        }
        let y = clampedOrigin(
            reader.midY - height / 2, span: height, in: visible.minY...visible.maxY)
        guard let y else { return nil }
        let right = CGRect(
            x: reader.maxX + CompanionMetrics.gap, y: y,
            width: width, height: height)
        if visible.contains(right) {
            return right
        }
        let left = CGRect(
            x: reader.minX - CompanionMetrics.gap - width, y: y,
            width: width, height: height)
        if visible.contains(left) {
            return left
        }
        return nil
    }

    private static func bottomOutside(
        reader: CGRect, visible: CGRect, preferred: CGFloat
    ) -> CGRect? {
        let width = min(reader.width, visible.width)
        guard width >= CompanionMetrics.minimumPanelWidth else {
            return nil
        }
        let x = clampedOrigin(
            reader.midX - width / 2, span: width, in: visible.minX...visible.maxX)
        guard let x else { return nil }
        // The tallest drawer the screen allows, so a bottom panel earns its
        // space instead of squeezing the transcript to a few lines.
        let heights = [preferred]
            + CompanionMetrics.bottomHeights.filter { $0 < preferred }
        for preferred in heights {
            let height = min(preferred, visible.height)
            guard height >= CompanionMetrics.minimumPanelHeight else {
                continue
            }
            let below = CGRect(
                x: x, y: reader.minY - CompanionMetrics.gap - height,
                width: width, height: height)
            if visible.contains(below) {
                return below
            }
            let above = CGRect(
                x: x, y: reader.maxY + CompanionMetrics.gap,
                width: width, height: height)
            if visible.contains(above) {
                return above
            }
        }
        return nil
    }

    private static func sideOverlay(
        reader: CGRect, visible: CGRect, width preferred: CGFloat
    ) -> CGRect? {
        let width = min(
            max(preferred, CompanionMetrics.minimumPanelWidth),
            min(reader.width, visible.width))
        let height = min(reader.height, visible.height)
        guard
            width >= CompanionMetrics.minimumPanelWidth,
            height >= CompanionMetrics.minimumPanelHeight
        else { return nil }
        let y = clampedOrigin(
            reader.midY - height / 2, span: height, in: visible.minY...visible.maxY)
        guard let y else { return nil }
        let x = min(
            max(reader.maxX - width, visible.minX),
            visible.maxX - width)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func cornerOverlay(
        reader: CGRect, visible: CGRect, width preferredWidth: CGFloat,
        height preferredHeight: CGFloat
    ) -> CGRect {
        // A reader that shrank — or a stale frame read while another window is
        // being dragged — must not produce a panel smaller than the panel.
        // The minimum is the last resort, clamped into the visible frame.
        let width = max(
            min(CompanionMetrics.minimumPanelWidth, visible.width),
            min(preferredWidth, min(max(reader.width, 0), visible.width)))
        let height = max(
            min(CompanionMetrics.minimumPanelHeight, visible.height),
            min(
                preferredHeight,
                min(max(reader.height, 0), visible.height)))
        let x = min(reader.maxX - width, visible.maxX - width)
        let y = min(reader.maxY - height, visible.maxY - height)
        return CGRect(
            x: max(x, visible.minX), y: max(y, visible.minY),
            width: width, height: height)
    }

    private static func triggerFrame(
        reader: CGRect, visible: CGRect,
        placement: CompanionSettings.TriggerPlacement
    ) -> CGRect {
        let size = CompanionMetrics.triggerSize
        var x: CGFloat
        let outside = reader.maxX + CompanionMetrics.gap
        let inside = reader.maxX - size - CompanionMetrics.triggerInset
        switch placement {
        case .outside:
            x = outside
        case .inside:
            x = inside
        case .auto:
            x = outside + size <= visible.maxX - CompanionMetrics.screenMargin
                ? outside : inside
        }
        x = max(
            visible.minX + CompanionMetrics.screenMargin,
            min(x, visible.maxX - size - CompanionMetrics.screenMargin))
        let y = max(
            visible.minY + CompanionMetrics.screenMargin,
            min(
                reader.midY - size / 2,
                visible.maxY - size - CompanionMetrics.screenMargin))
        return CGRect(x: x, y: y, width: size, height: size)
    }

    /// The origin that centres `span` on `value`, or nil when the span cannot
    /// fit in the range at all.
    private static func clampedOrigin(
        _ value: CGFloat, span: CGFloat, in range: ClosedRange<CGFloat>
    ) -> CGFloat? {
        let lower = range.lowerBound
        let upper = range.upperBound - span
        guard upper >= lower else { return nil }
        return min(max(value, lower), upper)
    }
}
