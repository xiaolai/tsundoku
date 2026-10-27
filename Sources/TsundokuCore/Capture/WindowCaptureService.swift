import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

public struct CapturedWindow: Sendable {
    public let image: CGImage
    /// The window's frame in global points, as AX and `SCWindow` report it.
    /// This is the coordinate space a crop is expressed against.
    public let windowFrame: CGRect
    /// The captured content without the window frame or shadow.
    public let contentRect: CGRect

    public init(
        image: CGImage, windowFrame: CGRect, contentRect: CGRect
    ) {
        self.image = image
        self.windowFrame = windowFrame
        self.contentRect = contentRect
    }
}

public enum WindowCaptureError: Error, CustomStringConvertible, Sendable {
    case noWindow
    case ambiguousWindow
    case timedOut
    case cancelled
    case invalidGeometry(String)
    case failed(String)

    public var description: String {
        switch self {
        case .noWindow:
            "The reader window is not available to ScreenCaptureKit."
        case .ambiguousWindow:
            "More than one reader window matched; refusing to guess."
        case .timedOut:
            "The window screenshot did not finish before its deadline."
        case .cancelled:
            "The window screenshot was cancelled."
        case .invalidGeometry(let reason):
            "The window geometry is not usable: \(reason)"
        case .failed(let message):
            "The window screenshot failed: \(message)"
        }
    }
}

/// A window as ScreenCaptureKit describes it, separated from the framework so
/// selection can be tested without a live session.
public struct ShareableWindow: Sendable, Equatable {
    public let windowID: CGWindowID
    public let frame: CGRect
    public let title: String?
    public let layer: Int

    public init(
        windowID: CGWindowID, frame: CGRect, title: String?, layer: Int
    ) {
        self.windowID = windowID
        self.frame = frame
        self.title = title
        self.layer = layer
    }
}

public protocol WindowCapturing: Sendable {
    func capture(
        expectedFrame: CGRect?, isCancelled: @escaping @Sendable () -> Bool
    ) throws -> CapturedWindow
}

/// Screenshots one reader window without activating it or photographing the
/// display. It includes off-screen and covered windows; a minimized window is
/// listed by ScreenCaptureKit but its content cannot receive page turns.
public struct WindowCaptureService: WindowCapturing, Sendable {
    public let bundleID: String
    public let timeout: TimeInterval

    public init(
        bundleID: String = "com.amazon.Lassen", timeout: TimeInterval = 6
    ) {
        self.bundleID = bundleID
        self.timeout = timeout
    }

    public func capture(
        expectedFrame: CGRect?, isCancelled: @escaping @Sendable () -> Bool
    ) throws -> CapturedWindow {
        let box = WindowResultBox()
        let bundleID = bundleID
        let deadline = DispatchTime.now()
            + .milliseconds(Int((timeout * 1_000).rounded()))
        let task = Task.detached {
            do {
                let content = try await SCShareableContent
                    .excludingDesktopWindows(
                        false, onScreenWindowsOnly: false)
                let windows = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == bundleID
                }
                let summaries = windows.map(Self.summary)
                let chosen = try Self.selectWindow(
                    summaries, expectedFrame: expectedFrame)
                guard
                    let window = windows.first(where: {
                        $0.windowID == chosen.windowID
                    })
                else {
                    throw WindowCaptureError.noWindow
                }
                let filter = SCContentFilter(
                    desktopIndependentWindow: window)
                let scale = CGFloat(filter.pointPixelScale)
                guard scale.isFinite, scale > 0 else {
                    throw WindowCaptureError.invalidGeometry(
                        "the window has no pixel scale")
                }
                let contentRect = filter.contentRect
                guard contentRect.width > 1, contentRect.height > 1 else {
                    throw WindowCaptureError.invalidGeometry(
                        "the captured content has no area")
                }
                let configuration = SCStreamConfiguration()
                configuration.width = max(
                    1, Int((contentRect.width * scale).rounded()))
                configuration.height = max(
                    1, Int((contentRect.height * scale).rounded()))
                configuration.scalesToFit = false
                configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: configuration)
                guard image.width > 1, image.height > 1 else {
                    throw WindowCaptureError.invalidGeometry(
                        "the screenshot has no pixels")
                }
                let actualScale = CGFloat(image.width) / contentRect.width
                guard actualScale.isFinite, actualScale > 0 else {
                    throw WindowCaptureError.invalidGeometry(
                        "the screenshot scale is not finite")
                }
                box.set(
                    .success(
                        CapturedWindow(
                            image: image,
                            windowFrame: window.frame,
                            contentRect: contentRect)))
            } catch {
                box.set(.failure(error))
            }
        }

        while box.value == nil {
            if isCancelled() {
                task.cancel()
                throw WindowCaptureError.cancelled
            }
            if DispatchTime.now() >= deadline {
                task.cancel()
                throw WindowCaptureError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let result = box.value else {
            throw WindowCaptureError.failed("the capture did not finish")
        }
        return try result.get()
    }

    /// A main reader window is layer 0, has a title, and is large enough to
    /// be a page. Helper windows are layer 0 too, so size and title are part
    /// of the filter rather than an afterthought.
    public static func selectWindow(
        _ windows: [ShareableWindow], expectedFrame: CGRect?
    ) throws -> ShareableWindow {
        let candidates = windows.filter {
            $0.layer == 0
                && $0.frame.width >= 120 && $0.frame.height >= 120
                && !($0.title ?? "").trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty
        }
        guard !candidates.isEmpty else { throw WindowCaptureError.noWindow }
        if let expectedFrame {
            let matches = candidates.filter {
                PageFrame.sameRect($0.frame, expectedFrame, tolerance: 4)
            }
            if matches.count == 1 { return matches[0] }
            if matches.isEmpty { throw WindowCaptureError.noWindow }
            throw WindowCaptureError.ambiguousWindow
        }
        let sorted = candidates.sorted {
            $0.frame.width * $0.frame.height
                > $1.frame.width * $1.frame.height
        }
        if sorted.count > 1,
            sorted[0].frame.width * sorted[0].frame.height
                == sorted[1].frame.width * sorted[1].frame.height
        {
            throw WindowCaptureError.ambiguousWindow
        }
        return sorted[0]
    }

    private static func summary(_ window: SCWindow) -> ShareableWindow {
        ShareableWindow(
            windowID: window.windowID, frame: window.frame,
            title: window.title, layer: window.windowLayer)
    }
}

private final class WindowResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<CapturedWindow, Error>?

    func set(_ result: Result<CapturedWindow, Error>) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    var value: Result<CapturedWindow, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
