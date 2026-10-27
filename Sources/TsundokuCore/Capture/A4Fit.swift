import CoreGraphics
import Foundation

public enum A4FitMode: String, Sendable, Equatable {
    case widthFit
    case scaledToDisplay
    case refused
}

public struct A4FitResult: Sendable, Equatable {
    public let mode: A4FitMode
    public let frame: CGRect
    public let pageBox: CGRect
    public let insets: CaptureInsets
    public let reason: String?

    public init(
        mode: A4FitMode, frame: CGRect, pageBox: CGRect,
        insets: CaptureInsets, reason: String?
    ) {
        self.mode = mode
        self.frame = frame
        self.pageBox = pageBox
        self.insets = insets
        self.reason = reason
    }

    public var pageRatio: CGFloat {
        pageBox.height > 0 ? pageBox.width / pageBox.height : 0
    }
}

public struct A4Measurement: Sendable, Equatable {
    public let window: CGRect
    public let pageBox: CGRect
    public let insets: CaptureInsets

    public init(window: CGRect, pageBox: CGRect, insets: CaptureInsets) {
        self.window = window
        self.pageBox = pageBox
        self.insets = insets
    }
}

public enum A4FitPlanner {
    public static let minimumPageSide: CGFloat = 120
    public static let ratio: CGFloat = CaptureCrop.a4Ratio

    /// Plan one fit. The page keeps the current width when the usable display
    /// area can hold it at A4 height; otherwise the page shrinks by the
    /// limiting dimension. The window is moved the minimum distance needed to
    /// stay inside that area, never to another display.
    public static func plan(
        measurement: A4Measurement, area: PageFrame.DisplayArea
    ) -> A4FitResult {
        let window = measurement.window
        let insets = measurement.insets
        guard !PageFrame.isFullScreen(
            window, displays: [area.display])
        else {
            return refused(
                measurement: measurement,
                reason: "full-screen capture is not supported; leave the "
                    + "menu bar visible and retry")
        }
        let usable = area.usable
        let targetHeight = measurement.pageBox.width / ratio
        let maxPageHeight =
            usable.height - insets.top - insets.bottom
        let maxPageWidth =
            usable.width - insets.left - insets.right
        guard maxPageHeight >= minimumPageSide,
            maxPageWidth >= minimumPageSide
        else {
            return refused(
                measurement: measurement,
                reason: "the usable display area cannot fit an A4 page")
        }
        var pageHeight = min(targetHeight, maxPageHeight)
        var pageWidth = pageHeight * ratio
        if pageWidth > maxPageWidth {
            pageWidth = maxPageWidth
            pageHeight = pageWidth / ratio
        }
        guard pageWidth >= minimumPageSide,
            pageHeight >= minimumPageSide
        else {
            return refused(
                measurement: measurement,
                reason: "the fitted page is smaller than "
                    + "\(Int(minimumPageSide)) points")
        }
        let size = PageSetupGeometry.windowSize(
            for: CGSize(width: pageWidth, height: pageHeight),
            insets: insets)
        let frame = CGRect(
            origin: PageSetupGeometry.clampedOrigin(
                window.origin, size: size, in: usable),
            size: size)
        let mode: A4FitMode =
            abs(pageWidth - measurement.pageBox.width) < 1
            ? .widthFit : .scaledToDisplay
        let pageBox = CGRect(
            x: frame.minX + insets.left, y: frame.minY + insets.top,
            width: pageWidth, height: pageHeight)
        return A4FitResult(
            mode: mode, frame: frame, pageBox: pageBox, insets: insets,
            reason: mode == .scaledToDisplay
                ? "the usable display area is too small for the current "
                    + "page width at A4 height"
                : nil)
    }

    private static func refused(
        measurement: A4Measurement, reason: String
    ) -> A4FitResult {
        A4FitResult(
            mode: .refused, frame: measurement.window,
            pageBox: measurement.pageBox, insets: measurement.insets,
            reason: reason)
    }
}

public enum A4FitError: Error, CustomStringConvertible, Sendable {
    case refused(String)
    case windowNotAccepted(expected: CGRect, actual: CGRect)

    public var description: String {
        switch self {
        case .refused(let reason): reason
        case .windowNotAccepted(let expected, let actual):
            "Kindle accepted \(Self.size(actual)) instead of "
                + "\(Self.size(expected))."
        }
    }

    private static func size(_ rect: CGRect) -> String {
        "\(Int(rect.width))×\(Int(rect.height))"
    }
}

/// Applies a plan, re-measures after the reflow, and bounds the attempts.
/// The closures keep the planner independent of a live Kindle.
public struct A4FitService: Sendable {
    public typealias Measure = @Sendable () throws -> A4Measurement
    public typealias Apply = @Sendable (CGRect) throws -> CGRect
    public typealias Settle = @Sendable () throws -> Void

    public let maximumAttempts: Int

    public init(maximumAttempts: Int = 3) {
        self.maximumAttempts = maximumAttempts
    }

    public func fit(
        area: PageFrame.DisplayArea, measure: Measure,
        apply: Apply, settle: Settle
    ) throws -> A4FitResult {
        var measurement = try measure()
        var last = A4FitPlanner.plan(
            measurement: measurement, area: area)
        guard last.mode != .refused else {
            throw A4FitError.refused(last.reason ?? "the fit was refused")
        }
        for _ in 0..<maximumAttempts {
            if PageFrame.sameRect(
                measurement.window, last.frame, tolerance: 1)
            {
                return last
            }
            _ = try apply(last.frame)
            try settle()
            measurement = try measure()
            let next = A4FitPlanner.plan(
                measurement: measurement, area: area)
            guard next.mode != .refused else {
                throw A4FitError.refused(
                    next.reason ?? "the fit was refused after resizing")
            }
            // The reader can clamp its own size. The next pass uses what it
            // actually accepted; the final result is never the requested
            // rectangle when the two disagree.
            last = next
        }
        guard PageFrame.sameRect(
            measurement.window, last.frame, tolerance: 2)
        else {
            throw A4FitError.windowNotAccepted(
                expected: last.frame, actual: measurement.window)
        }
        if abs(
            measurement.pageBox.width / measurement.pageBox.height
                - A4FitPlanner.ratio) > 0.002
        {
            throw A4FitError.windowNotAccepted(
                expected: last.frame, actual: measurement.window)
        }
        return last
    }
}
