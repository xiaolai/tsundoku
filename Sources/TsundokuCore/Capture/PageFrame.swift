import AppKit
import CoreGraphics
import Foundation
import KindleAX

public struct CaptureInsets: Sendable, Equatable {
    public let top: Double
    public let bottom: Double
    public let left: Double
    public let right: Double

    public init(top: Double, bottom: Double, left: Double, right: Double) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }

    public static let measured = CaptureInsets(
        top: 54, bottom: 54, left: 52, right: 52)

    public func covers(_ other: CaptureInsets) -> Bool {
        top >= other.top && bottom >= other.bottom
            && left >= other.left && right >= other.right
    }

    public var named: [String: Double] {
        ["top": top, "bottom": bottom, "left": left, "right": right]
    }
}

public enum CalibrationStatus: String, Sendable, Equatable {
    case confirmed
    case derived
    case unverified
    case refused
}

public struct PageFrameCalibration: Sendable, Equatable {
    public let insets: CaptureInsets
    public let status: CalibrationStatus
    public let reason: String?
    public let chrome: CaptureInsets?
    public let headroom: CaptureInsets?

    public init(
        insets: CaptureInsets, status: CalibrationStatus, reason: String?,
        chrome: CaptureInsets?, headroom: CaptureInsets?
    ) {
        self.insets = insets
        self.status = status
        self.reason = reason
        self.chrome = chrome
        self.headroom = headroom
    }
}

public enum PageFrameError: Error, CustomStringConvertible, Sendable {
    case unmeasurable(String)
    case noBox(String)

    public var description: String {
        switch self {
        case .unmeasurable(let reason): reason
        case .noBox(let reason): reason
        }
    }
}

/// Ports the Python lane's page-frame intent: chrome sets a floor, text sets a
/// ceiling, and the measured 52/54 constant is a hypothesis to confirm or
/// replace. A failed measurement is `unverified`, never silently confirmed.
public enum PageFrame {
    public static let safetyMargin = 8.0
    public static let containerRatio = 0.95
    public static let maxChromeFraction = 0.25
    public static let windowDriftTolerance = 2.0

    public static func chromeIntrusion(
        tree: AXNode, window: CGRect, content: CGRect? = nil
    ) throws -> CaptureInsets {
        let rootFrame = rect(tree.frame)
        guard let rootFrame,
            abs(rootFrame.minX - window.minX) <= windowDriftTolerance,
            abs(rootFrame.minY - window.minY) <= windowDriftTolerance,
            abs(rootFrame.width - window.width) <= windowDriftTolerance,
            abs(rootFrame.height - window.height) <= windowDriftTolerance
        else {
            throw PageFrameError.unmeasurable(
                "the AX tree describes a different window")
        }
        var floor = CaptureInsets(top: 0, bottom: 0, left: 0, right: 0)
        var seen = 0
        let limitX = window.width * maxChromeFraction
        let limitY = window.height * maxChromeFraction

        func walk(_ node: AXNode) {
            if let frame = rect(node.frame), !isContainer(frame, window) {
                let needed = cheapestExclusion(frame, window: window)
                let reachesIn =
                    max(needed.left, needed.right) > limitX
                    || max(needed.top, needed.bottom) > limitY
                let isContent = content.map {
                    sameRect(frame, $0, tolerance: 2)
                } ?? false
                if !isContent && !reachesIn {
                    seen += 1
                    floor = CaptureInsets(
                        top: max(floor.top, needed.top),
                        bottom: max(floor.bottom, needed.bottom),
                        left: max(floor.left, needed.left),
                        right: max(floor.right, needed.right))
                }
            }
            for child in node.children { walk(child) }
        }
        walk(tree)
        guard seen > 0 else {
            throw PageFrameError.unmeasurable(
                "no usable chrome element was found in the tree")
        }
        return floor
    }

    public static func textHeadroom(
        window: CGRect, text: CGRect
    ) -> CaptureInsets {
        CaptureInsets(
            top: text.minY - window.minY,
            bottom: window.maxY - text.maxY,
            left: text.minX - window.minX,
            right: window.maxX - text.maxX)
    }

    public static func disagreement(
        insets: CaptureInsets, chrome: CaptureInsets,
        headroom: CaptureInsets?
    ) -> String? {
        var problems: [String] = []
        if !insets.covers(chrome) {
            problems.append(
                "chrome needs at least \(chrome); the page box leaves \(insets)")
        }
        if let headroom, !headroom.covers(insets) {
            problems.append(
                "the page text only allows \(headroom); the box takes \(insets)")
        }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }

    public static func derive(
        chrome: CaptureInsets, headroom: CaptureInsets?
    ) throws -> CaptureInsets {
        let side = max(chrome.left, chrome.right) + safetyMargin
        let wanted = CaptureInsets(
            top: chrome.top + safetyMargin,
            bottom: chrome.bottom + safetyMargin,
            left: side, right: side)
        if let headroom {
            for (edge, needed) in wanted.named {
                let allowed = headroom.named[edge] ?? 0
                if needed > allowed {
                    throw PageFrameError.noBox(
                        "no page box fits: the \(edge) needs \(needed) pt "
                            + "to clear chrome, but the text leaves "
                            + "\(allowed) pt")
                }
            }
        }
        return wanted
    }

    public static func pageRect(
        window: CGRect, insets: CaptureInsets
    ) -> CGRect {
        CGRect(
            x: window.minX + insets.left,
            y: window.minY + insets.top,
            width: window.width - insets.left - insets.right,
            height: window.height - insets.top - insets.bottom)
    }

    /// Full screen is refused in v1: the window covers the menu bar, so a
    /// click meant to reveal the toolbar cannot be targeted reliably, and the
    /// chrome measurements were taken from a normal window. The display list
    /// is injectable so the rule can be tested without a live session.
    public static func isFullScreen(
        _ window: CGRect, displays: [CGRect]? = nil
    ) -> Bool {
        (displays ?? displayBounds()).contains {
            abs($0.minX - window.minX) <= 1
                && abs($0.minY - window.minY) <= 1
                && abs($0.width - window.width) <= 1
                && abs($0.height - window.height) <= 1
        }
    }

    public struct DisplayArea: Sendable, Equatable {
        /// The full display, used for full-screen detection.
        public let display: CGRect
        /// The screen's visible frame in the same top-left space as AX
        /// windows: menu bar and Dock excluded.
        public let usable: CGRect

        public init(display: CGRect, usable: CGRect) {
            self.display = display
            self.usable = usable
        }
    }

    /// Active displays with their usable areas, converted from AppKit's
    /// bottom-left screens to the top-left global space AX reports.
    @MainActor
    public static func displayAreas() -> [DisplayArea] {
        let screens = NSScreen.screens
        guard let primaryTop = screens.first?.frame.maxY else { return [] }
        return screens.map { screen in
            let full = CGRect(
                x: screen.frame.minX,
                y: primaryTop - screen.frame.maxY,
                width: screen.frame.width,
                height: screen.frame.height)
            let visible = screen.visibleFrame
            let usable = CGRect(
                x: visible.minX, y: primaryTop - visible.maxY,
                width: visible.width, height: visible.height)
            return DisplayArea(display: full, usable: usable)
        }
    }

    /// Bounds in the top-left-origin global space AX reports frames in.
    public static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else {
            return []
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return []
        }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    public static func resolve(
        window: CGRect, text: CGRect?, chrome: CaptureInsets?,
        constants: CaptureInsets = .measured
    ) -> PageFrameCalibration {
        guard let chrome else {
            return PageFrameCalibration(
                insets: constants, status: .unverified,
                reason: "chrome was not measured; the box is unverified",
                chrome: nil, headroom: nil)
        }
        let headroom = text.map { textHeadroom(window: window, text: $0) }
        let complaint = disagreement(
            insets: constants, chrome: chrome, headroom: headroom)
        if complaint == nil, headroom != nil {
            return PageFrameCalibration(
                insets: constants, status: .confirmed, reason: nil,
                chrome: chrome, headroom: headroom)
        }
        if complaint == nil, headroom == nil {
            return PageFrameCalibration(
                insets: constants, status: .unverified,
                reason: "no page text proves the box does not clip",
                chrome: chrome, headroom: nil)
        }
        do {
            let derived = try derive(chrome: chrome, headroom: headroom)
            return PageFrameCalibration(
                insets: derived, status: .derived,
                reason: complaint, chrome: chrome, headroom: headroom)
        } catch {
            return PageFrameCalibration(
                insets: constants, status: .refused,
                reason: "\(error); \(complaint ?? "")",
                chrome: chrome, headroom: headroom)
        }
    }

    public static func resolve(
        window: CGRect, text: CGRect?, tree: AXNode?,
        constants: CaptureInsets = .measured
    ) -> PageFrameCalibration {
        guard let tree else {
            return PageFrameCalibration(
                insets: constants, status: .unverified,
                reason: "the AX tree was not read; the box is unverified",
                chrome: nil, headroom: nil)
        }
        let chrome: CaptureInsets
        do {
            chrome = try chromeIntrusion(
                tree: tree, window: window, content: text)
        } catch {
            return PageFrameCalibration(
                insets: constants, status: .unverified,
                reason: "\(error)", chrome: nil, headroom: nil)
        }
        return resolve(
            window: window, text: text, chrome: chrome, constants: constants)
    }

    public static func rect(_ frame: AXNode.Frame?) -> CGRect? {
        guard let frame, frame.width > 0, frame.height > 0,
            frame.x.isFinite, frame.y.isFinite,
            frame.width.isFinite, frame.height.isFinite
        else { return nil }
        return CGRect(
            x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    public static func sameRect(
        _ one: CGRect, _ other: CGRect,
        tolerance: Double = windowDriftTolerance
    ) -> Bool {
        abs(one.minX - other.minX) <= tolerance
            && abs(one.minY - other.minY) <= tolerance
            && abs(one.width - other.width) <= tolerance
            && abs(one.height - other.height) <= tolerance
    }

    public static func sameSize(
        _ one: CGSize, _ other: CGSize,
        tolerance: Double = windowDriftTolerance
    ) -> Bool {
        abs(one.width - other.width) <= tolerance
            && abs(one.height - other.height) <= tolerance
    }

    private static func isContainer(_ rect: CGRect, _ window: CGRect) -> Bool {
        rect.width >= window.width * containerRatio
            && rect.height >= window.height * containerRatio
    }

    private static func clamped(_ rect: CGRect, to window: CGRect) -> CGRect {
        let left = max(rect.minX, window.minX)
        let top = max(rect.minY, window.minY)
        return CGRect(
            x: left, y: top,
            width: max(0, min(rect.maxX, window.maxX) - left),
            height: max(0, min(rect.maxY, window.maxY) - top))
    }

    private static func cheapestExclusion(
        _ rect: CGRect, window: CGRect
    ) -> CaptureInsets {
        let clipped = clamped(rect, to: window)
        let cost = [
            "top": clipped.maxY - window.minY,
            "bottom": window.maxY - clipped.minY,
            "left": clipped.maxX - window.minX,
            "right": window.maxX - clipped.minX,
        ]
        let edge = cost.min { $0.value < $1.value }?.key ?? "top"
        return CaptureInsets(
            top: edge == "top" ? (cost["top"] ?? 0) : 0,
            bottom: edge == "bottom" ? (cost["bottom"] ?? 0) : 0,
            left: edge == "left" ? (cost["left"] ?? 0) : 0,
            right: edge == "right" ? (cost["right"] ?? 0) : 0)
    }
}
