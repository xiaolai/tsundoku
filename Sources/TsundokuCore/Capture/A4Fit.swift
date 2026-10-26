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

    /// Plan one fit. The origin is kept; the height is bounded by the display
    /// below that origin, and the width is reduced when the height cannot
    /// produce an A4 page.
    public static func plan(
        measurement: A4Measurement, display: CGRect
    ) -> A4FitResult {
        let window = measurement.window
        let insets = measurement.insets
        guard !PageFrame.isFullScreen(window, displays: [display]) else {
            return refused(
                measurement: measurement,
                reason: "full-screen capture is not supported; leave the "
                    + "menu bar visible and retry")
        }
        let targetHeight = measurement.pageBox.width / ratio
        let top = max(
            window.minY, display.minY + PageSetupGeometry.menuBarHeight)
        let maxPageHeight = display.maxY - top - insets.top - insets.bottom
        let maxPageWidth =
            display.maxX - max(window.minX, display.minX)
            - insets.left - insets.right
        guard maxPageHeight >= minimumPageSide,
            maxPageWidth >= minimumPageSide
        else {
            return refused(
                measurement: measurement,
                reason: "the display cannot fit a usable A4 page below the "
                    + "current window origin")
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
        let frame = CGRect(origin: window.origin, size: size)
        let mode: A4FitMode =
            abs(pageWidth - measurement.pageBox.width) < 1
                && abs(pageHeight - targetHeight) < 1
            ? .widthFit : .scaledToDisplay
        let pageBox = CGRect(
            x: frame.minX + insets.left, y: frame.minY + insets.top,
            width: pageWidth, height: pageHeight)
        return A4FitResult(
            mode: mode, frame: frame, pageBox: pageBox, insets: insets,
            reason: mode == .scaledToDisplay
                ? "the display could not keep the current width"
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
        display: CGRect, measure: Measure, apply: Apply,
        settle: Settle
    ) throws -> A4FitResult {
        var measurement = try measure()
        var last = A4FitPlanner.plan(
            measurement: measurement, display: display)
        guard last.mode != .refused else {
            throw A4FitError.refused(last.reason ?? "the fit was refused")
        }
        for _ in 0..<maximumAttempts {
            if abs(measurement.window.width - last.frame.width) < 1,
                abs(measurement.window.height - last.frame.height) < 1
            {
                return last
            }
            let actual = try apply(last.frame)
            try settle()
            measurement = try measure()
            let next = A4FitPlanner.plan(
                measurement: measurement, display: display)
            guard next.mode != .refused else {
                throw A4FitError.refused(
                    next.reason ?? "the fit was refused after resizing")
            }
            last = next
            if abs(actual.width - last.frame.width) > 3
                || abs(actual.height - last.frame.height) > 3
            {
                // The reader can clamp its own size. The next pass uses what
                // it actually accepted; the final result is never the
                // requested rectangle when the two disagree.
                continue
            }
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
